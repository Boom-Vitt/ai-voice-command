//
//  AudioPipeline — mic tap ➜ 16 kHz mono WAV chunks for whisper.cpp
//
//  The shape of this file is dictated by one hard-won fact: `append(_:)` runs on AVFAudio's
//  realtime render thread. That thread must never touch actor-isolated state.
//
//  This app already hard-crashed once (EXC_BREAKPOINT inside `_dispatch_assert_queue_fail`,
//  called from `swift_task_isCurrentExecutor`) because an `installTap` closure silently
//  inherited `@MainActor` isolation and was then invoked from the audio thread. The runtime
//  checked "am I on the main executor?", found it was on a render thread, and aborted the
//  process. So:
//
//    * This type is NOT `@MainActor`, and must never become so.
//    * `@unchecked Sendable` is honest here — an unfair lock provides the mutual exclusion
//      the compiler cannot see.
//    * Nothing on the `append` path allocates unboundedly, does file I/O, prints, or touches
//      UI. The ring is preallocated; the converter, its scratch buffers, and even the
//      converter's input block are built once in `init`.
//
//  `OSAllocatedUnfairLock` rather than `NSLock`: unfair locks participate in priority
//  donation, so a low-priority background `takeChunk()` holding the lock cannot leave the
//  high-priority audio thread spinning. That inversion is precisely the contention pattern
//  here — audio thread vs. background transcription Task.
//

import AVFoundation
import Foundation
import os

final class AudioPipeline: @unchecked Sendable {

    // MARK: - Public surface

    /// One unit of audio handed to the transcriber.
    struct Chunk: Sendable {
        /// A complete 16 kHz mono 16-bit PCM WAV file, 44-byte header included.
        let wav: Data
        /// `true` when trailing silence ended the utterance (or the length cap forced it).
        /// `false` for an interim window, which will be re-transcribed and replaced in the UI.
        let isFinal: Bool
        /// Duration of audio represented by `wav`.
        let seconds: Double
    }

    enum PipelineError: Error, CustomStringConvertible {
        case invalidInputFormat(String)
        case converterUnavailable(String)

        var description: String {
            switch self {
            case .invalidInputFormat(let detail): return "invalid input format: \(detail)"
            case .converterUnavailable(let detail): return "cannot build converter: \(detail)"
            }
        }
    }

    // MARK: - Format constants (non-negotiable)

    /// whisper.cpp resamples nothing: 16 kHz mono is the only input it accepts.
    static let outputSampleRate: Double = 16_000
    static let outputChannelCount: AVAudioChannelCount = 1
    static let outputBitsPerSample = 16

    // MARK: - Segmentation constants

    /// RMS below this counts as silence. Linear amplitude, not dB.
    ///
    /// 0.01 is roughly -40 dBFS: comfortably above the noise floor of a MacBook's built-in
    /// mic in a quiet room (typically 0.001–0.004) and comfortably below conversational
    /// speech at arm's length (0.03–0.2). Raise it if a noisy room never falls silent;
    /// lower it if quiet speakers get chopped mid-sentence.
    // 0.0025, not the original 0.01: measured on this machine's microphone, real
    // speech that SFSpeechRecognizer transcribes perfectly sits BELOW 0.01 RMS
    // (trace 1:59: 13 chars recognized and typed, yet speech==0 and every flush
    // came back "below minimum buffered speech" because the ring was being
    // trimmed as permanent silence). The gate's job is to reject clicks and
    // thumps, not to second-guess the recognizer; the cloud dispatch has its own
    // non-empty-transcript gate for hallucination protection.
    private static let silenceRMSThreshold: Float = 0.0025

    /// Continuous trailing silence that ends an utterance. 0.6 s is long enough to survive
    /// the pause between words and the stop-gap of a plosive, short enough that the final
    /// result lands while the user is still looking at the screen.
    private static let finalSilenceSeconds: Double = 0.6

    /// Minimum speech in an utterance before trailing silence may finalise it. Below this a
    /// "word" is a door slam or a keyboard click, and sending it to whisper produces
    /// hallucinated text.
    private static let minFinalSpeechSeconds: Double = 0.4

