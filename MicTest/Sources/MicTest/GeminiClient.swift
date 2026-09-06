import Foundation

/// Cloud accuracy pass: **Google Gemini** (`gemini-3.5-flash`), audio in, Thai
/// transcript out.
///
/// The *second* opinion in the dictation path. Apple's on-device recognizer
/// runs live and types as you speak; this runs afterwards in someone else's
/// datacenter and returns better Thai, in particular keeping English technical
/// terms ("deploy", "commit", "branch main") intact inside a Thai sentence.
///
/// It supersedes an earlier fal Scribe v2 client, which has since been deleted
/// from the tree. On the measured clip below Gemini was verbatim-perfect on Thai
/// in ~4.0 s — the same latency class the fal path managed (~3–3.5 s), from a
/// provider the rest of this account already uses. The shared pieces the two
/// clients had in common now live in ``CloudKeyFile``.
///
/// # Wire format
///
/// ```
/// POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent
/// x-goog-api-key: <GOOGLE_API_KEY>
/// Content-Type: application/json
///
/// { "contents": [ { "parts": [
///     { "text": "<prompt>" },
///     { "inline_data": { "mime_type": "audio/wav", "data": "<base64 wav>" } }
/// ] } ] }
/// ```
///
/// Details on that request that are load-bearing, each established against the
/// live API rather than read off a doc page:
///
/// * **The key goes in the `x-goog-api-key` *header*, never the `?key=` query
///   parameter.** Both authenticate. Only one of them keeps the secret out of
///   URLs, and URLs are the part of a request that gets written down — proxy
///   access logs, `URLError` descriptions, crash reports, anything that prints
///   a request line. A header is not logged by default anywhere in that chain.
///   Do not "simplify" this to a query parameter.
/// * **`inline_data` / `mime_type` are snake_case here.** The v1beta REST
///   surface also accepts the camelCase spellings, but snake_case is what was
///   verified working and is what the JSON examples in Google's own audio docs
///   use. Both spellings are fine; this one is tested.
/// * **The audio is inlined as base64, not uploaded first.** No Files API
///   round trip, no handle to manage, no cleanup. Expect the on-wire payload to
///   be about 4/3 the size of the WAV buffer.
/// * **There is no `keyterms` field.** fal took a bias-vocabulary array; Gemini
///   has no equivalent, so the caller's key terms go into the *prompt* instead
///   (see ``transcribe(wav:keyterms:)``). That is the only place they can go.
///
/// # Measured behaviour
///
/// A 9.46 s, 302 KB, 16 kHz mono WAV → **~4.0 s round trip, 234 AUDIO tokens**,
/// transcript verbatim-perfect on Thai. Timeouts below are sized from that.
///
/// # The surprising one: `parts[0]` can be an empty object
///
/// **Measured, repeatedly:** a perfectly normal 200 can carry
/// `"parts": [ {} ]` — an empty object with no `text` key at all — while
/// `finishReason` is `"STOP"` and the request bills normally. `candidates` may
/// likewise be absent entirely.
///
/// That is the model saying *it heard nothing*, and this client treats it as
/// exactly that: an **empty transcript**, with the real `elapsedMS` and token
/// counts still reported, because the request really did happen and really was
/// billed. It is **not** a decoding error and must **never** become a crash.
/// This is the single most surprising behaviour of the endpoint and the one a
/// future reader is most likely to "fix" into a force-unwrap. Don't. The whole
/// response type below is optional at every level for this reason; the
/// discriminator that remains is *`JSONDecoder` threw* → ``ClientError/decoding(_:)``
/// (a proxy's HTML page, a truncated body), *`JSONDecoder` succeeded with no
/// text* → empty transcript.
///
/// # Measured negative results — do not retry these
///
/// Recorded so nobody spends the afternoon again:
///
/// * **`gemini-3.5-transcribe` returns an empty part for every request shape
///   tried**: with and without a text prompt, PCM and WAV, `v1` and `v1beta`.
///   It additionally rejects system instructions with *"Developer instruction
///   is not enabled for this model"*. It is not a drop-in for the flash model.
/// * **`gemini-3.5-transcribe-live` over the bidi WebSocket** produced its
///   first transcript only after **25 s** of realtime-paced audio — WITH THE
///   MODEL'S OWN VAD LEFT ON, which is the whole of that result and was not
///   stated when this paragraph was first written. It read as "the streaming
///   model is unusable"; it actually means "letting the model decide its own
///   turn boundaries is unusable".
///
///   ``GeminiLiveRecognizer`` is the disproof. With
///   `automaticActivityDetection.disabled = true` and turns closed by this
///   app on a measured silence run, the same model answers **0.30 s** after
///   each close at **97.6%** character accuracy on Thai. Closing turns on a
///   fixed 2 s timer instead gives the same 0.30 s but only 89%, because a
///   timer cuts mid-word — so the silence alignment, not the streaming, is
///   what makes it work.
///
///   Consequence for THIS file: the live path is now a user-selectable
///   choice, not a foregone conclusion. Apple's on-device recognizer remains
///   the DEFAULT — it is the only engine that keeps every sample on this Mac,
///   and the only one that types word-by-word rather than phrase-by-phrase —
///   but it is no longer the only option, and this paragraph must not be
///   quoted as evidence that it has to be.
///
/// # Response
///
/// ```json
/// { "candidates": [ { "content": { "parts": [ { "text": "…" } ] },
///                     "finishReason": "STOP" } ],
///   "usageMetadata": { "promptTokenCount": 246, "totalTokenCount": 246,
///     "promptTokensDetails": [ { "modality": "TEXT",  "tokenCount": 12 },
///                              { "modality": "AUDIO", "tokenCount": 234 } ] } }
/// ```
///
/// `candidatesTokenCount` appears only when output was actually produced —
/// another reason nothing here may be required. Errors are
/// `{"error":{"code":400,"message":"…","status":"…"}}` with the HTTP status
/// matching `error.code`; 400, 403 and 429 have all been observed.
///
/// # The API key
///
/// Read at init from `~/.config/thaidictate/env`, a `chmod 600` one-liner file
/// carrying a `GOOGLE_API_KEY=…` line. The parser is
/// ``CloudKeyFile/loadKey(from:name:)``; it is not duplicated here. Any other
/// provider's line in that file is simply not matched — `name:` is required, so
/// reading the wrong one is a compile error rather than a runtime leak. The key is never
/// logged, never interpolated into an error, and is scrubbed out of every
/// string that escapes. If you add a new error path, keep it that way.
///
/// # Concurrency
///
/// `Sendable`, no actor isolation, no mutable shared state, no UI. Safe to call
/// from a detached background `Task` — which is the only way it is ever called,
/// since a 4 s round trip has no business on the main actor.
struct GeminiClient: Sendable {

