import Foundation

/// `Transcriber` backed by a resident local `whisper-server` (whisper.cpp) on
/// 127.0.0.1. Audio never leaves the machine.
///
/// The multipart body is assembled by hand — no third-party dependencies — and
/// posted to `POST /inference` with `response_format=json`, which answers
/// `{"text": "..."}`.
///
/// Per the `Transcriber` contract this type **never throws**: every failure is
/// returned as a `TranscriptionResult` whose `error` is one short, actionable
/// sentence.
///
/// The type is `Sendable`: all stored properties are immutable, and every piece
/// of mutable state lives inside the `WhisperServerManager` actor.
final class LocalTranscriber: Transcriber, Sendable {

    /// Conservative bound on the initial-prompt field.
    ///
    /// whisper's prompt window is `n_text_ctx / 2 = 224` tokens; anything past
    /// that is silently dropped by the decoder, and an over-long prompt eats
    /// the context the model needs for the utterance itself. Budgeting ~4 UTF-8
    /// bytes per token gives ~896; 800 leaves headroom, and using *bytes* keeps
    /// the estimate conservative for non-ASCII terms.
    static let maxPromptBytes = 800

    /// Wall-clock ceiling for one `/inference` call. Comfortably covers a 15 s
    /// utterance (measured: 5.7 s audio → 1.15 s warm) without hanging forever.
    static let requestTimeout: TimeInterval = 30

    let engine: Engine = .localWhisper

    private let manager: WhisperServerManager
    private let session: URLSession
    /// Seconds to wait for the model to load on first use.
    private let readinessTimeout: TimeInterval