    /// Minimum speech before an interim window is worth transcribing at all.
    private static let minInterimSpeechSeconds: Double = 0.3

    /// How much *new* audio must arrive before another interim window is emitted. 1 s keeps
    /// the UI visibly alive without re-running whisper on nearly identical audio.
    private static let interimIntervalSeconds: Double = 1.0

    /// Hard ceiling on one chunk. A monologue with no pause would otherwise grow until it
    /// hit the ring cap and started losing its own beginning; instead we force-finalise.
    ///
    /// 10 s, down from 25: measured with real no-pause Thai dictation (14:02), a 25 s
    /// chunk cost 9.3 s of fal latency and by then the live partials had revised the
    /// typed text so much the correction span could no longer be located ("typed text
    /// not found") — corrections never applied. 10 s chunks return in ~2-4 s against
    /// text that still matches, at the cost of one extra correction seam per ~10 s of
    /// continuous speech.
    private static let maxChunkSeconds: Double = 10.0

    /// Ring capacity. Must exceed `maxChunkSeconds` with headroom so the force-finalise
    /// fires before the oldest samples are overwritten. 30 s of Float32 at 16 kHz is 1.9 MB.
    private static let ringSeconds: Double = 30.0

    /// Silence retained ahead of speech. Speakers begin the first phoneme before the RMS of
    /// a whole buffer crosses the threshold, so a hard cut at the threshold clips onsets.
    /// While no speech is pending, everything older than this is dropped, which is what
    /// stops an idle mic from filling the ring with room tone.
    private static let preRollSeconds: Double = 0.25

    // MARK: - Derived sample counts

    private let ringCapacity: Int
    private let finalSilenceSamples: Int
    private let minFinalSpeechSamples: Int
    private let minInterimSpeechSamples: Int
    private let interimIntervalSamples: Int
    private let maxChunkSamples: Int
    private let preRollSamples: Int

    // MARK: - Shared state (audio thread ⇄ background Task)

    /// Everything both threads touch, in one struct so there is exactly one lock ordering
    /// and no chance of a torn read between `count` and the indices that interpret it.
    private struct State: Sendable {
        /// Preallocated ring of 16 kHz mono samples. Never resized after `init`.
        var ring: [Float]
        /// Next write position (wraps).
        var write: Int = 0
        /// Valid pending samples, saturating at `ring.count`. Oldest live at
        /// `(write - count + capacity) % capacity`.
        var count: Int = 0
        /// Samples classified as speech within the pending region.
        var speech: Int = 0
        /// Consecutive silent samples at the end of the pending region.
        var trailingSilence: Int = 0
        /// Samples appended since the last interim chunk was emitted.
        var sinceInterim: Int = 0
        /// Most recent per-buffer RMS, already clamped to 0…1.
        var level: Float = 0
    }
    private let lock: OSAllocatedUnfairLock<State>

    // MARK: - Audio-thread-only state

    /// Reused across every `append`. It carries the resampler's filter state, so building one
    /// per buffer would both allocate on the audio thread and inject a click at every
    /// boundary.
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    /// Preallocated destination for one `convert` call. ~1 s of output; the convert loop
    /// handles any input larger than that by draining the converter repeatedly.
    private let converted: AVAudioPCMBuffer
    /// Preallocated staging area so one `append` performs exactly one critical section
    /// regardless of how many `convert` iterations it took. 2 s at 16 kHz.
    private var scratch: [Float]

    // MARK: - takeChunk-only state

    /// Preallocated snapshot destination. Allocating a 30 s array *inside* the critical
    /// section would zero-fill 1.9 MB while the audio thread spins on the lock; the copy
    /// alone is bad enough. `takeChunk` is documented single-consumer, so this needs no lock.
    private var snapshot: [Float]

    // MARK: - Converter input plumbing

