//  SyntheticAudioSource.swift
//
//  A file that plays the part of the microphone, so that the 20 s seam can be tested
//  without a human in the room.
//
//  ── WHY THIS EXISTS ──────────────────────────────────────────────────────────────────
//
//  Phase 2's whole purpose is that the session rotation at 20 s stops eating the words that
//  straddle it. The number that measures it is printed by `handle`, from the
//  `result.isFinal` branch that receives the flushed final; `beginFlushRotation` only asks
//  for the flush and latches the baseline the number is measured against:
//
//      rotation: flushed final after 34 ms, ±N chars beyond partial at flush
//
//  `±N` is the text the seam used to lose, signed because a final can retract as well as
//  extend. In the silent-room round of `TEST-2026-08-30.md` it read 0 at every seam
//  observed — not because the fix worked, but because every run happened in a silent room,
//  so there was nothing at the seam to lose. A no-change seam prints `0 chars`, which is
//  equally consistent with "the gap is recovered" and "there was no gap". The mechanism was
//  proven to RUN; it was never proven to FIX anything. See `TEST-2026-08-30.md`, "Open /
//  not verified" §1. The synthetic runs this file exists to enable did later move it off
//  zero — `TEST-2026-08-31-run6-trace.txt` reads +7, +2, −4 and +6 at its four
//  seams — so that zero is scoped to the silent-room round, and must not be widened out.
//
//  Closing that needs continuous speech across a 20 s boundary. The obvious automation —
//  `say -v Kanya` out of the speakers while the harness listens — was tried and does not
//  work, at any volume: macOS voice processing subtracts the machine's own output from the
//  input path, so the microphone measured `rms≈0.011` against a `0.010` noise floor and the
//  run produced `partials=0`. **A Mac cannot dictate to itself through its speakers.**
//
//  The way past that is to notice the echo canceller only exists on the speaker→microphone
//  path. Render the same `say` output to a FILE and inject it after the tap, and the
//  canceller is not in the circuit at all:
//
//      say -v Kanya -o /tmp/thai.aiff -f thai.txt
//      open -W -n -g --env MICTEST_AUTOSTART=1 --env MICTEST_AUTOSTART_HOLD=50 \
//           --env MICTEST_AUDIO_FILE=/tmp/thai.aiff -a ~/Desktop/MicTest.app
//
//  ── WHAT THIS DOES AND DOES NOT PROVE ────────────────────────────────────────────────
//
//  Injection happens at `AppDelegate.processTap`, which is the single point every microphone
//  buffer passes through. Everything downstream is therefore exercised by exactly the code
//  that serves a real speaker: `LiveRecognizer.append` → `SFSpeechAudioBufferRecognitionRequest`,
//  the `AudioReplayRing`, the rotation, the flush, the `±N` measurement, the injector.
//
//  NOT covered, and no run through this source may be described as if it were: the physical
//  microphone, `AVAudioEngine`'s input node, the room, and — most importantly — whether
//  Apple's recogniser treats a synthetic voice the way it treats a human one. Kanya is a
//  text-to-speech voice. A `±N` above zero here proves the seam recovers audio that
//  crosses it; it does not prove a sentence a person says survives. Read `SYNTH:` lines as
//  "the harness fed this", never as "the user said this".
//
//  ── WHY THE MICROPHONE STAYS OPEN ────────────────────────────────────────────────────
//
//  `beginCapture` still builds the engine, installs the tap and starts it exactly as always;
//  the tap closure simply discards its own buffer while a synthetic source is running. That
//  is deliberate. The alternative — skipping `installTap`/`e.start()` — would fork the
//  start/stop state machine (`engine`, `isCapturing`, `sessions`, `captureGeneration`,
//  `chunkTask`, and the teardown that mirrors them), and a test harness that runs a
//  different lifecycle than the thing it is testing is not a test. One `if` in the tap
//  closure costs a predicted branch on the audio thread and changes no sequencing at all.
//
//  It also means the tap format is the REAL input format, so the buffers handed downstream
//  are indistinguishable from microphone buffers — `capturedTapFormat` bootstraps to the
//  same value it always would. `AudioPipeline`'s init comment is the rule being obeyed here:
//  "it must be the format `installTap` was given; a made-up format produces silence or
//  garbage."

import AVFoundation
import Foundation

/// Feeds a decoded audio file into the tap path at wall-clock speed.
///
/// `@unchecked Sendable` for the same reason the engines are: it is a reference type whose
/// mutable state is confined to one dedicated thread and guarded by `lock`, and it carries no
/// actor isolation. It is created on the main actor in `beginCapture` and its `sink` runs on
/// the pacing thread.
final class SyntheticAudioSource: @unchecked Sendable {

    /// Frames per delivered buffer. 1024 is not a round number picked for tidiness — it is
    /// the exact `bufferSize` `beginCapture` passes to `installTap`, so downstream code sees
    /// the cadence it was tuned against (~21.3 ms at 48 kHz). `AudioReplayRing`'s sizing
    /// comment calls out the same 1024 frames as "the 21 ms at 48 kHz" it budgets for.
    private static let framesPerChunk: AVAudioFrameCount = 1024

