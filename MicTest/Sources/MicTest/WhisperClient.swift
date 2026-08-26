import Foundation

/// Minimal HTTP client for a resident local `whisper-server` (whisper.cpp).
///
/// # The server this talks to
///
/// This client does **not** own or start a server. It expects one already
/// running, launched exactly like this:
///
/// ```
/// /opt/homebrew/bin/whisper-server \
///     -m ~/.cache/hyperframes/whisper/models/ggml-large-v3.bin \
///     --host 127.0.0.1 --port 8177 -l th
/// ```
///
/// Two consequences of that invocation matter to every caller:
///
/// * **The model is `ggml-large-v3`.** It is accurate but not instant — a few
///   seconds of audio can legitimately take several seconds to come back. See
///   ``requestTimeout``.
/// * **The language is fixed to `th` (Thai) at server start.** whisper.cpp
///   binds `-l` when the process launches; the per-request `language` form
///   field does *not* override it. We still send `language=th` so the request
///   agrees with the server rather than silently disagreeing with it, but
///   changing that string here will not change the decode language. To
///   transcribe another language you must restart the server with a different
///   `-l`.
///
/// Audio never leaves the machine: everything goes to `127.0.0.1`.
///
/// # Wire format
///
/// `POST /inference`, `multipart/form-data`, with the raw WAV as the `file`
/// part and `response_format=json`. The reply is `{"text": "..."}`. This shape
/// is copied verbatim from `PhayaVoice/Sources/PhayaVoice/LocalTranscriber.swift`,
/// which is already proven against this exact server — do not "improve" it
/// without testing against a live server first.
///
/// # Concurrency
///
/// `Sendable`, with no mutable stored state and no actor isolation of any kind.
/// Every method is safe to call from any background `Task`; nothing here
/// touches the main actor or any UI.
struct WhisperClient: Sendable {

    // MARK: - Public types

    /// One successful round trip.
    struct Result: Sendable {
        /// Transcribed text, trimmed. **Empty** when the model heard no speech
        /// (see ``WhisperClient/speechText(from:)``) — that is a normal outcome
        /// during live capture, not an error.
        let text: String
        /// Wall-clock milliseconds for the whole HTTP exchange, measured on
        /// this side of the wire.
        let elapsedMS: Double
    }

