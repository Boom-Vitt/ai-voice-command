import AVFoundation
import CryptoKit
import Foundation

/// Exercises the production pipeline, final request and ordered queue using synthetic
/// WAV fixtures. It opens no microphone or UI and does not manage server processes.
@main
struct IntegrationTest {
    typealias Queue = LocalTranscriptionQueue<Payload, Transcript>

    struct Manifest: Decodable {
        struct Clip: Decodable {
            let file: String
            let reference: String
            let english: [String]
        }
        let clips: [Clip]
    }
    struct Payload: Sendable {
        let fixture: Int
        let wav: Data
        let seconds: Double
    }
    struct Transcript: Codable, Sendable {
        let fixture: Int
        let capture: Int
        let chunk: Int
        let audioSeconds: Double
        let requestMilliseconds: Double
        let text: String
        let error: String?
    }
    struct Fixture: Codable {
        let name: String
        let kind: String
        let path: String
        let reference: String
        let expectedEnglish: [String]
        let gain: Float
        let pollWhileFeeding: Bool
    }
    struct CaptureReport: Codable {
        let fixture: Fixture
        let capture: Int
        let inputFrames: Int
        let outputFrames: Int
        let maxBufferRMS: Float
        let flushChunks: Int
        let chunks: Int
        var text = ""
        var preservedEnglish: [String] = []
        var missingEnglish: [String] = []
        var exactReference = false
    }
    struct Check: Codable {
        let name: String
        let passed: Bool
    }
    struct Report: Codable {
        let generatedAt: String
        let testMode: String
        let serverURL: String
        let corpus: String
        let fixtureOrigin: String
        let effectivePrompt: String
        let sourceSHA256: [String: String]
        let captures: [CaptureReport]
        let requests: [Transcript]
        let deliveryOrder: [String]
        let checks: [Check]
        let seedEnglishPreserved: Int
        let seedEnglishExpected: Int
        let seedExactReferences: Int
        let seedCount: Int
        let quietTextNonempty: Bool
        let passed: Bool
    }
    enum Failure: Error { case invalid(String) }

    static let keyterms = [
        "deploy", "commit", "branch", "main", "refactor", "push", "merge", "rebase",
        "pull request", "API", "database", "function", "variable", "debug", "build",
        "test", "server", "client", "endpoint", "repository",
    ]

