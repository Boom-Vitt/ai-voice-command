import AVFoundation
import CryptoKit
import Foundation

/// Bounded comparison of chunk boundaries, with one frozen PCM stream for both caps.
@main
struct ChunkCapComparison {
    struct Manifest: Decodable {
        struct Clip: Codable { let file: String; let reference: String; let english: [String] }
        let clips: [Clip]
    }
    struct Phrase: Codable {
        let file: String
        let reference: String
        let english: [String]
        let startSeconds: Double
        let endSeconds: Double
    }
    struct Request: Codable {
        let scheme: String
        let repetition: Int
        let chunk: Int
        let seconds: Double
        let sha256: String
        let milliseconds: Double
        let text: String
    }
    struct Outcome: Codable {
        let scheme: String
        let repetition: Int
        let text: String
        let expectedEnglish: Int
        let retainedEnglish: Int
        let missingEnglish: [String]
        let expectedThaiScalars: Int
        let retainedThaiScalarsInOrder: Int
    }
    struct Report: Codable {
        let sourceWAV: String
        let port: Int
        let prompt: String
        let clientSHA256: String
        let gainSHA256: String
        let pipelineSHA256: String
        let pcmFrames: Int
        let stopAndPolledChunksByteIdentical: Bool
        let stoppedHashes: [String]
        let polledHashes: [String]
        let completePhrases: [Phrase]
        let scoring: String
        let requests: [Request]
        let outcomes: [Outcome]
    }
    enum Failure: Error { case invalid(String) }
    static let keyterms = ["deploy", "commit", "branch", "main", "refactor", "push", "merge", "rebase",
                           "pull request", "API", "database", "function", "variable", "debug", "build",
                           "test", "server", "client", "endpoint", "repository"]