    enum ClientError: Error, LocalizedError {
        /// Nothing answered on the port, or the connection dropped / timed out.
        case unreachable
        /// The server answered, but not with 2xx.
        case httpStatus(Int)
        /// HTTP 200 with a zero-byte body — the server answered but said
        /// nothing at all. (A *transcript* of "" is not this; that is a normal
        /// ``Result`` with an empty ``Result/text``.)
        case emptyResponse
        /// The body could not be parsed as `{"text": ...}`. Payload carries a
        /// short snippet of what actually arrived.
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .unreachable:
                return "whisper-server is not answering on 127.0.0.1 — is it running?"
            case .httpStatus(let code):
                return "whisper-server returned HTTP \(code)"
            case .emptyResponse:
                return "whisper-server returned an empty response body"
            case .decoding(let snippet):
                return "could not parse whisper-server reply: \(snippet)"
            }
        }
    }

    // MARK: - Tuning constants

    /// Wall-clock ceiling for one `/inference` call.
    ///
    /// Deliberately generous. `ggml-large-v3` is a 3.1 GB model; a warm server
    /// answers a few seconds of Thai in roughly 1–3 s, but a busy machine or a
    /// longer utterance can push well past that. A short timeout here shows up
    /// to the user as "transcription randomly fails", which is far worse than
    /// waiting. 30 s is long enough to never fire in normal use and short
    /// enough that a wedged server does not hang the app forever.
    static let requestTimeout: TimeInterval = 30

    /// Timeout for ``isReachable()``. A liveness probe must answer fast or not
    /// at all — on loopback, anything slower than this is effectively down.
    static let probeTimeout: TimeInterval = 2

    /// The language the server was started with (`-l th`). Sent for agreement
    /// only; it cannot override the server-side setting. See the type doc.
    static let serverLanguage = "th"

    // MARK: - Stored state (all immutable)

    /// Loopback port the server is listening on.
    let port: Int

    /// `POST` target. Precomputed so the hot path allocates nothing extra.
    private let inferenceURL: URL
    /// Identity/health probe target (`GET /`).
    private let rootURL: URL
    /// One ephemeral session for the life of this client. Ephemeral so nothing
    /// is ever written to a cache or cookie store on disk.
    private let session: URLSession

    // MARK: - Init

    init(port: Int = 8177) {
        self.port = port
        // Force-unwrap is safe: the only interpolated value is an Int.
        self.inferenceURL = URL(string: "http://127.0.0.1:\(port)/inference")!
        self.rootURL = URL(string: "http://127.0.0.1:\(port)/")!

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.requestTimeout
        cfg.timeoutIntervalForResource = Self.requestTimeout + 15
        cfg.waitsForConnectivity = false           // loopback: fail fast, never queue
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Transcription

    /// POST one 16 kHz mono 16-bit WAV and return what whisper heard.
    ///
    /// An empty ``Result/text`` means "no speech in this audio" and is an
    /// ordinary result — silence during live capture must not throw.
    ///
    /// - Important: **Do not POST silent buffers.** This model does not report
    ///   silence, it invents plausible speech for it (measured: 3 s of zeros
    ///   reliably yields `โปรดติดตามตอนต่อไป`, low-level noise yields
    ///   `สวัสดีครับ ทุกคน`). ``speechText(from:)`` catches the ones that are
    ///   unambiguous, but it cannot catch a hallucination that reads like a
    ///   normal sentence. Gate on RMS energy or a VAD before calling this.
    ///
    /// - Throws: ``ClientError`` for transport, status, and parse failures.
    ///   `CancellationError` / `URLError.cancelled` propagate unchanged so a
    ///   cancelled `Task` is never mistaken for a dead server.
    func transcribe(wav: Data) async throws -> Result {
        let body = Self.multipartBody(wav: wav,
                                      filename: "audio.wav",
                                      language: Self.serverLanguage)

        var request = URLRequest(url: inferenceURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("multipart/form-data; boundary=\(body.boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body.data

        let clock = ContinuousClock()
        let started = clock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }
            throw ClientError.unreachable
        }
        let elapsedMS = Self.milliseconds(started.duration(to: clock.now))

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decoding("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode)
        }
        // A truly empty body is a different failure from an empty transcript.
        guard !data.isEmpty else { throw ClientError.emptyResponse }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["text"] as? String else {
            throw ClientError.decoding(Self.snippet(data))
        }

        return Result(text: Self.speechText(from: raw), elapsedMS: elapsedMS)
    }

    // MARK: - Health

    /// Is a whisper server actually answering on this port?
    ///
    /// whisper.cpp's httplib stamps `Server: whisper.cpp` on **every** response
    /// including 404s, so `GET /` is a reliable identity probe — it proves we
    /// are talking to whisper and not to some unrelated service that happened
    /// to grab the port. Because whisper.cpp binds the port only after the
    /// model finishes loading, a positive probe also means the model is
    /// resident and ready.
    ///
    /// Never throws; returns `false` for every failure, and gives up after
    /// ``probeTimeout`` seconds.
    func isReachable() async -> Bool {
        var request = URLRequest(url: rootURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.probeTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if let server = http.value(forHTTPHeaderField: "Server"),
               server.localizedCaseInsensitiveContains("whisper") {
                return true
            }
            // Fallback for builds that omit the header: the served index page.
            return String(decoding: data.prefix(2048), as: UTF8.self)
                .localizedCaseInsensitiveContains("whisper.cpp")
        } catch {
            return false
        }
    }

    // MARK: - Non-speech filtering

    /// Exact whole-string outputs that mean "the model heard no speech".
    ///
    /// Compared case-insensitively against the trimmed, newline-joined text.
    /// Extend this list freely — that is the intended maintenance point.
    ///
    /// **The bar for adding an entry:** a phrase a human might plausibly say
    /// into the microphone does **not** belong here. Filtering a real
    /// utterance is a worse bug than showing a spurious one, because the user
    /// can see and ignore a spurious line but cannot recover a swallowed one.
    ///
    /// Two kinds of entry live here:
    ///
    /// * *Sound annotations* (`[BLANK_AUDIO]`, `(silence)`, `[Music]`, …) —
    ///   what whisper emits on silence in many configurations. Note that this
    ///   server does **not** emit them; see ``speechText(from:)``.
    /// * *Silence hallucinations* — fluent sentences the model invents when
    ///   fed no speech. These are model- and language-specific and must be
    ///   measured, not guessed. The Thai entries below were observed from this
    ///   exact server; see ``speechText(from:)`` for the reproduction.
    private static let nonSpeechExactTags: Set<String> = [
        "[blank_audio]",
        "[silence]",
        "(silence)",
        "[music]",
        "(music)",
        "[sound]",
        "[noise]",
        "[inaudible]",
        "[no speech]",
        "*ดนตรี*",
        "(ดนตรี)",
        "[ดนตรี]",
        "ดนตรี",
        "(เสียงเพลง)",
        "[เสียงเพลง]",
        "(ไม่มีเสียง)",

        // --- Measured silence hallucinations (ggml-large-v3, -l th) ---
        // "Please stay tuned for the next episode" — a TV/YouTube end-card
        // stock phrase baked into the training data. Emitted verbatim for
        // digital silence of any length (verified at 1 s, 3 s and 5 s of
        // zero samples, identical every time). Nobody says this into a
        // voice-command microphone, so it is safe to drop.
        "โปรดติดตามตอนต่อไป",
        // English equivalents of the same end-card artifact, for when the
        // server is restarted with a different -l.
        // UNVERIFIED: these are well-known whisper artifacts carried over from
        // general reports, *not* measured against this server (which runs
        // -l th). Confirm them before relying on them.
        "thank you for watching",
        "thanks for watching!",
        "thank you for watching!",
        "subscribe to my channel",
    ]

    /// Character pairs that delimit a whisper sound annotation, e.g.
    /// `[BLANK_AUDIO]`, `(silence)`, `[Music]`, `*ดนตรี*`, `♪♪♪`.
    ///
    /// Defensive coverage. **This server does not produce these** — see
    /// ``speechText(from:)`` — but other models, other `-l` settings and other
    /// whisper.cpp builds do, and stripping them costs nothing.
    private static let annotationDelimiters: [(open: Character, close: Character)] = [
        ("[", "]"),
        ("(", ")"),
        ("*", "*"),
        ("<", ">"),
        ("♪", "♪"),
    ]

    /// Normalise whisper's text and blank it out entirely if it is not speech.
    ///
    /// # What this server actually does on silence — read before editing
    ///
    /// The common wisdom is that whisper answers silence with `[BLANK_AUDIO]`.
    /// **That is not what this server does.** Measured against the live
    /// `ggml-large-v3` / `-l th` instance:
    ///
    /// | input (16 kHz mono)          | `text` returned      |
    /// |------------------------------|----------------------|
    /// | 1 s / 3 s / 5 s of zeros     | `โปรดติดตามตอนต่อไป`     |
    /// | 3 s of low-amplitude noise   | `สวัสดีครับ ทุกคน`       |
    ///
    /// Both are fluent, well-formed Thai with no annotation markup anywhere.
    /// The first is a stock end-card phrase and is filtered by name. The second
    /// ("hello everyone") is **deliberately not filtered**: it is an ordinary
    /// greeting a user could genuinely speak, and no amount of string
    /// inspection can tell the hallucinated one from the real one — the
    /// information simply is not in the text.
    ///
    /// So treat this function as a last line of defence, not a solution. The
    /// real fix belongs upstream in the audio pipeline: gate on RMS energy (or
    /// a VAD) and never POST a buffer that has no speech in it. A silent buffer
    /// that is never sent cannot be hallucinated over.
    ///
    /// # What it does
    ///
    /// 1. Joins whisper's per-segment newlines (see below) and trims — whisper
    ///    habitually returns a leading space and a trailing newline.
    /// 2. Blanks an exact match against ``nonSpeechExactTags``.
    /// 3. Blanks text that is nothing but sound annotations and punctuation —
    ///    `[BLANK_AUDIO]`, `♪♪♪`, `(silence) (silence)`, a bare `...`. This
    ///    generalises: a *new* bracketed tag is filtered without being listed.
    ///
    /// Text that mixes speech with an annotation (`สวัสดีครับ [Music]`) is kept
    /// **whole** — dropping real words to tidy up an annotation would be worse
    /// than leaving the annotation in.
    ///
    /// - Returns: the normalised transcript, or `""` when there was no speech.
    ///   An empty return is a normal outcome, never an error.
    static func speechText(from raw: String) -> String {
        let trimmed = joiningSegments(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if nonSpeechExactTags.contains(trimmed.lowercased()) { return "" }

        // Strip every delimited annotation, then see whether any real character
        // survives. If not, the whole utterance was annotation/punctuation.
        let residue = strippingAnnotations(trimmed)
        let hasRealContent = residue.contains { character in
            !character.isWhitespace && !character.isPunctuation && !character.isSymbol
        }
        return hasRealContent ? trimmed : ""
    }

    /// Collapse whisper's per-segment newlines into one flowing line.
    ///
    /// whisper.cpp joins decoded segments with `\n`, so a single utterance can
    /// come back split mid-phrase. Observed from this server:
    ///
    /// ```
    /// "สวัสดีครับ วันนี้อากาศดีมาก ผมกําลังทดสอบระบบรู้จําเสียงภาษา\nไทย\n"
    /// ```
    ///
    /// That break falls *inside* the word ภาษาไทย. A live transcript is one
    /// line, so the newlines have to go — and they must be removed, not
    /// replaced with a space, or Thai words get split by a space that was
    /// never spoken.
    ///
    /// This assumes whisper carries any needed leading space **inside** the
    /// segment (it does for space-delimited languages), so plain removal keeps
    /// word boundaries correct in both cases. The trailing
    /// double-space collapse cleans up the seam when it does.
    private static func joiningSegments(_ text: String) -> String {
        let joined = text
            .replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        // Tidy any doubled space created at a segment seam.
        return joined.replacingOccurrences(of: "  ", with: " ")
    }

    /// Remove `[...]`, `(...)`, `*...*`, `<...>` and `♪...♪` spans.
    ///
    /// Scans once, left to right. An unclosed opener consumes the rest of the
    /// string, which is the behaviour we want: a truncated `[BLANK_AUD` is
    /// still not speech.
    ///
    /// - Note: `*` and `♪` are their own closer, so a *stray* leading one
    ///   (`*สวัสดีครับ`) swallows the remainder and the text is judged
    ///   non-speech. This is the one path here that can discard real words.
    ///   It only affects the empty/non-empty decision — the caller either gets
    ///   the original text untouched or gets `""`, never a mangled string —
    ///   and this server has not been observed to emit such markup at all. If
    ///   it ever becomes a problem, require a matching close for the
    ///   symmetric delimiters rather than widening the tag list.
    private static func strippingAnnotations(_ text: String) -> String {
        var output = ""
        var closer: Character?

        for character in text {
            if let expected = closer {
                if character == expected { closer = nil }
                continue                                   // inside an annotation
            }
            if let match = annotationDelimiters.first(where: { $0.open == character }) {
                closer = match.close
                continue
            }
            output.append(character)
        }
        return output
    }

    // MARK: - Multipart

    /// Hand-rolled `multipart/form-data` body for `POST /inference`.
    ///
    /// Built as `Data`, never as a `String`: the WAV bytes are binary and any
    /// text encoding round trip would corrupt them.
    ///
    /// cpp-httplib's multipart parser is strict, and every one of these details
    /// is load-bearing:
    ///
    /// * `\r\n` everywhere — **not** `\n`. A body with bare LF parses as a
    ///   single malformed part, and whisper then transcribes nothing and
    ///   returns an empty `text` with a cheerful HTTP 200. That silent-empty
    ///   result is the single most common way this integration breaks.
    /// * a blank line (a second CRLF) after each part's headers;
    /// * a CRLF after the raw file bytes, before the next `--boundary`;
    /// * a closing `--boundary--`.
    ///
    /// The file part comes first, mirroring `curl -F file=@... -F language=...`,
    /// which is the ordering the server is known to accept.
    static func multipartBody(wav: Data,
                              filename: String,
                              language: String) -> (data: Data, boundary: String) {
        let boundary = "----MicTest\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let crlf = "\r\n"
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        func appendField(_ name: String, _ value: String) {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
            append("\(value)\(crlf)")
        }

        let safeName = filename.isEmpty ? "audio.wav" : filename
        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\(crlf)")
        append("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(wav)
        append(crlf)

        appendField("language", language)
        appendField("response_format", "json")

        append("--\(boundary)--\(crlf)")
        return (body, boundary)
    }

    // MARK: - Small helpers

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }

    /// First 200 bytes of a bad reply, for error messages.
    private static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
