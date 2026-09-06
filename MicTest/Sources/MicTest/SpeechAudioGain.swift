import Foundation

/// Raises quiet, app-produced audio before model VAD. It neither classifies speech nor
/// filters transcript text. Normal audio and digital silence remain byte-identical.
enum SpeechAudioGain {
    /// Accepts only AudioPipeline's canonical 44-byte RIFF/WAVE header followed by
    /// little-endian 16 kHz mono PCM16. Extra chunks, inconsistent lengths, unsupported
    /// formats and invalid tuning values are returned unchanged, without guessing.
    static func normalize(_ wav: Data, targetRMS: Double = 0.04,
                          maxGain: Double = 32, peakCeiling: Double = 0.8) -> Data {
        guard targetRMS.isFinite, targetRMS > 0, targetRMS <= 1,
              maxGain.isFinite, maxGain >= 1,
              peakCeiling.isFinite, peakCeiling > 0, peakCeiling <= 1 else { return wav }
        let analysis: (rms: Double, peak: Double)? = wav.withUnsafeBytes { bytes in
            guard bytes.count >= 44,
                  let riffLength = UInt32(exactly: bytes.count - 8),
                  let dataLength = UInt32(exactly: bytes.count - 44), dataLength % 2 == 0 else { return nil }
            func u16(_ offset: Int) -> UInt16 {
                bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
            }
            func u32(_ offset: Int) -> UInt32 {
                bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
            guard u32(0) == 0x4646_4952,       // RIFF
                  u32(4) == riffLength,
                  u32(8) == 0x4556_4157,       // WAVE
                  u32(12) == 0x2074_6d66,     // fmt[space]
                  u32(16) == 16, u16(20) == 1, u16(22) == 1,
                  u32(24) == 16_000, u32(28) == 32_000,
                  u16(32) == 2, u16(34) == 16,
                  u32(36) == 0x6174_6164,     // data
                  u32(40) == dataLength, dataLength > 0 else { return nil }
            var sumSquares = 0.0, peak = 0.0
            for offset in stride(from: 44, to: bytes.count, by: 2) {
                let value = Double(Int16(bitPattern: u16(offset))) / 32_768
                sumSquares += value * value
                peak = max(peak, abs(value))
            }
            return ((sumSquares / Double(dataLength / 2)).squareRoot(), peak)
        }
        guard let analysis, analysis.rms > 0, analysis.rms < targetRMS, analysis.peak > 0 else { return wav }
        let gain = min(targetRMS / analysis.rms, maxGain, peakCeiling / analysis.peak)
        guard gain > 1 else { return wav }   // Never attenuate a peak or normal speech.
        // Floor the integer ceiling so rounding cannot exceed the requested peak cap.
        let peakLimit = Int((peakCeiling * 32_768).rounded(.down))
        guard peakLimit > 0 else { return wav }
        var amplified = wav
        amplified.withUnsafeMutableBytes { bytes in
            for offset in stride(from: 44, to: bytes.count, by: 2) {
                let sample = bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self).littleEndian
                let rounded = Int((Double(sample) * gain).rounded())
                let limited = min(Int(Int16.max), min(peakLimit, max(-peakLimit, rounded)))
                bytes.storeBytes(of: Int16(limited).littleEndian, toByteOffset: offset, as: Int16.self)
            }
        }
        return amplified
    }
}