    /// - Parameters:
    ///   - manager: server lifecycle owner. Defaults to the process-wide instance.
    ///   - readinessTimeout: how long a first request may wait for the 3.1 GB
    ///     model load (default 60 s).
    ///   - session: injectable for testing; defaults to an ephemeral session
    ///     configured with ``requestTimeout``.
    init(manager: WhisperServerManager = .shared,
         readinessTimeout: TimeInterval = 60,
         session: URLSession? = nil) {
        self.manager = manager
        self.readinessTimeout = readinessTimeout
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = Self.requestTimeout
            cfg.timeoutIntervalForResource = Self.requestTimeout + 15
            cfg.waitsForConnectivity = false
            cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            cfg.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: cfg)
        }
    }

    /// True when the local server is listening and has its model resident.
    ///
    /// Does not start the server — call `WhisperServerManager.start()` /
    /// `waitUntilReady(timeout:)` for that, or just call ``transcribe(_:)``,
    /// which starts it on demand.
    func isReady() async -> Bool {
        await manager.isHealthy()
    }

    /// Transcribe one 16 kHz mono WAV.
    ///
    /// Starts or adopts the server if it is not already up, POSTs the audio,
    /// and returns the recognised text. `latencyMS` covers the HTTP exchange
    /// only — not the model load, and not the server start.
    ///
    /// `promptApplied` is `true` only when a non-empty glossary actually went
    /// out as the `prompt` field.
    func transcribe(_ req: TranscriptionRequest) async -> TranscriptionResult {
        func fail(_ message: String, latencyMS: Int = 0, promptApplied: Bool = false) -> TranscriptionResult {
            TranscriptionResult(text: "", engine: .localWhisper, latencyMS: latencyMS,
                                promptApplied: promptApplied, error: message)
        }

        if Task.isCancelled { return fail("cancelled before transcription started") }

        // 1. Audio must exist and be non-trivial.
        let audioData: Data
        do {
            audioData = try Data(contentsOf: req.audioURL, options: [.mappedIfSafe])
        } catch {
            return fail("cannot read audio at \(req.audioURL.path): \(error.localizedDescription)")
        }
        guard audioData.count > 44 else {
            return fail("audio file is empty (\(audioData.count) bytes) — nothing was recorded")
        }

        // 2. Prompt: capped, joined, never cut mid-term.
        let prompt = Self.promptString(from: req.glossary)
        let promptApplied = !prompt.isEmpty

        // 3. Server up (starts or adopts on demand).
        let endpoint: URL
        do {
            endpoint = try await manager.ensureReady(timeout: readinessTimeout)
        } catch is CancellationError {
            return fail("cancelled while starting whisper-server", promptApplied: false)
        } catch let error as WhisperServerError {
            return fail("local whisper unavailable — \(error.description)", promptApplied: false)
        } catch {
            return fail("local whisper unavailable — \(error.localizedDescription)", promptApplied: false)
        }

        // 4. POST, with one retry if the connection is refused mid-flight
        //    (server died between the health probe and the request).
        let body = Self.multipartBody(audio: audioData,
                                      filename: req.audioURL.lastPathComponent,
                                      language: req.language ?? "auto",
                                      prompt: promptApplied ? prompt : nil)

        var elapsedMS = 0
        var lastTransportError: String?

        for attempt in 0..<2 {
            if Task.isCancelled { return fail("cancelled", latencyMS: elapsedMS, promptApplied: promptApplied) }

            var target = endpoint
            if attempt == 1 {
                // Re-resolve: a restart may have moved us to another port.
                if let refreshed = try? await manager.ensureReady(timeout: readinessTimeout) {
                    target = refreshed
                } else {
                    return fail("whisper-server died and could not be restarted (\(lastTransportError ?? "connection refused"))",
                                latencyMS: elapsedMS, promptApplied: promptApplied)
                }
            }

            var request = URLRequest(url: target)
            request.httpMethod = "POST"
            request.timeoutInterval = Self.requestTimeout
            request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.data.count), forHTTPHeaderField: "Content-Length")
            request.httpBody = body.data

            let clock = ContinuousClock()
            let started = clock.now
            do {
                let (data, response) = try await session.data(for: request)
                elapsedMS += Self.milliseconds(started.duration(to: clock.now))

                guard let http = response as? HTTPURLResponse else {
                    return fail("whisper-server returned a non-HTTP response", latencyMS: elapsedMS, promptApplied: promptApplied)
                }
                guard (200..<300).contains(http.statusCode) else {
                    let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return fail("whisper-server HTTP \(http.statusCode)\(snippet.isEmpty ? "" : ": \(snippet)")",
                                latencyMS: elapsedMS, promptApplied: promptApplied)
                }
                guard let text = Self.parseText(data) else {
                    let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return fail("could not parse whisper-server reply: \(snippet)",
                                latencyMS: elapsedMS, promptApplied: promptApplied)
                }
                return TranscriptionResult(text: text, engine: .localWhisper, latencyMS: elapsedMS,
                                           promptApplied: promptApplied, error: nil)
            } catch is CancellationError {
                elapsedMS += Self.milliseconds(started.duration(to: clock.now))
                return fail("cancelled", latencyMS: elapsedMS, promptApplied: promptApplied)
            } catch let urlError as URLError {
                elapsedMS += Self.milliseconds(started.duration(to: clock.now))
                switch urlError.code {
                case .cancelled:
                    return fail("cancelled", latencyMS: elapsedMS, promptApplied: promptApplied)
                case .timedOut:
                    return fail("whisper-server did not answer within \(Int(Self.requestTimeout))s — the utterance may be too long",
                                latencyMS: elapsedMS, promptApplied: promptApplied)
                case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .badServerResponse:
                    lastTransportError = urlError.localizedDescription
                    continue      // retry once, after re-ensuring the server
                default:
                    return fail("whisper-server request failed: \(urlError.localizedDescription)",
                                latencyMS: elapsedMS, promptApplied: promptApplied)
                }
            } catch {
                elapsedMS += Self.milliseconds(started.duration(to: clock.now))
                return fail("whisper-server request failed: \(error.localizedDescription)",
                            latencyMS: elapsedMS, promptApplied: promptApplied)
            }
        }

        return fail("whisper-server refused the connection twice (\(lastTransportError ?? "unknown"))",
                    latencyMS: elapsedMS, promptApplied: promptApplied)
    }

    // MARK: - Helpers (internal for testability)

    /// Join a glossary into whisper's `prompt` field.
    ///
    /// Terms are trimmed, de-duplicated case-insensitively, joined with `", "`,
    /// and truncated **on a term boundary** once the running length would pass
    /// ``maxPromptBytes``. A half term would bias the decoder toward a fragment,
    /// which is worse than dropping it.
    static func promptString(from glossary: [String], maxBytes: Int = maxPromptBytes) -> String {
        var kept: [String] = []
        var seen = Set<String>()
        var length = 0
        for raw in glossary {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { continue }
            let cost = term.utf8.count + (kept.isEmpty ? 0 : 2)   // ", "
            if length + cost > maxBytes { break }                 // stop on a whole term
            kept.append(term)
            length += cost
        }
        return kept.joined(separator: ", ")
    }

    /// Hand-rolled `multipart/form-data` body for `POST /inference`.
    ///
    /// cpp-httplib's parser is strict: CRLF line endings everywhere, a CRLF
    /// after the raw file bytes, and a closing `--boundary--`.
    static func multipartBody(audio: Data,
                              filename: String,
                              language: String,
                              prompt: String?) -> (data: Data, boundary: String) {
        let boundary = "----PhayaVoice\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let crlf = "\r\n"
        var body = Data()

        func appendString(_ string: String) {
            body.append(Data(string.utf8))
        }
        func appendField(_ name: String, _ value: String) {
            appendString("--\(boundary)\(crlf)")
            appendString("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
            appendString("\(value)\(crlf)")
        }

        // File part first, mirroring `curl -F file=@...`.
        let safeName = filename.isEmpty ? "audio.wav" : filename
        appendString("--\(boundary)\(crlf)")
        appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\(crlf)")
        appendString("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(audio)
        appendString(crlf)

        appendField("language", language)
        appendField("response_format", "json")
        if let prompt, !prompt.isEmpty {
            appendField("prompt", prompt)
        }
        appendString("--\(boundary)--\(crlf)")
        return (body, boundary)
    }

    /// Pull `text` out of `{"text": "..."}`, trimmed.
    static func parseText(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let text = object["text"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000) + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
