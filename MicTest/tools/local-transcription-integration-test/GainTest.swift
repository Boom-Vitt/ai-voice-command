import Foundation

@main
struct GainTest {
    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(samples.count * 2))
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return data
    }
    static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { bytes in
            stride(from: 44, to: bytes.count, by: 2).map {
                bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self).littleEndian
            }
        }
    }
    static func check(_ passed: Bool, _ name: String) {
        guard passed else { print("FAIL \(name)"); exit(1) }
        print("PASS \(name)")
    }
    static func main() {
        let quiet = wav(Array(repeating: [Int16(100), Int16(-100)], count: 800).flatMap { $0 })
        let normalized = SpeechAudioGain.normalize(quiet)
        check(normalized.prefix(44) == quiet.prefix(44) && normalized.count == quiet.count,
              "header and byte count preserved")
        let raised = samples(normalized)
        check(Set(raised) == Set<Int16>([1_311, -1_311]), "quiet RMS raised to target within PCM16 rounding")
        let tiny = wav([1, -1, 0])
        check(samples(SpeechAudioGain.normalize(tiny)) == [32, -32, 0], "gain capped at 32x and zero samples preserved")
        let transient = wav([Int16](repeating: 1, count: 9_999) + [20_000])
        let capped = samples(SpeechAudioGain.normalize(transient))
        check(capped.last == 26_214 && capped.map { abs(Int($0)) }.max() == 26_214, "output peak stays below 0.8")
        let negativeTransient = wav([Int16](repeating: -1, count: 9_999) + [-20_000])
        check(samples(SpeechAudioGain.normalize(negativeTransient)).last == -26_214, "negative peak uses same safe ceiling")
        let loudPeak = wav([Int16](repeating: 1, count: 9_999) + [30_000])
        check(SpeechAudioGain.normalize(loudPeak) == loudPeak, "low RMS with existing high peak is not attenuated")
        let normal = wav([Int16](repeating: 2_000, count: 160))
        check(SpeechAudioGain.normalize(normal) == normal, "already-normal audio byte-identical")
        let silence = wav([Int16](repeating: 0, count: 128_000))
        check(SpeechAudioGain.normalize(silence) == silence, "digital silence byte-identical")
        let empty = wav([])
        check(SpeechAudioGain.normalize(empty) == empty, "empty WAV unchanged")
        let extremes = wav([Int16.min, Int16.max])
        check(SpeechAudioGain.normalize(extremes) == extremes, "PCM16 extrema never overflow")
        let target = 100.0 / 32_768
        check(SpeechAudioGain.normalize(quiet, targetRMS: target) == quiet, "RMS at target is unchanged")
        check(SpeechAudioGain.normalize(quiet, maxGain: 1) == quiet, "unity maximum gain is unchanged")
        for offset in [0, 4, 8, 12, 16, 20, 22, 24, 28, 32, 34, 36, 40] {
            var malformed = quiet
            malformed[offset] ^= 1
            check(SpeechAudioGain.normalize(malformed) == malformed, "invalid header field at byte \(offset) unchanged")
        }
        let truncated = Data(quiet.dropLast())
        check(SpeechAudioGain.normalize(truncated) == truncated, "truncated odd data unchanged")
        let extra = quiet + Data([0, 0])
        check(SpeechAudioGain.normalize(extra) == extra, "undeclared trailing data unchanged")
        check(SpeechAudioGain.normalize(Data([1, 2, 3])) == Data([1, 2, 3]), "short input unchanged")
        for invalid in [Double.nan, Double.infinity, -Double.infinity, -1, 0] {
            check(SpeechAudioGain.normalize(quiet, targetRMS: invalid) == quiet, "invalid target \(invalid) unchanged")
            check(SpeechAudioGain.normalize(quiet, maxGain: invalid) == quiet, "invalid gain \(invalid) unchanged")
            check(SpeechAudioGain.normalize(quiet, peakCeiling: invalid) == quiet, "invalid ceiling \(invalid) unchanged")
        }
        var prefixed = Data([99])
        prefixed.append(quiet)
        check(SpeechAudioGain.normalize(prefixed.dropFirst()) == normalized, "nonzero-index Data slice handled safely")
        print("ALL GAIN CHECKS PASSED")
    }
}