    // MARK: - Public types

    /// One successful round trip.
    ///
    /// A ``Result`` with an empty ``text`` is a legitimate outcome, not a
    /// failure: see the note on empty `parts[0]` in the type documentation. The
    /// token counts and ``elapsedMS`` are still real in that case — the request
    /// was made and billed — which is what makes an empty transcript
    /// distinguishable from a request that never happened.
    struct Result: Sendable {
        /// The transcript, trimmed of surrounding whitespace and newlines.
        /// Empty when the model produced no text.
        let text: String
        /// Wall-clock milliseconds for the whole round trip, measured on this
        /// side of the wire with a monotonic clock — the same basis
        /// ``WhisperClient`` uses, so every `elapsedMS` in this app is
        /// comparable with every other.
        let elapsedMS: Double
        /// `usageMetadata.promptTokensDetails` entry whose `modality` is
        /// `"AUDIO"`. `0` when the field is absent. This is the number that
        /// scales with utterance length, so it is the one worth watching.
        let audioTokens: Int
        /// `usageMetadata.totalTokenCount`. `0` when the field is absent.
        let totalTokens: Int
    }

    enum ClientError: Error, LocalizedError {
        /// No usable `GOOGLE_API_KEY` on disk. Payload is the path we looked
        /// at, so the message can tell the user exactly what to create.
        case missingKey(String)
        /// The API answered, but not with 2xx. Payload is the status and a
        /// truncated, key-scrubbed prefix of the response body.
        case http(Int, String)
        /// 2xx whose body was not JSON at all. Payload is a short snippet of
        /// what actually arrived. Note this does **not** cover a well-formed
        /// response that carried no text — that is an empty transcript.
        case decoding(String)
        /// The request never completed — offline, DNS, TLS, timeout.
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingKey(let path):
                return """
                    No GOOGLE_API_KEY found. Add a line to \(path) reading \
                    `GOOGLE_API_KEY=<your Google AI Studio key>`, then \
                    `chmod 600` it.
                    """
            case .http(let status, let body):
                return "Gemini returned HTTP \(status): \(body)"
            case .decoding(let snippet):
                return "Could not parse the Gemini response: \(snippet)"
            case .transport(let reason):
                return "Could not reach Gemini: \(reason)"
            }
        }
    }

    // MARK: - Tunables

    /// The model. Named separately from ``endpoint`` because it is the thing a
    /// reader will want to change, and because the two negative results in the
    /// type documentation are about *other* values of exactly this constant.
    static let model = "gemini-3.5-flash"

    /// The `generateContent` endpoint, built from ``model`` so the two cannot
    /// drift apart. Synchronous — it holds the connection open and answers with
    /// the transcript, so there is no job/poll cycle to run.
    static let endpoint = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/models/"
            + GeminiClient.model + ":generateContent"
    )!

    /// The header Google's key auth uses. Not a query parameter — see the type
    /// documentation for why that distinction is not cosmetic.
    private static let apiKeyHeader = "x-goog-api-key"

    /// Which assignment in the env file holds the key.
    static let keyName = "GOOGLE_API_KEY"

    /// Seconds to wait for the transcript before giving up.
    ///
    /// 15 s, inherited from the fal client this replaced rather than invented
    /// here: the measured round trip is ~4.0 s (fal's was ~3.5 s), so 15 s buys
    /// ~4x headroom for a long utterance, a slow uplink, or a busy region. The
    /// reasoning that set that number applies unchanged —
    /// this is a delayed accuracy pass, a correction that lands tens of seconds
    /// late targets text the caret has long moved past, and main.swift allows
    /// only ONE of these in flight at a time, so a hung request silently blocks
    /// every subsequent correction until it resolves. Fail fast, free the gate.
    static let requestTimeout: TimeInterval = 15

    /// Ceiling on the whole transfer (`timeoutIntervalForResource`): the
    /// request timeout plus a little slack for a response already trickling in.
    /// Kept nearly as tight as ``requestTimeout``, for the same reason — while
    /// this runs, the one-in-flight gate in main.swift is held.
    static let resourceTimeout: TimeInterval = 20

    /// MIME type of the inlined audio. The caller hands us complete WAV bytes.
    private static let audioMIMEType = "audio/wav"

    /// The `modality` value whose token count we surface as
    /// ``Result/audioTokens``.
    private static let audioModality = "AUDIO"

    /// How much of a failing response body to keep in ``ClientError/http(_:_:)``.
    /// 400 characters: enough to read Google's
    /// `{"error":{"message": …}}`, short enough not to dump a page of HTML from
    /// some intermediate proxy into a log line.
    private static let errorBodyPrefix = 400

    // MARK: - The prompt
    //
    // Short and fixed on purpose. This model's output is only as reproducible
    // as its instruction: a prompt that drifts between builds — or grows an
    // unbounded key-term list appended to it — produces transcripts that drift
    // with it, and then a regression in the typed text has two candidate causes
    // instead of one. Change it only deliberately.

    /// First half of the standing instruction: what to do with the audio.
    private static let promptHead = """
        Transcribe this audio verbatim in Thai. Keep any English words exactly \
        as spoken, in Latin script.
        """

    /// Prefix for the key-term line, emitted only when the caller supplied
    /// terms. Gemini has no bias-vocabulary field, so this is the whole
    /// mechanism — the terms are spelling hints inside the instruction.
    private static let keytermsPrefix = "Use these exact spellings if you hear them: "

    /// Second half: the output contract, and **always the last thing the model
    /// reads** — the key-term line goes between the two halves, never after
    /// this one.
    ///
    /// That ordering is not cosmetic. With a hint line appended *after* "If
    /// there is no speech, output nothing", a model that heard nothing can
    /// plausibly echo the word list back as its answer, and an echoed word list
    /// is indistinguishable downstream from a real transcript — whereas the
    /// empty string it should have produced is a case this client handles
    /// explicitly. Keep the contract last.
    private static let promptTail = """
        Output only the transcript text: no commentary, no translation, no \
        punctuation you did not hear, no quotation marks, no formatting. If \
        there is no speech, output nothing.
        """

    // MARK: - Stored state

    /// The API key. Immutable, never logged, never rendered into an error.
    private let apiKey: String

    /// One ephemeral session for the life of this client. Ephemeral so no part
    /// of a request carrying the user's key or audio is ever written to a disk
    /// cache, cookie jar, or credential store.
    private let session: URLSession

    // MARK: - Init

    /// Loads the key from `~/.config/thaidictate/env`.
    ///
    /// - Throws: ``ClientError/missingKey(_:)`` if the file does not exist, is
    ///   unreadable, or contains no `GOOGLE_API_KEY=` assignment.
    init() throws {
        try self.init(keyFileURL: Self.defaultKeyFileURL())
    }

    /// Designated init, parameterised on the key file so it can be pointed at a
    /// fixture. Production callers use ``init()``.
    init(keyFileURL: URL) throws {
        // The error is translated rather than propagated, so that a caller
        // catching `GeminiClient.ClientError.missingKey` matches. `CloudKeyFile`
        // throws its own `KeyFileError.missingKey`, which now names the variable
        // that was actually missing — it is no longer wrong, merely a different
        // type. `name:` is required by that API; see CloudKeyFile.swift for why
        // it has no default.
        do {
            self.apiKey = try CloudKeyFile.loadKey(from: keyFileURL, name: Self.keyName)
        } catch {
            throw ClientError.missingKey(keyFileURL.path)
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.requestTimeout
        cfg.timeoutIntervalForResource = Self.resourceTimeout
        cfg.waitsForConnectivity = false     // fail and report, never queue silently
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: cfg)
    }

    /// True when a key was loaded successfully.
    ///
    /// Always true on a live instance: ``init()`` throws rather than
    /// constructing an unconfigured client. It exists so call sites can ask the
    /// question without caring how the answer is arrived at.
    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Key loading

    /// `~/.config/thaidictate/env` — **the same file** every cloud client reads.
    ///
    /// Delegated rather than re-derived from a second copy of the path
    /// components, so "same file" holds by construction and cannot drift if
    /// that location ever moves.
    static func defaultKeyFileURL() -> URL {
        CloudKeyFile.defaultURL()
    }

    // MARK: - Transcription

    /// Send one complete WAV and return what Gemini heard.
    ///
    /// - Parameters:
    ///   - wav: Complete 16 kHz mono 16-bit WAV bytes, header included. The
    ///     bytes are base64'd into an `inline_data` part (see the type
    ///     documentation), so expect the on-wire payload to be about 4/3 the
    ///     size of this buffer.
    ///   - keyterms: Technical words the model would otherwise transliterate
    ///     into Thai. Gemini has **no bias-vocabulary field**, so unlike fal's
    ///     `keyterms` array these are folded into the prompt as spelling hints;
    ///     that is the only place they can go. Pass as many as you like.
    /// - Returns: The transcript, the measured round-trip time, and the token
    ///   counts. An empty ``Result/text`` means the model heard nothing — a
    ///   normal outcome, not a failure. See the type documentation.
    func transcribe(wav: Data, keyterms: [String]) async throws -> Result {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The one place the key touches the wire. A header, never the URL —
        // nothing else reads `apiKey` except the scrubber in `redacting(_:)`.
        request.setValue(apiKey, forHTTPHeaderField: Self.apiKeyHeader)

        let payload = RequestBody(contents: [
            RequestBody.Content(parts: [
                RequestBody.Part(text: Self.prompt(keyterms: keyterms), inlineData: nil),
                RequestBody.Part(
                    text: nil,
                    inlineData: RequestBody.InlineData(
                        mimeType: Self.audioMIMEType,
                        data: wav.base64EncodedString()
                    )
                )
            ])
        ])

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            // Encoding a struct of Strings should not fail; if it somehow does,
            // report it without echoing the body — the body holds the audio.
            throw ClientError.transport("could not encode the request body")
        }

        let clock = ContinuousClock()
        let started = clock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // `localizedDescription` on a URLError describes the transport
            // ("The request timed out"); it never contains our headers. The
            // redaction is belt-and-braces, and cheap.
            throw ClientError.transport(Self.snippet(of: redacting(error.localizedDescription)))
        }

        // Measured before any branching, so the number means "time on the wire"
        // and not "time on the wire plus however much parsing we then did".
        let elapsedMS = Self.milliseconds(started.duration(to: clock.now))

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            // Google's errors are `{"error":{"code","message","status"}}` and
            // the HTTP status matches `error.code`, so the snippet is the part
            // that actually says what was wrong.
            throw ClientError.http(status, bodySnippet(of: data))
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            // Reachable only for a body that is not this JSON *at all* — a
            // proxy's HTML page, a truncated stream. Every field of
            // `ResponseBody` is optional, so a valid-but-empty answer decodes
            // successfully and falls through to the empty transcript below.
            throw ClientError.decoding(bodySnippet(of: data))
        }

        return Result(
            text: Self.transcript(from: decoded),
            elapsedMS: elapsedMS,
            audioTokens: decoded.usageMetadata?.audioTokenCount ?? 0,
            totalTokens: decoded.usageMetadata?.totalTokenCount ?? 0
        )
    }

    // MARK: - Prompt assembly

    /// ``promptHead``, a single key-terms line when there are any, then
    /// ``promptTail``. The terms go in the *middle*; see ``promptTail`` for why
    /// the output contract has to come last.
    ///
    /// The terms are clamped through ``CloudKeyFile/clampTerms(_:)``. Its
    /// 100-term / 50-character ceilings are not Gemini limits — they are a bound
    /// on an otherwise unbounded prompt. An unclamped word list appended to the
    /// instruction is exactly the "wandering prompt" that makes output
    /// irreproducible, quite apart from the tokens it bills. It also trims and
    /// de-duplicates, which is why the terms can safely be joined onto one
    /// comma-separated line: no term can carry a newline that would break the
    /// prompt's structure.
    private static func prompt(keyterms: [String]) -> String {
        let terms = CloudKeyFile.clampTerms(keyterms)
        guard !terms.isEmpty else { return promptHead + "\n" + promptTail }
        return promptHead + "\n"
            + keytermsPrefix + terms.joined(separator: ", ") + "\n"
            + promptTail
    }

    // MARK: - Transcript extraction

    /// Pull the transcript out of a decoded response, or return `""`.
    ///
    /// Every level is optional and every absence means the same thing: the
    /// model produced no text, which is a legitimate "heard nothing" and not an
    /// error. `"parts": [ {} ]` with `finishReason: "STOP"` is a *measured*
    /// response shape, not a hypothetical — see the type documentation. Do not
    /// turn any of these into a force-unwrap or a thrown error.
    ///
    /// The parts of the first candidate are concatenated rather than just
    /// `parts[0]` being read: a single-part response — the only shape observed
    /// — is unaffected, and a future split one is not silently truncated.
    private static func transcript(from body: ResponseBody) -> String {
        let parts = body.candidates?.first?.content?.parts ?? []
        return parts
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let contents: [Content]

        struct Content: Encodable {
            let parts: [Part]
        }

        /// One heterogeneous part: it carries *either* `text` or `inline_data`.
        /// Both are optional and the encoder omits the nil one — sending an
        /// explicit `null` alongside the field that matters is a plausible
        /// `400 INVALID_ARGUMENT`, and there is nothing to gain by risking it.
        struct Part: Encodable {
            let text: String?
            let inlineData: InlineData?

            enum CodingKeys: String, CodingKey {
                case text
                case inlineData = "inline_data"
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let text { try c.encode(text, forKey: .text) }
                if let inlineData { try c.encode(inlineData, forKey: .inlineData) }
            }
        }

        /// snake_case keys, as verified against the live API.
        struct InlineData: Encodable {
            let mimeType: String
            let data: String

            enum CodingKeys: String, CodingKey {
                case mimeType = "mime_type"
                case data
            }
        }
    }

    /// Only the fields we actually consume. `JSONDecoder` ignores everything
    /// else, so extra fields Google adds later cannot break decoding.
    ///
    /// **Nothing here is required.** That is not defensive style for its own
    /// sake: `candidates` can be absent, a candidate's `parts[0]` can be an
    /// empty object, and `candidatesTokenCount` only appears when output was
    /// produced. Making any of it required would convert an ordinary "heard
    /// nothing" answer into a thrown ``ClientError/decoding(_:)``.
    private struct ResponseBody: Decodable {
        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?

        struct Candidate: Decodable {
            let content: Content?
            /// `"STOP"` even on the empty-part responses. Decoded because a
            /// reader will look for it; deliberately not branched on.
            let finishReason: String?
        }

        struct Content: Decodable {
            let parts: [Part]?
        }

        /// The empty object `{}` decodes to a `Part` with `text == nil`. This
        /// is the whole reason `text` is optional.
        struct Part: Decodable {
            let text: String?
        }

        struct UsageMetadata: Decodable {
            let totalTokenCount: Int?
            let promptTokensDetails: [ModalityTokenCount]?

            /// The `"AUDIO"` entry's count, or `nil` when the breakdown is
            /// absent. The details array is per-modality — a request like ours
            /// yields a `"TEXT"` entry for the prompt and an `"AUDIO"` entry
            /// for the clip — so this is a lookup, not `promptTokenCount`.
            var audioTokenCount: Int? {
                promptTokensDetails?
                    .first { $0.modality == GeminiClient.audioModality }?
                    .tokenCount
            }
        }

        struct ModalityTokenCount: Decodable {
            let modality: String?
            let tokenCount: Int?
        }
    }

    // MARK: - Helpers
    //
    // REDACT FIRST, THEN TRUNCATE. That order is load-bearing and is the one
    // thing to preserve if these are ever refactored. Truncating first can cut
    // through the middle of an echoed key, leaving a prefix of it in the snippet
    // that no later redaction can match — the deleted fal client had them in
    // that order, and this pair was deliberately written the other way round.
    //
    // (These were once described as local copies of `FalClient`'s equivalents.
    // That client has since been deleted; these are now simply the only copies.
    // The genuinely shared pieces live in `CloudKeyFile`.)

    /// Remove the API key from a string that is about to escape into an error.
    ///
    /// Google has no reason to echo the key back, but a proxy or a verbose
    /// error page might, and an error value is exactly the thing that ends up
    /// in a log. This makes the guarantee mechanical rather than assumed.
    private func redacting(_ text: String) -> String {
        text.replacingOccurrences(of: apiKey, with: "<redacted>")
    }

    /// Redact first, *then* truncate — so a key straddling the cut can only
    /// ever be replaced whole, never clipped into a surviving fragment.
    private func bodySnippet(of data: Data) -> String {
        Self.snippet(of: redacting(Self.text(of: data)))
    }

    /// A response body as text, or a placeholder describing why it is not.
    private static func text(of data: Data) -> String {
        guard !data.isEmpty else { return "<empty body>" }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "<\(data.count) bytes of non-text>" : text
    }

    /// A short, printable prefix of an already-redacted string.
    private static func snippet(of text: String) -> String {
        text.count > errorBodyPrefix
            ? String(text.prefix(errorBodyPrefix)) + "…"
            : text
    }

    /// `Duration` → milliseconds. The same conversion ``WhisperClient`` uses,
    /// so every `elapsedMS` in this app means the same thing.
    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}