    static func option(_ key: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: key), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func chunks(from url: URL, poll: Bool) throws -> [Data] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512) else {
            throw Failure.invalid("16 kHz mono required")
        }
        let pipeline = try AudioPipeline(inputFormat: file.processingFormat, mode: .localDictation)
        var result: [Data] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 512)
            guard buffer.frameLength > 0 else { break }
            pipeline.append(buffer)
            if poll { while let chunk = pipeline.takeChunk() { result.append(chunk.wav) } }
        }
        while let chunk = pipeline.flush() { result.append(chunk.wav) }
        return result
    }

    static func decodedFrames(_ url: URL) throws -> Int {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure.invalid("sample buffer unavailable")
        }
        try file.read(into: buffer)
        return Int(buffer.frameLength)
    }

    static func canonical(_ pcm: Data, template: Data) -> Data {
        var result = Data(template.prefix(44))
        func replace32(_ value: UInt32, at offset: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        replace32(UInt32(pcm.count + 36), at: 4)
        replace32(UInt32(pcm.count), at: 40)
        result.append(pcm)
        return result
    }

    static func thaiScalars(_ text: String) -> [UInt32] {
        text.unicodeScalars.filter { (0x0e00...0x0e7f).contains($0.value) }.map(\.value)
    }
    static func lcs(_ expected: [UInt32], _ actual: [UInt32]) -> Int {
        var previous = [Int](repeating: 0, count: actual.count + 1)
        for character in expected {
            var next = [Int](repeating: 0, count: actual.count + 1)
            for index in actual.indices {
                next[index + 1] = character == actual[index]
                    ? previous[index] + 1 : max(previous[index + 1], next[index])
            }
            previous = next
        }
        return previous.last ?? 0
    }
    static func score(_ text: String, phrases: [Phrase], scheme: String, repetition: Int) -> Outcome {
        var counts: [String: Int] = [:]
        for phrase in phrases { for word in phrase.english { counts[word, default: 0] += 1 } }
        var retained = 0, missing: [String] = []
        for (word, expected) in counts.sorted(by: { $0.key < $1.key }) {
            let pattern = "(?i)(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z])"
            let regex = try! NSRegularExpression(pattern: pattern)
            let found = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            retained += min(found, expected)
            missing += Array(repeating: word, count: max(0, expected - found))
        }
        let goldThai = thaiScalars(phrases.map(\.reference).joined())
        return Outcome(scheme: scheme, repetition: repetition, text: text,
                       expectedEnglish: counts.values.reduce(0, +), retainedEnglish: retained,
                       missingEnglish: missing, expectedThaiScalars: goldThai.count,
                       retainedThaiScalarsInOrder: lcs(goldThai, thaiScalars(text)))
    }

    static func main() async throws {
        let repo = URL(fileURLWithPath: option("--repo") ?? FileManager.default.currentDirectoryPath)
        guard let wavPath = option("--wav") else { throw Failure.invalid("--wav PATH required") }
        let source = URL(fileURLWithPath: wavPath)
        let port = Int(option("--port") ?? "8177") ?? 8177
        let cap20Only = CommandLine.arguments.contains("--cap20-only")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let output = repo.appending(path: "MicTest/build/local-transcription-integration-test/cap-comparison-\(stamp)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stopped = try chunks(from: source, poll: false)
        let polled = try chunks(from: source, poll: true)
        guard stopped.count == 2, let template = stopped.first else { throw Failure.invalid("expected two chunks under the 20 s cap") }
        let same = stopped == polled
        print("stop-only and polled chunks byte-identical: \(same)")
        var pcm = Data()
        for chunk in stopped { pcm.append(chunk.dropFirst(44)) }
        guard pcm.count == 24 * 16_000 * 2 else { throw Failure.invalid("source must retain exactly 24 s") }
        let ten = stride(from: 0, to: pcm.count, by: 10 * 16_000 * 2).map {
            canonical(Data(pcm[$0..<min($0 + 10 * 16_000 * 2, pcm.count)]), template: template)
        }
        for (label, list) in [("stopped20", stopped), ("polled20", polled), ("split10", ten)] {
            for (index, wav) in list.enumerated() {
                try wav.write(to: output.appending(path: "\(label)-\(index).wav"))
            }
        }
        let corpus = repo.appending(path: "thaiasr/corpus")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: corpus.appending(path: "manifest.json")))
        var phrases: [Phrase] = [], offset = 0
        while offset < 24 * 16_000 {
            for clip in manifest.clips {
                let frames = try decodedFrames(corpus.appending(path: clip.file))
                if offset + frames <= 24 * 16_000 {
                    phrases.append(Phrase(file: clip.file, reference: clip.reference, english: clip.english,
                                          startSeconds: Double(offset) / 16_000,
                                          endSeconds: Double(offset + frames) / 16_000))
                }
                offset += frames + 8_000
                if offset >= 24 * 16_000 { break }
            }
        }
        let client = LocalWhisperTranscriber(), clock = ContinuousClock()
        var requests: [Request] = [], outcomes: [Outcome] = []
        // Running capture selects a quiet seam; stop-time flush intentionally keeps
        // its hard cap. Probe the running path when validating seam selection.
        let schemes = cap20Only ? [("cap20-polled", polled)] : [("20+4", stopped), ("10+10+4", ten)]
        for repetition in 1...2 {
            for (scheme, list) in schemes {
                var texts: [String] = []
                for (index, wav) in list.enumerated() {
                    let began = clock.now
                    let text = try await client.transcribe(wav: wav, keyterms: keyterms, port: port)
                    let elapsed = began.duration(to: clock.now).components
                    let request = Request(scheme: scheme, repetition: repetition, chunk: index,
                                          seconds: Double(wav.count - 44) / 32_000, sha256: hash(wav),
                                          milliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15,
                                          text: text)
                    requests.append(request); texts.append(text)
                    print(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
                }
                outcomes.append(score(texts.joined(separator: " "), phrases: phrases, scheme: scheme, repetition: repetition))
            }
        }
        let report = Report(sourceWAV: source.path, port: port, prompt: LocalWhisperTranscriber.prompt(keyterms: keyterms),
                            clientSHA256: hash(try Data(contentsOf: repo.appending(path: "MicTest/Sources/MicTest/LocalWhisperTranscriber.swift"))),
                            gainSHA256: hash(try Data(contentsOf: repo.appending(path: "MicTest/Sources/MicTest/SpeechAudioGain.swift"))),
                            pipelineSHA256: hash(try Data(contentsOf: repo.appending(path: "MicTest/Sources/MicTest/AudioPipeline.swift"))),
                            pcmFrames: pcm.count / 2, stopAndPolledChunksByteIdentical: same,
                            stoppedHashes: stopped.map(hash), polledHashes: polled.map(hash), completePhrases: phrases,
                            scoring: "Only fully spoken phrase occurrences count. English exact token occurrences are capped at expected multiplicity. Thai retention is LCS over Thai Unicode scalars, ignoring spaces and Latin text; it measures retained order, not accuracy or extra-word penalties. The cut final phrase is excluded from the reference.",
                            requests: requests, outcomes: outcomes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportURL = output.appending(path: "report.json")
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        for outcome in outcomes {
            print("\(outcome.scheme) repeat\(outcome.repetition): English \(outcome.retainedEnglish)/\(outcome.expectedEnglish), Thai scalars \(outcome.retainedThaiScalarsInOrder)/\(outcome.expectedThaiScalars)")
        }
        print("REPORT \(reportURL.path)")
    }
}