    /// The converter pulls input through a block. The block is built once and captures this
    /// box — never `self` — so there is no retain cycle and no per-buffer closure allocation.
    private final class InputSource: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        var supplied = false
    }
    private let source = InputSource()
    private let inputBlock: AVAudioConverterInputBlock

    // MARK: - Init

    /// - Parameter inputFormat: the tap's own format, e.g. 48 kHz mono Float32. It must be
    ///   the format `installTap` was given; a made-up format produces silence or garbage.
    init(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PipelineError.invalidInputFormat(
                "sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount)")
        }

        // Float32 mono, deinterleaved. Float rather than Int16 so the ring keeps full
        // precision and the single clamp-and-scale happens once, at WAV time.
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Self.outputSampleRate,
                                            channels: Self.outputChannelCount,
                                            interleaved: false) else {
            throw PipelineError.converterUnavailable("cannot describe 16 kHz mono Float32")
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw PipelineError.converterUnavailable(
                "\(Int(inputFormat.sampleRate)) Hz ×\(inputFormat.channelCount) → 16 kHz mono")
        }
        // Rate conversion is not decimation: 48 k → 16 k needs a proper anti-alias filter or
        // everything above 8 kHz folds back down onto the speech band as hiss. High quality
        // costs microseconds on Apple silicon.
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        // ~1.02 s of output per convert call. Any tap buffer in practice is 5–100 ms, so the
        // loop in `append` normally runs exactly once.
        let outCapacity = AVAudioFrameCount(16_384)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw PipelineError.converterUnavailable("cannot allocate conversion buffer")
        }

        self.converter = conv
        self.outputFormat = outFormat
        self.converted = outBuffer

        let rate = Self.outputSampleRate
        self.ringCapacity = Int(rate * Self.ringSeconds)
        self.finalSilenceSamples = Int(rate * Self.finalSilenceSeconds)
        self.minFinalSpeechSamples = Int(rate * Self.minFinalSpeechSeconds)
        self.minInterimSpeechSamples = Int(rate * Self.minInterimSpeechSeconds)
        self.interimIntervalSamples = Int(rate * Self.interimIntervalSeconds)
        self.maxChunkSamples = Int(rate * Self.maxChunkSeconds)
        self.preRollSamples = Int(rate * Self.preRollSeconds)

        self.scratch = [Float](repeating: 0, count: Int(rate * 2))
        self.snapshot = [Float](repeating: 0, count: ringCapacity)
        self.lock = OSAllocatedUnfairLock(
            initialState: State(ring: [Float](repeating: 0, count: ringCapacity)))

        let src = self.source
        self.inputBlock = { _, outStatus in
            // Exactly one buffer per `append`. Once handed over, report that input ran dry so
            // the converter flushes what it has instead of waiting for more.
            guard !src.supplied, let buffer = src.buffer else {
                outStatus.pointee = .noDataNow
                return nil
            }
            src.supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
    }

    // MARK: - Realtime audio thread

    /// Called on the REALTIME AUDIO THREAD.
    ///
    /// Converts to 16 kHz, then takes one short critical section: memcpy into the ring,
    /// update the segmentation counters, store the level. The conversion — the expensive
    /// part — happens outside the lock, so the background consumer never blocks the render
    /// thread for longer than a couple of memcpys.
    func append(_ buffer: AVAudioPCMBuffer) {
        let produced = convertIntoScratch(buffer)
        guard produced > 0 else { return }

        // RMS of this buffer decides speech vs. silence for the whole buffer. Per-buffer
        // rather than per-sample granularity is deliberate: at 5–100 ms a buffer is already
        // shorter than any phoneme, and sample-level gating would chatter on zero crossings.
        var sumSquares: Float = 0
        scratch.withUnsafeBufferPointer { src in
            for i in 0..<produced {
                let s = src[i]
                sumSquares += s * s
            }
        }
        let rms = (sumSquares / Float(produced)).squareRoot()
        let isSpeech = rms >= Self.silenceRMSThreshold

        let capacity = ringCapacity
        let preRoll = preRollSamples

        lock.withLock { state in
            // --- copy into the ring, wrapping at most once -----------------------------
            var written = 0
            while written < produced {
                let room = capacity - state.write
                let n = min(room, produced - written)
                state.ring[state.write ..< (state.write + n)] = scratch[written ..< (written + n)]
                state.write = (state.write + n) % capacity
                written += n
            }
            state.count = min(state.count + produced, capacity)

            // --- segmentation counters -------------------------------------------------
            if isSpeech {
                state.speech += produced
                state.trailingSilence = 0
            } else {
                state.trailingSilence += produced
            }
            state.sinceInterim += produced
            state.level = min(rms, 1)

            // While nothing has been spoken, keep only the pre-roll. Dropping the oldest
            // samples is just a smaller `count`, since the read origin is derived from it.
            if state.speech == 0 && state.count > preRoll {
                state.count = preRoll
            }
            // Cap *after* any trim, so neither counter can claim more samples than the ring
            // actually holds. Without the trailing-silence cap a long idle period would
            // satisfy the final-silence test the instant real speech arrived; without the
            // speech cap, a monologue that saturated the ring would keep crediting itself
            // for samples that have already been overwritten.
            state.trailingSilence = min(state.trailingSilence, state.count)
            state.speech = min(state.speech, state.count)
        }
    }

    /// Drain `buffer` through the converter into `scratch`. Returns the number of 16 kHz
    /// samples produced. Audio-thread only.
    private func convertIntoScratch(_ buffer: AVAudioPCMBuffer) -> Int {
        guard buffer.frameLength > 0 else { return 0 }

        source.buffer = buffer
        source.supplied = false
        defer { source.buffer = nil }

        var total = 0
        var error: NSError?

        while total < scratch.count {
            // `convert` writes frameLength on the output buffer; reset it so a short final
            // pass cannot be misread as the previous pass's length.
            converted.frameLength = 0
            let status = converter.convert(to: converted, error: &error, withInputFrom: inputBlock)

            let produced = Int(converted.frameLength)
            if produced > 0, let channels = converted.floatChannelData {
                // Guarded rather than force-unwrapped: a nil here would silently yield zero
                // samples, which looks exactly like a dead microphone.
                let n = min(produced, scratch.count - total)
                let src = channels[0]
                scratch.withUnsafeMutableBufferPointer { dst in
                    if let base = dst.baseAddress {
                        base.advanced(by: total).update(from: src, count: n)
                    }
                }
                total += n
            }

            // Break on every status other than `.haveData` — including `.error` and
            // `.endOfStream`. Looping only on the status we expect would spin forever the
            // first time the converter reports a problem.
            if status != .haveData { break }
            if produced == 0 { break }
        }

        return total
    }

    // MARK: - Background consumer

    /// Called periodically from a background Task — never from the audio thread.
    ///
    /// The snapshot copy happens under the lock (it must, the ring keeps moving); the WAV
    /// encoding, which is the allocating part, happens after the lock is released.
    func takeChunk() -> Chunk? {
        let finalSilence = finalSilenceSamples
        let minFinalSpeech = minFinalSpeechSamples
        let minInterimSpeech = minInterimSpeechSamples
        let interimInterval = interimIntervalSamples
        let maxChunk = maxChunkSamples
        let capacity = ringCapacity

        // (sampleCount, isFinal); nil means nothing worth sending.
        let decision: Taken? = lock.withLock { state -> Taken? in
            guard state.count > 0 else { return nil }

            let silenceEnded = state.trailingSilence >= finalSilence
            let tooLong = state.count >= maxChunk

            if silenceEnded {
                // Exactly two outcomes, no middle band: either the utterance is long enough
                // to transcribe, or it was a click/thump and gets dropped. Leaving a 0.3–0.4 s
                // remnant pending would wedge the buffer — trailing silence only grows, so
                // the same not-quite-enough state would be re-evaluated forever.
                guard state.speech >= minFinalSpeech else {
                    Self.clear(&state)
                    return nil
                }
                return emitFinal(&state, capacity: capacity, maxChunk: maxChunk)
            }

            if tooLong {
                // A monologue with no pause. Cut it here rather than let the ring eat its
                // own head; whisper handles a mid-word boundary far better than lost audio.
                return emitFinal(&state, capacity: capacity, maxChunk: maxChunk)
            }

            if state.speech >= minInterimSpeech && state.sinceInterim >= interimInterval {
                // Interim: the buffer is deliberately NOT cleared. This same audio will be
                // re-transcribed (with more context) and the UI replaces the previous text.
                // `count` is necessarily below `maxChunk` here — the force-finalise branch
                // above already claimed anything longer.
                let n = copyPending(&state, capacity: capacity, limit: state.count)
                state.sinceInterim = 0
                return Taken(samples: n, isFinal: false)
            }

            return nil
        }

        guard let taken = decision, taken.samples > 0 else { return nil }

        let wav = Self.encodeWAV(snapshot, count: taken.samples)
        return Chunk(wav: wav,
                     isFinal: taken.isFinal,
                     seconds: Double(taken.samples) / Self.outputSampleRate)
    }

    /// Force-finalize: return all buffered speech as a final chunk immediately,
    /// regardless of trailing-silence state, then clear the consumed audio.
    /// Returns nil only when there is less than `minSpeechSeconds` of buffered speech.
    /// Called from the background chunk loop (NOT the audio thread) when the user
    /// releases the hold-to-talk key -- the release is the utterance boundary, so
    /// waiting for acoustic silence would be redundant (and impossible in a room
    /// whose ambient noise sits above silenceRMSThreshold, which is exactly the
    /// measured failure this method fixes).
    func flush() -> Chunk? {
        let minFinalSpeech = minFinalSpeechSamples
        let maxChunk = maxChunkSamples
        let capacity = ringCapacity

        // Same shape as `takeChunk`: decide and snapshot under the lock, encode after it,
        // so the realtime `append` path never waits on WAV encoding.
        let decision: Taken? = lock.withLock { state -> Taken? in
            guard state.count > 0 else { return nil }
            // Gate on total buffered DURATION, not the `speech` counter. `speech` only
            // accumulates above silenceRMSThreshold (0.01), and a quiet microphone can
            // sit below that while the on-device recognizer still hears words fine --
            // measured in production: 11 chars transcribed and typed, yet speech==0 and
            // flush returned nil, so the cloud pass never fired. The caller already
            // gates the cloud dispatch on non-empty recognizer text (the
            // anti-hallucination gate), so RMS adds no protection here -- it only
            // starves the flush. Below ~0.4 s of ANY audio it is still a click/thump:
            // clear rather than leave it pending so the next press starts clean.
            guard state.count >= minFinalSpeech else {
                Self.clear(&state)
                return nil
            }
            // `emitFinal` applies the 25 s cap, consumes the emitted span, and resets
            // segmentation state (fully, when nothing is left pending).
            return emitFinal(&state, capacity: capacity, maxChunk: maxChunk)
        }

        guard let taken = decision, taken.samples > 0 else { return nil }

        let wav = Self.encodeWAV(snapshot, count: taken.samples)
        return Chunk(wav: wav,
                     isFinal: taken.isFinal,
                     seconds: Double(taken.samples) / Self.outputSampleRate)
    }

    /// Most recent RMS level, 0…1, for the level meter.
    var level: Float {
        lock.withLock { $0.level }
    }

    /// Drop all buffered audio and reset segmentation state.
    func reset() {
        lock.withLock { state in
            Self.clear(&state)
            state.level = 0
        }
    }

    // MARK: - Private helpers

    private struct Taken: Sendable {
        let samples: Int
        let isFinal: Bool
    }

    /// Emit a final chunk, never longer than `maxChunk`. Call with the lock held.
    ///
    /// The clamp matters because `count` saturates at the ring's 30 s capacity, not at the
    /// 25 s chunk cap: a consumer that stalls for six seconds mid-monologue would otherwise
    /// be handed a 30 s chunk. So we take the oldest `maxChunk` samples and leave the tail
    /// pending — it becomes the head of the next chunk rather than being thrown away.
    private func emitFinal(_ state: inout State, capacity: Int, maxChunk: Int) -> Taken? {
        let take = min(state.count, maxChunk)
        guard take > 0 else {
            Self.clear(&state)
            return nil
        }
        _ = copyPending(&state, capacity: capacity, limit: take)
        // Dropping the oldest samples is just a smaller `count`; the read origin is derived
        // from it, so the retained tail is already in the right place.
        state.count -= take
        if state.count == 0 {
            Self.clear(&state)
        } else {
            // `speech` is not tracked per sample, so charge the emitted span against it. In
            // the case that gets here — an unbroken monologue — nearly all of it was speech.
            state.speech = max(0, state.speech - take)
            state.trailingSilence = min(state.trailingSilence, state.count)
            state.sinceInterim = 0
        }
        return Taken(samples: take, isFinal: true)
    }

    /// Copy the oldest `limit` pending samples into `snapshot`, oldest first. Call with the
    /// lock held. Returns the sample count. `snapshot` is preallocated at ring capacity, so
    /// this is a pair of memcpys and nothing else.
    private func copyPending(_ state: inout State, capacity: Int, limit: Int) -> Int {
        let n = min(limit, state.count)
        guard n > 0 else { return 0 }
        // Origin of the whole pending region — `limit` trims the *end*, not the start.
        let start = (state.write - state.count + capacity) % capacity
        let first = min(n, capacity - start)
        snapshot[0 ..< first] = state.ring[start ..< (start + first)]
        if first < n {
            snapshot[first ..< n] = state.ring[0 ..< (n - first)]
        }
        return n
    }

    /// Reset segmentation without touching `level` — the meter should keep reading the room
    /// even after an utterance is consumed.
    private static func clear(_ state: inout State) {
        state.count = 0
        state.speech = 0
        state.trailingSilence = 0
        state.sinceInterim = 0
    }

    // MARK: - WAV

    /// Canonical 44-byte-header RIFF/WAVE: PCM format 1, 16-bit signed little-endian, mono,
    /// 16 kHz.
    ///
    /// Hand-rolled rather than routed through `AVAudioFile` because the header must be
    /// exactly this and nothing else — no `fact` chunk, no metadata, no format negotiation
    /// that could hand whisper.cpp a Float32 file. A malformed header does not error: whisper
    /// returns empty text, and the whole feature looks broken for the wrong reason.
    ///
    /// Also a pure function of its input, so it is testable without a microphone.
    static func encodeWAV(_ samples: [Float], count: Int) -> Data {
        let frames = max(0, min(count, samples.count))
        let bytesPerSample = outputBitsPerSample / 8
        let channels = Int(outputChannelCount)
        let blockAlign = channels * bytesPerSample
        let byteRate = Int(outputSampleRate) * blockAlign
        let dataBytes = frames * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataBytes)

        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        // --- RIFF chunk descriptor --------------------------------------------------
        ascii("RIFF")
        u32(UInt32(36 + dataBytes))          // everything after this field
        ascii("WAVE")
        // --- "fmt " sub-chunk -------------------------------------------------------
        ascii("fmt ")
        u32(16)                               // a PCM fmt chunk is exactly 16 bytes
        u16(1)                                // WAVE_FORMAT_PCM
        u16(UInt16(channels))
        u32(UInt32(outputSampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(outputBitsPerSample))
        // --- "data" sub-chunk -------------------------------------------------------
        ascii("data")
        u32(UInt32(dataBytes))

        guard frames > 0 else { return data }

        var pcm = [Int16](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { src in
            for i in 0..<frames {
                // Clamp before scaling. An un-clamped 1.2 would scale past Int16.max and wrap
                // to a large negative value — a full-amplitude sign flip, which sounds like a
                // gunshot and wrecks recognition on exactly the loudest (clearest) syllables.
                let clamped = min(max(src[i], -1), 1)
                pcm[i] = Int16(clamped * 32767)
            }
        }
        pcm.withUnsafeBufferPointer { buffer in
            // Int16 in memory is little-endian on arm64 and x86_64, which is also WAV's byte
            // order, so this is a straight copy.
            data.append(UnsafeRawBufferPointer(buffer).bindMemory(to: UInt8.self))
        }
        return data
    }
}