// MARK: - CorrectionProvider

/// ``GeminiClient`` as the cloud choice behind main.swift's correction pass.
///
/// The three properties live in this ordinary conformance extension. The
/// `transcribe` witness does not, and that placement is load-bearing:
/// ``transcribe(wav:keyterms:)`` already exists on this type returning
/// ``Result``, and a second method with the same labels returning
/// ``CorrectionResult`` — the obvious way to write the witness — makes
/// main.swift's existing `let result = try await client.transcribe(wav:keyterms:)`
/// fail with *ambiguous use of 'transcribe(wav:keyterms:)'* (tried 2026-09-03,
/// Swift 6.3.2). Supplying the witness from a protocol extension constrained to
/// `Self == GeminiClient` instead keeps the concrete method winning at a concrete
/// call site — the same un-annotated call compiled and returned ``Result`` — while
/// `any CorrectionProvider` dispatches to the witness through the protocol.
/// Nothing about the existing method, its result type, or its callers changes.
extension GeminiClient: CorrectionProvider {

    /// Derived from ``model`` so the menu cannot name one model while the
    /// request names another.
    var displayName: String { "Gemini (\(Self.model))" }

    /// The WAV is inlined into a request to `generativelanguage.googleapis.com`.
    var sendsAudioOffDevice: Bool { true }

    /// ``isConfigured``. Always true on a live instance — ``init()`` throws
    /// rather than build an unconfigured client — so `false` here is
    /// unreachable today; the protocol asks, and this is the honest answer.
    func isAvailable() async -> Bool { isConfigured }
}

extension CorrectionProvider where Self == GeminiClient {

    /// ``GeminiClient/Result`` → ``CorrectionResult``: the same `text`, the same
    /// monotonic `elapsedMS`, and `audioTokens` straight from Google's ledger.
    /// `totalTokens` is dropped because nothing downstream reads it.
    func transcribe(wav: Data, keyterms: [String]) async throws -> CorrectionResult {
        // The annotation selects the concrete method. Without it this line faces
        // the same overload set main.swift does, inside the very function that
        // would be the other candidate.
        let result: GeminiClient.Result = try await transcribe(wav: wav, keyterms: keyterms)
        return CorrectionResult(text: result.text,
                                elapsedMS: result.elapsedMS,
                                audioTokens: result.audioTokens)
    }
}
