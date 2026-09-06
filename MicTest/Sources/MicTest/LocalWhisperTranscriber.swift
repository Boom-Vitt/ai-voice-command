import Foundation

/// Primary transcription against MicTest's owned whisper.cpp 1.9.2 runtime.
/// The VAD model is required by the manager. Text is returned once, without
/// transliteration rules, glossary substitution or phrase blacklists.
struct LocalWhisperTranscriber: Sendable {
    enum Failure: Error, LocalizedError {
        case invalidReply
        case status(Int)
        var errorDescription: String? {
            switch self {
            case .invalidReply: return "Local transcription returned an invalid reply"
            case .status(let code): return "Local transcription failed (HTTP \(code))"
            }
        }
    }

    /// Whisper's segment line breaks are not dictated document newlines. Remove only
    /// those separators; existing spaces still separate Latin words across segments.
    static func joiningSegments(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prompt(keyterms: [String]) -> String {
        var terms: [String] = []
        var bytes = 0
        for term in keyterms {
            let clean = term.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !clean.isEmpty else { continue }
            let size = clean.utf8.count + (terms.isEmpty ? 0 : 1)
            guard bytes + size <= 800 else { break }
            terms.append(clean)
            bytes += size
        }
        return terms.joined(separator: " ")
    }

    func transcribe(wav: Data, keyterms: [String], port: Int) async throws -> String {
        let boundary = "MicTestFinal" + UUID().uuidString
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        let fields = [
            ("language", "th"), ("translate", "false"),
            ("temperature", "0"), ("temperature_inc", "0"),
            ("best_of", "5"), ("beam_size", "5"),
            ("no_timestamps", "true"), ("token_timestamps", "false"),
            ("response_format", "json"), ("prompt", Self.prompt(keyterms: keyterms)),
            ("vad", "true"), ("vad_threshold", "0.35"),
            ("vad_speech_pad_ms", "500"), ("vad_min_silence_duration_ms", "500")
        ]
        for (key, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(SpeechAudioGain.normalize(wav))
        append("\r\n--\(boundary)--\r\n")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration,
                                 delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidReply }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw Failure.invalidReply }
        return Self.joiningSegments(text)
    }
}