    static func option(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func decodedSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure.invalid("fixture must be 16 kHz mono: \(url.path)")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw Failure.invalid("Float32 unavailable") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw Failure.invalid("WAV buffer unavailable") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    static func maximumBlockRMS(_ samples: [Float]) -> Float {
        stride(from: 0, to: samples.count, by: 512).map { offset -> Float in
            let block = samples[offset..<min(offset + 512, samples.count)]
            let sum = block.reduce(Float(0)) { $0 + $1 * $1 }
            return sqrt(sum / Float(block.count))
        }.max() ?? 0
    }

    static func prepareFixtures(corpus: URL, output: URL, manifest: Manifest) throws -> [Fixture] {
        var fixtures = manifest.clips.map {
            Fixture(name: $0.file, kind: "seed", path: corpus.appending(path: $0.file).path,
                    reference: $0.reference, expectedEnglish: $0.english, gain: 1, pollWhileFeeding: true)
        }
        guard let first = manifest.clips.first else { throw Failure.invalid("empty seed manifest") }
        let firstSamples = try decodedSamples(corpus.appending(path: first.file))
        let gain = min(Float(1), 0.0015 / max(maximumBlockRMS(firstSamples), Float.leastNonzeroMagnitude))
        let quiet = output.appending(path: "quiet-scaled-cs1.wav")
        try writeWAV(firstSamples.map { $0 * gain }, to: quiet)
        fixtures.append(Fixture(name: quiet.lastPathComponent, kind: "quiet", path: quiet.path,
                                reference: first.reference, expectedEnglish: first.english,
                                gain: gain, pollWhileFeeding: true))
        for seconds in [3, 8] {
            let silence = output.appending(path: "silence-\(seconds)s.wav")
            try writeWAV([Float](repeating: 0, count: seconds * 16_000), to: silence)
            fixtures.append(Fixture(name: silence.lastPathComponent, kind: "silence", path: silence.path,
                                    reference: "", expectedEnglish: [], gain: 1, pollWhileFeeding: true))
        }
        var noiseState: UInt64 = 0x4d69_6354_6573_74
        let whiteNoise: [Float] = (0..<48_000).map { _ in
            noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1
            let unit = Double(noiseState >> 11) / Double(UInt64.max >> 11)
            return Float((unit * 2 - 1) * 0.03 * sqrt(3))
        }
        let hum: [Float] = (0..<48_000).map { frame in
            Float(sin(Double(frame) * 2 * Double.pi * 60 / 16_000) * 0.03 * sqrt(2))
        }
        for (name, samples) in [("white-noise-rms03", whiteNoise), ("hum-60hz-rms03", hum)] {
            let url = output.appending(path: "\(name).wav")
            try writeWAV(samples, to: url)
            fixtures.append(Fixture(name: name, kind: "noise", path: url.path,
                                    reference: "", expectedEnglish: [], gain: 1, pollWhileFeeding: true))
        }
        var phraseSequence: [Float] = []
        for clip in manifest.clips {
            phraseSequence += try decodedSamples(corpus.appending(path: clip.file))
            phraseSequence += [Float](repeating: 0, count: 8_000)
        }
        var longSamples: [Float] = []
        while longSamples.count < 24 * 16_000 { longSamples += phraseSequence }
        longSamples = Array(longSamples.prefix(24 * 16_000))
        let long = output.appending(path: "multi-chunk-24s.wav")
        try writeWAV(longSamples, to: long)
        for polling in [false, true] {
            fixtures.append(Fixture(name: polling ? "multi-chunk-polled" : "multi-chunk-stop-drain",
                                    kind: polling ? "multi-polled" : "multi-drain", path: long.path,
                                    reference: "", expectedEnglish: [], gain: 1, pollWhileFeeding: polling))
        }
        return fixtures
    }

    static func capture(_ fixture: Fixture, index: Int, queue: inout Queue) throws -> CaptureReport {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixture.path),
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512) else {
            throw Failure.invalid("input must be 16 kHz mono")
        }
        let pipeline = try AudioPipeline(inputFormat: file.processingFormat, mode: .localDictation)
        let capture = try queue.beginCapture()
        var inputFrames = 0, outputFrames = 0, chunks = 0, flushChunks = 0
        var maxRMS: Float = 0
        func enqueue(_ chunk: AudioPipeline.Chunk, queue: inout Queue) throws {
            guard chunk.isFinal else { throw Failure.invalid("local pipeline emitted interim audio") }
            _ = try queue.enqueue(Payload(fixture: index, wav: chunk.wav, seconds: chunk.seconds),
                                  byteCount: chunk.wav.count, in: capture)
            outputFrames += (chunk.wav.count - 44) / 2
            chunks += 1
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 512)
            guard buffer.frameLength > 0 else { break }
            inputFrames += Int(buffer.frameLength)
            pipeline.append(buffer)
            maxRMS = max(maxRMS, pipeline.level)
            if fixture.pollWhileFeeding {
                while let chunk = pipeline.takeChunk() { try enqueue(chunk, queue: &queue) }
            }
        }
        // The app must drain repeatedly after stopping. The 24 s fixture proves one
        // flush is insufficient: local chunks cap at 20 s while the ring holds 30 s.
        while let chunk = pipeline.flush() {
            try enqueue(chunk, queue: &queue)
            flushChunks += 1
        }
        queue.stopCapture(capture)
        return CaptureReport(fixture: fixture, capture: capture.sequence, inputFrames: inputFrames,
                             outputFrames: outputFrames, maxBufferRMS: maxRMS,
                             flushChunks: flushChunks, chunks: chunks)
    }

    static func containsEnglish(_ term: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        return text.range(of: "(?i)(?<![A-Za-z])" + escaped + "(?![A-Za-z])",
                          options: .regularExpression) != nil
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
    }

    static func main() async throws {
        let repo = URL(fileURLWithPath: option("--repo") ?? FileManager.default.currentDirectoryPath,
                       isDirectory: true)
        let port = Int(option("--port") ?? "18181") ?? 18181
        guard (1...65535).contains(port) else { throw Failure.invalid("invalid server port") }
        let corpus = URL(fileURLWithPath: option("--corpus") ?? repo.appending(path: "thaiasr/corpus").path,
                         isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let output = URL(fileURLWithPath: option("--output") ?? repo
            .appending(path: "MicTest/build/local-transcription-integration-test/run-\(stamp)").path,
                         isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: corpus.appending(path: "manifest.json")))
        var fixtures = try prepareFixtures(corpus: corpus, output: output, manifest: manifest)
        let probeName = option("--probe-fixture")
        let repetitions = Int(option("--repeat") ?? "5") ?? 5
        if let probeName {
            guard (1...12).contains(repetitions),
                  let fixture = fixtures.first(where: { $0.name == probeName && $0.kind == "seed" }) else {
                throw Failure.invalid("probe requires a seed fixture and repeat count 1...12")
            }
            fixtures = Array(repeating: fixture, count: repetitions)
        }
        var sourceHashes: [String: String] = [:]
        for name in ["AudioPipeline.swift", "LocalWhisperTranscriber.swift", "SpeechAudioGain.swift", "LocalTranscriptionQueue.swift", "RefuseRedirects.swift"] {
            let data = try Data(contentsOf: repo.appending(path: "MicTest/Sources/MicTest/\(name)"))
            sourceHashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        var queue = Queue(limits: .init(captures: 16, chunks: 128, inputBytes: 32 * 1024 * 1024))
        var captures: [CaptureReport] = []
        for (index, fixture) in fixtures.enumerated() {
            captures.append(try capture(fixture, index: index, queue: &queue))
        }
        var work: [Queue.Work] = []
        while let next = queue.nextWork() { work.append(next) }
        let seedBytesUnchanged = work.filter { fixtures[$0.payload.fixture].kind == "seed" }
            .allSatisfy { SpeechAudioGain.normalize($0.payload.wav) == $0.payload.wav }
        print("\(seedBytesUnchanged ? "PASS" : "FAIL") every normal seed PCM16 chunk is byte-identical after gain")
        let identicalProbeInputs = probeName == nil || Set(work.map {
            SHA256.hash(data: $0.payload.wav).map { String(format: "%02x", $0) }.joined()
        }).count == 1
        if probeName != nil, let first = work.first {
            try first.payload.wav.write(to: output.appending(path: "probe-input.wav"), options: .atomic)
            print("\(identicalProbeInputs ? "PASS" : "FAIL") repeated probe uses one identical WAV payload")
        }
        if CommandLine.arguments.contains("--gain-proof-only") {
            if !seedBytesUnchanged { exit(1) }
            return
        }
        let client = LocalWhisperTranscriber()
        let clock = ContinuousClock()
        var requests: [Transcript] = []
        for item in work {
            let began = clock.now
            let text: String, failure: String?
            do {
                text = try await client.transcribe(wav: item.payload.wav, keyterms: keyterms, port: port)
                failure = nil
            } catch {
                text = ""
                failure = String(describing: error)
            }
            let result = Transcript(fixture: item.payload.fixture, capture: item.id.capture.sequence,
                                    chunk: item.id.sequence, audioSeconds: item.payload.seconds,
                                    requestMilliseconds: milliseconds(began.duration(to: clock.now)),
                                    text: text, error: failure)
            requests.append(result)
            let encoded = try JSONEncoder().encode(result)
            print(String(decoding: encoded, as: UTF8.self))
        }
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool) { checks.append(Check(name: name, passed: passed)) }
        check("normal seed PCM16 chunks byte-identical after gain", seedBytesUnchanged)
        if probeName != nil { check("all repeated probe inputs byte-identical", identicalProbeInputs) }
        check("all inference requests succeeded", requests.allSatisfy { $0.error == nil })
        // Deliver actual provider results in reverse completion order; the queue must
        // retain them until the earlier capture/chunk is complete, then release once.
        for index in work.indices.reversed() {
            check("completion accepted \(index)", queue.complete(work[index].id,
                  with: .success(requests[index])) == .accepted)
            if index > 0 { check("later completion held \(index)", queue.takeReadyEvents().isEmpty) }
        }
        var deliveryOrder: [String] = []
        var drained: [Int] = []
        var delivered: [String] = []
        for event in queue.takeReadyEvents() {
            switch event {
            case .result(let id, let outcome):
                let key = "\(id.capture.sequence):\(id.sequence)"
                deliveryOrder.append(key)
                delivered.append(key)
                if case .success(let result) = outcome {
                    if !result.text.isEmpty {
                        if !captures[result.fixture].text.isEmpty { captures[result.fixture].text += " " }
                        captures[result.fixture].text += result.text
                    }
                }
            case .captureDrained(let id):
                drained.append(id.sequence)
                deliveryOrder.append("drained:\(id.sequence)")
            }
        }
        check("results delivered in capture/chunk order", delivered == work.map { "\($0.id.capture.sequence):\($0.id.sequence)" })
        check("all stopped captures drained exactly once", drained == captures.map(\.capture))
        check("queue fully released", queue.pendingChunkCount == 0 && queue.pendingInputBytes == 0 && queue.pendingCaptureCount == 0)
        check("second drain produces no duplicate events", queue.takeReadyEvents().isEmpty)
        for index in captures.indices {
            captures[index].preservedEnglish = captures[index].fixture.expectedEnglish.filter {
                containsEnglish($0, in: captures[index].text)
            }
            captures[index].missingEnglish = captures[index].fixture.expectedEnglish.filter {
                !containsEnglish($0, in: captures[index].text)
            }
            captures[index].exactReference = captures[index].text == captures[index].fixture.reference
            let capture = captures[index]
            if capture.fixture.kind == "silence" || capture.fixture.kind == "noise" {
                check("\(capture.fixture.name) reached VAD with all samples", capture.chunks > 0 && capture.outputFrames == capture.inputFrames)
                check("\(capture.fixture.name) empty transcript", capture.text.isEmpty)
            }
            if capture.fixture.kind == "quiet" {
                check("quiet speech stays below RMS boundary threshold", capture.maxBufferRMS < 0.0025)
                check("quiet speech preserved through explicit flush", capture.outputFrames == capture.inputFrames && capture.flushChunks > 0)
                check("quiet speech English terms preserved after gain and VAD",
                      !capture.fixture.expectedEnglish.isEmpty && capture.missingEnglish.isEmpty)
            }
            if capture.fixture.kind == "multi-drain" {
                check("24 s stop drains two capped chunks", capture.flushChunks == 2 && capture.chunks == 2)
                check("24 s stop preserves every sample", capture.outputFrames == capture.inputFrames)
            }
            if capture.fixture.kind == "multi-polled" {
                check("polled multi-utterance capture produces multiple chunks", capture.chunks >= 2)
                check("polled capture loses at most subminimum final tail", capture.inputFrames - capture.outputFrames < 2_400)
            }
        }
        let seed = captures.filter { $0.fixture.kind == "seed" }
        let preserved = seed.reduce(0) { $0 + $1.preservedEnglish.count }
        let expected = seed.reduce(0) { $0 + $1.fixture.expectedEnglish.count }
        let expectedTerms = probeName == nil ? 8 : (fixtures.first?.expectedEnglish.count ?? 0) * repetitions
        check("all expected seed English terms preserved", expected == expectedTerms && preserved == expected)
        let report = Report(generatedAt: ISO8601DateFormatter().string(from: Date()),
                            testMode: probeName.map { "repeat \($0) x\(repetitions)" } ?? "full integration",
                            serverURL: "http://127.0.0.1:\(port)/inference", corpus: corpus.path,
                            fixtureOrigin: "Synthetic Kanya seed; derived quiet and concatenated audio; generated digital silence",
                            effectivePrompt: LocalWhisperTranscriber.prompt(keyterms: keyterms),
                            sourceSHA256: sourceHashes, captures: captures, requests: requests,
                            deliveryOrder: deliveryOrder, checks: checks,
                            seedEnglishPreserved: preserved, seedEnglishExpected: expected,
                            seedExactReferences: seed.filter(\.exactReference).count, seedCount: seed.count,
                            quietTextNonempty: captures.contains { $0.fixture.kind == "quiet" && !$0.text.isEmpty },
                            passed: checks.allSatisfy(\.passed))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportURL = output.appending(path: "report.json")
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        for check in checks where !check.passed { print("FAIL \(check.name)") }
        print("\(report.passed ? "PASS" : "FAIL") integration: seed English \(preserved)/\(expected), exact references \(report.seedExactReferences)/\(seed.count); report \(reportURL.path)")
        if !report.passed { exit(1) }
    }
}