    private let chunks: [AVAudioPCMBuffer]
    private let sampleRate: Double
    private let sourceSeconds: Double
    private let path: String

    private let lock = NSLock()
    private var stopped = false
    private var thread: Thread?

    // MARK: - Construction

    enum SourceError: Error, CustomStringConvertible {
        case unreadable(String)
        case converterUnavailable(String)
        case empty(String)

        var description: String {
            switch self {
            case .unreadable(let s):          return "cannot read audio file: \(s)"
            case .converterUnavailable(let s): return "cannot convert to tap format: \(s)"
            case .empty(let s):               return "audio file decoded to nothing: \(s)"
            }
        }
    }

    /// Decode `path` and rewrite it into `tapFormat` up front.
    ///
    /// All of the decode and rate-conversion cost is paid here, on the main actor before the
    /// capture starts, precisely so that the pacing thread does nothing per chunk but copy
    /// bytes and sleep. A converter running under the deadline would make the harness's own
    /// jitter part of the measurement.
    ///
    /// - Parameter tapFormat: the format `installTap` was given. Not a preference — feeding
    ///   the recogniser a format the rest of the app was not built around is how you get a
    ///   run that measures the harness instead of the app.
    init(path: String, tapFormat: AVAudioFormat) throws {
        self.path = path
        let url = URL(fileURLWithPath: path)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SourceError.unreadable("\(path) — \((error as NSError).localizedDescription)")
        }

