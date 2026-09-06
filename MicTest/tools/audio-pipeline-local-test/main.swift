import AVFoundation
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct PipelineTests {
    static var checks = 0
    static let rate = 16_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: Double(rate), channels: 1,
                                     interleaved: false)!

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try condition() else { throw TestFailure(description: message) }
    }

    /// A deterministic square wave gives each buffer an exact known RMS.
    /// These are transport/segmentation fixtures, not claimed ASR accuracy tests.
    static func signal(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int((seconds * Double(rate)).rounded())).map {
            $0 % 32 < 16 ? amplitude : -amplitude
        }
    }

    /// Exercise the real AVAudioConverter/append path in ordinary 100 ms buffers.
    /// At equal input/output rates the WAV samples must survive exactly.
    @discardableResult
    static func append(_ samples: [Float], to pipe: AudioPipeline,
                       poll: Bool = true) throws -> [AudioPipeline.Chunk] {
        var chunks: [AudioPipeline.Chunk] = []
        let step = 1_600
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(step)),
              let target = buffer.floatChannelData?[0] else {
            throw TestFailure(description: "could not allocate generated PCM fixture")
        }
        for offset in stride(from: 0, to: samples.count, by: step) {
            let count = min(step, samples.count - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                target.update(from: source.baseAddress!.advanced(by: offset), count: count)
            }
            pipe.append(buffer)
            if poll, let chunk = pipe.takeChunk() { chunks.append(chunk) }
        }
        return chunks
    }

    static func drained(_ pipe: AudioPipeline) -> [AudioPipeline.Chunk] {
        var chunks: [AudioPipeline.Chunk] = []
        while let chunk = pipe.flush() { chunks.append(chunk) }
        return chunks
    }

    static func verify(_ chunks: [AudioPipeline.Chunk], equal samples: [Float],
                       label: String) throws {
        var actualPCM = Data()
        for chunk in chunks {
            try check(chunk.isFinal, "\(label): local mode emitted an interim")
            try check(String(decoding: chunk.wav.prefix(4), as: UTF8.self) == "RIFF"
                      && String(decoding: chunk.wav[8..<12], as: UTF8.self) == "WAVE"
                      && String(decoding: chunk.wav[36..<40], as: UTF8.self) == "data",
                      "\(label): malformed PCM WAV header")
            try check(chunk.seconds == Double(chunk.wav.count - 44) / 2 / Double(rate),
                      "\(label): duration does not match emitted frames")
            actualPCM.append(chunk.wav.dropFirst(44))
        }
        let expectedPCM = AudioPipeline.encodeWAV(samples, count: samples.count).dropFirst(44)
        try check(actualPCM == expectedPCM,
                  "\(label): generated samples were lost, duplicated, reordered or modified")
    }

    static func quietSpeechSurvivesPolling() throws {
        let pipe = try AudioPipeline(inputFormat: format, mode: .localDictation)
        let quiet = signal(3, amplitude: 0.001)
        try check(try append(quiet, to: pipe).isEmpty,
                  "quiet audio should wait for VAD at cap/flush, without interim output")
        for _ in 0..<50 {
            try check(pipe.takeChunk() == nil, "poll without new input must not emit quiet audio")
        }
        let chunks = drained(pipe)
        try check(chunks.count == 1 && chunks[0].seconds == 3,
                  "quiet audio must survive repeated polling instead of pre-roll trimming")
        try verify(chunks, equal: quiet, label: "quiet speech")
        try check(pipe.flush() == nil, "repeated flush must not duplicate quiet audio")
        print("PASS: below-threshold audio survives polling and explicit flush")
    }

    static func quietOnsetAndNaturalBoundary() throws {
        let pipe = try AudioPipeline(inputFormat: format, mode: .localDictation)
        let quiet = signal(2, amplitude: 0.001)
        let speech = signal(0.4, amplitude: 0.04)
        let earlySilence = signal(0.5, amplitude: 0)
        let endingSilence = signal(0.1, amplitude: 0)
        try check(try append(quiet, to: pipe).isEmpty, "quiet onset must stay buffered")
        try check(try append(speech, to: pipe).isEmpty, "qualified speech is not yet an utterance end")
        try check(try append(earlySilence, to: pipe).isEmpty, "0.5 s silence must not end utterance")
        let chunks = try append(endingSilence, to: pipe)
        try check(chunks.count == 1 && chunks[0].seconds == 3,
                  "0.6 s natural boundary must include the complete quiet onset")
        try verify(chunks, equal: quiet + speech + earlySilence + endingSilence,
                   label: "natural boundary including quiet onset")
        try check(pipe.flush() == nil, "natural final must consume exactly its own audio")
        print("PASS: quiet onset preserved through the 0.6 s natural boundary")
    }

    static func shortWordsAndFlushFloor() throws {
        let pipe = try AudioPipeline(inputFormat: format, mode: .localDictation)
        let shortWord = signal(0.2, amplitude: 0.02)
        let silence = signal(0.8, amplitude: 0)
        try check(try append(shortWord + silence, to: pipe).isEmpty,
                  "sub-0.4 s RMS speech must be retained instead of cleared on silence")
        try verify(drained(pipe), equal: shortWord + silence, label: "short word before pause")

        let tooShort = signal(0.149, amplitude: 0.001)
        try append(tooShort, to: pipe)
        try check(pipe.flush() == nil, "below-0.15 s explicit flush floor must remain bounded")
        let minimum = signal(0.15, amplitude: 0.001)
        try append(minimum, to: pipe)
        try verify(drained(pipe), equal: minimum, label: "0.15 s flush floor")
        let singleWord = signal(0.2, amplitude: 0.04)
        try append(singleWord, to: pipe)
        try verify(drained(pipe), equal: singleWord, label: "short word on stop")
        print("PASS: short word retention and 0.15 s explicit stop threshold")
    }

    static func silenceAndLongAudio() throws {
        let pipe = try AudioPipeline(inputFormat: format, mode: .localDictation)
        let silence = signal(45, amplitude: 0)
        var chunks = try append(silence, to: pipe)
        try check(chunks.map(\.seconds) == [20, 20],
                  "all-silent input must be emitted at 20 s caps for downstream VAD")
        chunks += drained(pipe)
        try check(chunks.map(\.seconds) == [20, 20, 5], "stop must flush final silence remainder")
        try verify(chunks, equal: silence, label: "45 seconds of silence")

        let continuous = signal(41, amplitude: 0.03)
        chunks = try append(continuous, to: pipe)
        try check(chunks.map(\.seconds) == [20, 20],
                  "continuous speech must have final-only 20 s caps")
        chunks += drained(pipe)
        try verify(chunks, equal: continuous, label: "41 seconds continuous speech")
        print("PASS: silence sent intact to VAD and long speech capped without interims")
    }

    static func flushLeftoversAndRingWrap() throws {
        let pipe = try AudioPipeline(inputFormat: format, mode: .localDictation)
        // No polling: represent a consumer stall still inside the 30-second ring.
        let first = signal(19.9, amplitude: 0.001)
        let second = signal(7.4, amplitude: 0.0018)
        try append(first + second, to: pipe, poll: false)
        let chunks = drained(pipe)
        try check(chunks.map(\.seconds) == [20, 7.3],
                  "repeated flush must return both oldest cap and retained remainder")
        try verify(chunks, equal: first + second, label: "multiple flush leftovers")

        // The ring write position is now near its end; this next input wraps.
        let wrapped = signal(6.1, amplitude: 0.0015)
        try append(wrapped, to: pipe)
        try verify(drained(pipe), equal: wrapped, label: "ring wrap after stop")
        try append(signal(2, amplitude: 0.001), to: pipe)
        pipe.reset()
        try check(pipe.flush() == nil && pipe.level == 0, "reset must discard old capture and meter")
        let fresh = signal(0.3, amplitude: 0.002)
        try append(fresh, to: pipe)
        try verify(drained(pipe), equal: fresh, label: "fresh capture after reset")
        print("PASS: multiple flush leftovers, ring wrap and reset")
    }

    static func correctionBehaviorUnchanged() throws {
        let pipe = try AudioPipeline(inputFormat: format)
        try check(try append(signal(2, amplitude: 0.001), to: pipe).isEmpty,
                  "default mode must still trim idle quiet input")
        try check(pipe.flush() == nil, "default quiet pre-roll must stay below 0.4 s flush minimum")

        let speech = signal(1, amplitude: 0.04)
        let interim = try append(speech, to: pipe)
        try check(interim.count == 1 && !interim[0].isFinal && interim[0].seconds == 1,
                  "default correction mode must retain 1 s interim windows")
        try verify(drained(pipe), equal: speech, label: "correction interim does not consume audio")
        try append(signal(0.2, amplitude: 0.03), to: pipe)
        try check(pipe.flush() == nil, "default explicit flush minimum must remain 0.4 s")

        try append(signal(12, amplitude: 0.04), to: pipe, poll: false)
        let capped = drained(pipe)
        try check(capped.map(\.seconds) == [10, 2], "default chunk cap must remain 10 s")
        try verify(capped, equal: signal(12, amplitude: 0.04), label: "correction 10 s cap")
        let shortNoise = signal(0.3, amplitude: 0.03) + signal(0.6, amplitude: 0)
        try check(try append(shortNoise, to: pipe).isEmpty,
                  "default natural boundary must still reject short RMS noise")
        try check(pipe.flush() == nil, "default natural short-noise rejection must clear buffer")

        let explicit = try AudioPipeline(inputFormat: format, mode: .correction)
        let defaulted = try AudioPipeline(inputFormat: format)
        let fixture = signal(2, amplitude: 0) + signal(1.4, amplitude: 0.04)
            + signal(0.8, amplitude: 0) + signal(12, amplitude: 0.03)
            + signal(0.7, amplitude: 0)
        let a = try append(fixture, to: explicit) + drained(explicit)
        let b = try append(fixture, to: defaulted) + drained(defaulted)
        try check(a.count == b.count && zip(a, b).allSatisfy {
            $0.wav == $1.wav && $0.isFinal == $1.isFinal && $0.seconds == $1.seconds
        }, "omitted mode and explicit correction mode must produce identical output")
        print("PASS: correction default retains pre-roll, interim, minimums and 10 s cap")
    }

    static func capUsesRecentQuietSeam() throws {
        // A hard 20 s cap lands 300 ms into the second word. A 200 ms gap is too
        // short for natural finalization, but safely holds the cap seam.
        let input = signal(19.5, amplitude: 0.04) + signal(0.2, amplitude: 0)
            + signal(0.6, amplitude: 0.03)
        let pipe = try AudioPipeline(inputFormat: format, mode: .localDictation)
        let finals = try append(input, to: pipe)
        try check(finals.count == 1 && finals[0].seconds == 19.6,
                  "local cap must move into the recent gap before the next phoneme")
        try verify(finals + drained(pipe), equal: input, label: "cap gap with complete next word")

        let laterGap = signal(18.2, amplitude: 0.04) + signal(0.14, amplitude: 0)
            + signal(1.22, amplitude: 0.03) + signal(0.14, amplitude: 0)
            + signal(0.6, amplitude: 0.04)
        let latest = try AudioPipeline(inputFormat: format, mode: .localDictation)
        let chosen = try append(laterGap, to: latest)
        try check(chosen.count == 1 && chosen[0].seconds == 19.63,
                  "cap must prefer the latest qualifying gap, not an earlier gap")
        try verify(chosen + drained(latest), equal: laterGap, label: "latest gap seam")
        print("PASS: cap seam moves before the next phoneme using the latest quiet gap")
    }

    static func capGapEvidenceAndScale() throws {
        let tinyVoice = signal(19.6, amplitude: 0.001) + signal(0.16, amplitude: 0.00003)
            + signal(0.54, amplitude: 0.0012)
        let quiet = try AudioPipeline(inputFormat: format, mode: .localDictation)
        let moved = try append(tinyVoice, to: quiet)
        try check(moved.count == 1 && moved[0].seconds == 19.68,
                  "quiet scaled voice must use its much quieter gap, not a fixed RMS label")
        try verify(moved + drained(quiet), equal: tinyVoice, label: "scaled quiet voice seam")

        for gapSeconds in [0.119, 0.12] {
            let input = signal(19.6, amplitude: 0.04) + signal(gapSeconds, amplitude: 0)
                + signal(0.7 - gapSeconds, amplitude: 0.04)
            let pipe = try AudioPipeline(inputFormat: format, mode: .localDictation)
            let chunks = try append(input, to: pipe)
            let expected = gapSeconds == 0.12 ? 19.66 : 20.0
            try check(chunks.count == 1 && chunks[0].seconds == expected,
                      "cap requires at least 120 ms quiet evidence (gap \(gapSeconds))")
            try verify(chunks + drained(pipe), equal: input, label: "minimum gap evidence")
        }

        var interrupted = signal(19.6, amplitude: 0.04) + signal(0.16, amplitude: 0)
            + signal(0.54, amplitude: 0.04)
        // Its 10 ms frame RMS is low, but this narrow peak splits the gap into
        // two runs shorter than 120 ms and must not be treated as silence.
        interrupted[Int(19.665 * Double(rate))] = 0.02
        let plosive = try AudioPipeline(inputFormat: format, mode: .localDictation)
        let kept = try append(interrupted, to: plosive)
        try check(kept.count == 1 && kept[0].seconds == 20,
                  "a low-RMS frame with a phoneme peak must interrupt the quiet run")
        try verify(kept + drained(plosive), equal: interrupted, label: "peak-protected cap")
        print("PASS: adaptive quiet voice, 120 ms minimum and peak interruption")
    }

    static func capFallbackAndStopRemainUnchanged() throws {
        var clippedPeak = signal(20.3, amplitude: 0.001)
        // A loud transient must not raise the silence threshold enough to
        // classify the surrounding quiet, continuous voice as a gap.
        for sample in (19 * rate)..<(19 * rate + 160) { clippedPeak[sample] = 1 }
        let fixtures = [signal(20.3, amplitude: 0.001), signal(20.3, amplitude: 0.04),
                        signal(20.3, amplitude: 0), clippedPeak,
                        signal(17.6, amplitude: 0.04) + signal(0.2, amplitude: 0)
                            + signal(2.5, amplitude: 0.04)]
        for (index, input) in fixtures.enumerated() {
            let pipe = try AudioPipeline(inputFormat: format, mode: .localDictation)
            let chunks = try append(input, to: pipe)
            try check(chunks.count == 1 && chunks[0].seconds == 20,
                      "no suitable recent gap must retain the 20 s hard cap (fixture \(index))")
            try verify(chunks + drained(pipe), equal: input, label: "cap fallback \(index)")
        }
        let stoppedInput = signal(19.5, amplitude: 0.04) + signal(0.2, amplitude: 0)
            + signal(0.6, amplitude: 0.03)
        let stopped = try AudioPipeline(inputFormat: format, mode: .localDictation)
        try append(stoppedInput, to: stopped, poll: false)
        let flushed = drained(stopped)
        try check(flushed.map(\.seconds) == [20, 0.3],
                  "explicit stop must retain full capped chunks and existing tail rules")
        try verify(flushed, equal: stoppedInput, label: "stop ignores optional seam search")
        let correction = try AudioPipeline(inputFormat: format, mode: .correction)
        let legacy = try append(stoppedInput, to: correction).filter(\.isFinal) + drained(correction)
        try check(legacy.map(\.seconds) == [10, 10],
                  "correction cap and subminimum final-tail behavior must stay unchanged")
        print("PASS: hard-cap fallback, old gap exclusion, explicit stop and correction unchanged")
    }

    static func main() throws {
        try quietSpeechSurvivesPolling()
        try quietOnsetAndNaturalBoundary()
        try shortWordsAndFlushFloor()
        try silenceAndLongAudio()
        try flushLeftoversAndRingWrap()
        try correctionBehaviorUnchanged()
        try capUsesRecentQuietSeam()
        try capGapEvidenceAndScale()
        try capFallbackAndStopRemainUnchanged()
        print("ALL PASS (\(checks) checks)")
    }
}