        let inFormat = file.processingFormat
        let inFrames = AVAudioFrameCount(file.length)
        guard inFrames > 0 else { throw SourceError.empty(path) }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inFrames) else {
            throw SourceError.unreadable("cannot allocate \(inFrames)-frame decode buffer")
        }
        do {
            try file.read(into: inBuffer)
        } catch {
            throw SourceError.unreadable("read failed — \((error as NSError).localizedDescription)")
        }

        // `say` writes 22.05 kHz mono AIFF; the input node is typically 48 kHz. High quality
        // for the same reason AudioPipeline uses it: rate conversion without a proper
        // anti-alias filter folds everything above Nyquist back onto the speech band, and
        // hiss on the speech band is precisely what this harness must not introduce.
        guard let converter = AVAudioConverter(from: inFormat, to: tapFormat) else {
            throw SourceError.converterUnavailable(
                "\(Int(inFormat.sampleRate)) Hz ×\(inFormat.channelCount) → "
                + "\(Int(tapFormat.sampleRate)) Hz ×\(tapFormat.channelCount)")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let ratio = tapFormat.sampleRate / inFormat.sampleRate
        // +2048 of slack: the resampler's output length is not exactly frames×ratio, and a
        // capacity one frame short would silently truncate the tail of the speech — which
        // would land as a "gap" the seam appears to have eaten. Overshoot is free; the real
        // length is read back from `frameLength` below.
        let outCapacity = AVAudioFrameCount(Double(inFrames) * ratio) + 2048
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: outCapacity) else {
            throw SourceError.converterUnavailable("cannot allocate \(outCapacity)-frame output buffer")
        }

        // Both the flag AND the buffer live in the box, deliberately. `AVAudioConverterInputBlock`
        // is `@Sendable`, so capturing either a local `var` or a bare `AVAudioPCMBuffer`
        // directly is a Swift 6 concurrency warning; there is no actual concurrency to guard
        // against, because the block is called synchronously on this thread before `convert`
        // returns. This is the same shape, and the same `@unchecked Sendable` justification,
        // as `AudioPipeline.InputSource` — which holds exactly these two fields for exactly
        // this converter call. One idiom for one problem.
        final class InputSource: @unchecked Sendable {
            var buffer: AVAudioPCMBuffer?
            var supplied = false
        }
        let source = InputSource()
        source.buffer = inBuffer

        var conversionError: NSError?
        converter.convert(to: outBuffer, error: &conversionError) { _, status in
            // One-shot: the whole file is already in memory, so the first call hands it over
            // and every later call reports end-of-stream. Returning the same buffer twice
            // would duplicate the audio.
            if source.supplied {
                status.pointee = .endOfStream
                return nil
            }
            source.supplied = true
            status.pointee = .haveData
            return source.buffer
        }
        if let conversionError {
            throw SourceError.converterUnavailable(conversionError.localizedDescription)
        }
        guard outBuffer.frameLength > 0 else { throw SourceError.empty("\(path) (after conversion)") }

        self.sampleRate = tapFormat.sampleRate
        self.sourceSeconds = Double(outBuffer.frameLength) / tapFormat.sampleRate
        self.chunks = Self.slice(outBuffer, into: Self.framesPerChunk, format: tapFormat)
        guard !chunks.isEmpty else { throw SourceError.empty("\(path) (after slicing)") }
    }

    /// Cut one long buffer into fixed-size delivery buffers.
    ///
    /// Copying is done over the raw `AudioBufferList` rather than `floatChannelData` so that
    /// interleaved and deinterleaved layouts are both handled by the same three lines: each
    /// `AudioBuffer` carries its own `mNumberChannels`, which is 1 per buffer when
    /// deinterleaved and N in a single buffer when interleaved, and the frame stride follows
    /// from it. Reaching for `floatChannelData[0]` instead would silently take one channel's
    /// worth of an interleaved buffer and produce chipmunk audio.
    private static func slice(_ source: AVAudioPCMBuffer,
                              into frames: AVAudioFrameCount,
                              format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        var out: [AVAudioPCMBuffer] = []
        out.reserveCapacity(Int(source.frameLength / frames) + 1)

        let srcList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        var position: AVAudioFrameCount = 0

        while position < source.frameLength {
            let count = min(frames, source.frameLength - position)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            chunk.frameLength = count

            let dstList = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            for i in 0..<min(srcList.count, dstList.count) {
                let bytesPerFrame = Int(srcList[i].mNumberChannels) * MemoryLayout<Float>.size
                guard let src = srcList[i].mData, let dst = dstList[i].mData else { continue }
                memcpy(dst,
                       src.advanced(by: Int(position) * bytesPerFrame),
                       Int(count) * bytesPerFrame)
                dstList[i].mDataByteSize = UInt32(Int(count) * bytesPerFrame)
            }

            out.append(chunk)
            position += count
        }
        return out
    }

    // MARK: - Running

    var describeSource: String {
        String(format: "%@ — %.1f s, %d chunks of %d frames @ %.0f Hz",
               (path as NSString).lastPathComponent, sourceSeconds,
               chunks.count, Int(Self.framesPerChunk), sampleRate)
    }

    /// Begin feeding `sink` on a dedicated thread, one chunk per chunk-duration of wall clock.
    ///
    /// **Real-time pacing is the point, not a nicety.** The rotation this harness exists to
    /// test fires on a 20 s *wall-clock* cadence (`LiveRecognizer.sessionRotationSeconds`).
    /// A pacer that pushed the file through as fast as it could read it would cross the
    /// boundary at an arbitrary and irreproducible point in the audio, and `±N` would
    /// measure nothing but scheduling luck. Feeding audio-time at wall-time puts the seam
    /// mid-utterance, which is where the bug lives.
    ///
    /// Deadlines are computed from a fixed origin rather than by adding a sleep each time, so
    /// error does not accumulate: 2,300 chunks at ~21.3 ms would drift by seconds over a 50 s
    /// run if each iteration slept "one chunk's worth" from wherever it happened to wake up.
    ///
    /// When the file runs out it loops, and says so in the trace. A run whose seam lands on a
    /// loop point is reading a discontinuity the harness introduced, not one the app did —
    /// hence the line, so that case is recognisable rather than mysterious.
    func start(sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let t = Thread { [self] in
            let chunkSeconds = Double(Self.framesPerChunk) / sampleRate
            let origin = Date()
            var index = 0
            var delivered = 0
            var loops = 0

            while true {
                lock.lock()
                let done = stopped
                lock.unlock()
                if done { break }

                let deadline = origin.addingTimeInterval(Double(delivered) * chunkSeconds)
                let wait = deadline.timeIntervalSinceNow
                // Only sleep when actually ahead. A negative interval means the thread was
                // descheduled past its slot; sleeping on it would compound the lateness.
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }

                // RE-CHECKED AFTER THE SLEEP, and this second read is not belt-and-braces.
                // `stop()` is called from `finishCapture`, which then removes the tap and
                // stops the recogniser. Checking only before the sleep left a ~21 ms window
                // in which `stop()` landed mid-sleep and this thread woke up and delivered
                // one more buffer into a capture that no longer existed — measurably, and
                // always exactly one: every headless run reported `capture stopped …
                // frames=2433024` against `AUTOSTART SUMMARY … frames=2434048`, a delta of
                // one 1024-frame buffer. Harmless downstream (`append` tolerates a retired
                // session) but it made the harness's own frame count differ from the
                // microphone path it is supposed to be indistinguishable from.
                lock.lock()
                let stoppedDuringSleep = stopped
                lock.unlock()
                if stoppedDuringSleep { break }

                sink(chunks[index])
                delivered += 1
                index += 1

                if index >= chunks.count {
                    index = 0
                    loops += 1
                    trace("SYNTH: source exhausted after \(String(format: "%.1f", sourceSeconds)) s "
                        + "— looping (loop \(loops)). A seam landing here reads a JOIN THE "
                        + "HARNESS MADE, not one the app made.")
                }
            }

            trace("SYNTH: stopped — fed \(delivered) buffers, "
                + String(format: "%.1f s of audio", Double(delivered) * chunkSeconds))
        }
        // Not `.userInteractive`: this thread must not outrank the audio and recogniser work
        // it is feeding. `.userInitiated` is late enough to be honest about scheduling and
        // early enough that a 21 ms deadline is comfortably met.
        t.qualityOfService = .userInitiated
        t.name = "MicTest.SyntheticAudioSource"
        lock.lock(); thread = t; lock.unlock()
        trace("SYNTH: feeding \(describeSource)")
        t.start()
    }

    /// Idempotent. Called from `finishCapture`, which can run more than once per capture.
    func stop() {
        lock.lock()
        stopped = true
        thread = nil
        lock.unlock()
    }
}
