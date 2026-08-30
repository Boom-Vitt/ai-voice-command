import Foundation

/// Cloud accuracy pass: ElevenLabs **Scribe v2**, hosted on fal.ai.
///
/// This is the *second* opinion in the dictation path. ``WhisperClient`` runs
/// locally and returns fast; this runs in someone else's datacenter and returns
/// better Thai — in particular it keeps English technical terms ("deploy",
/// "commit", "branch main") intact inside a Thai sentence, which the local
/// model tends to mangle.
///
/// # Wire format
///
/// ```
/// POST https://fal.run/fal-ai/elevenlabs/speech-to-text/scribe-v2
/// Authorization: Key <FAL_KEY>
/// Content-Type: application/json
///
/// { "audio_url": "data:audio/wav;base64,<...>",
///   "language_code": "tha",
///   "diarize": false,
///   "tag_audio_events": false,
///   "keyterms": ["deploy", "commit", ...] }
/// ```
///
/// Three details on that body are load-bearing and were each established
/// against the live API, not read off a doc page:
///
/// * **`language_code` is `"tha"`, not `"th"`.** Scribe v2 wants ISO-639-3.
///   The two-letter ISO-639-1 code is a different vocabulary and does not
///   mean the same thing here. Do not "fix" this to `"th"`.
/// * **The audio is inlined as a `data:` URI.** This endpoint accepts data
///   URIs. That is *not* a general fal.ai property — `fal-ai/whisper` rejects
///   them outright with `422 Unsupported data URL` — so it is easy to assume
///   the two-step presigned-upload dance is required here. It is not, and
///   skipping it saves roughly **2.3 s per utterance**, which is most of the
///   budget for a dictation UI that has to feel live. Inline the bytes.
/// * **`keyterms` is bias vocabulary, not a filter.** fal documents a ceiling
///   of 100 terms at 50 characters each; over it, the API 422s. We clamp
///   defensively in ``sanitize(keyterms:)`` rather than letting a caller's
///   long word list turn into a failed transcription.
///
/// # Measured latency
///
/// **≈3–3.5 s observed**: 3014 ms for ~4 s of audio, 3483 ms for a 7.0 s clip.
/// Both transcripts were exactly correct, including the embedded English.
/// Budget accordingly — this is an accuracy pass that costs about three
/// seconds, not a real-time path. See ``requestTimeout``.
///
/// # Response
///
/// ```json
/// { "text": "ช่วย deploy แล้ว commit ขึ้น branch main ให้หน่อยครับ",
///   "language_code": "tha",
///   "language_probability": 0.98,
///   "words": [ {"text":"ช่","start":0.079,"end":0.299,"type":"word","speaker_id":null} ] }
/// ```
///
/// Decoding is deliberately forgiving: unknown fields are ignored, and every
/// field this client does not strictly need is optional. A transcript that
/// arrives with one surprising word entry should still produce a ``Result``.
///
/// # The API key
///
/// Read at init from `~/.config/thaidictate/env` (a `chmod 600` one-liner,
/// `FAL_KEY=…`). The key is never logged, never interpolated into an error,
/// and is scrubbed out of the HTTP body echo in ``ClientError/http(_:_:)``
/// before that error escapes. If you add a new error path, keep it that way.
///
/// # Concurrency
///
/// `Sendable`, no actor isolation, no mutable shared state, no UI. Safe to
/// call from a detached background `Task` — which is the only way it is ever
/// called, since a 3 s round trip has no business on the main actor.
struct FalClient: Sendable {

    // MARK: - Public types

    /// One token from the transcript, with its position in the audio.
    ///
    /// Only entries the API tagged `type == "word"` become a ``Word``; see
    /// ``Result/words``.
    struct Word: Sendable {
        let text: String
        /// Seconds from the start of the submitted audio.
        let start: Double
        /// Seconds from the start of the submitted audio.
        let end: Double
    }

    /// One successful round trip.
    struct Result: Sendable {
        /// The transcript, trimmed of surrounding whitespace and newlines.
        let text: String
        /// Timed transcript entries — the ones the API tagged
        /// `"type": "word"`, with its `"type": "spacing"` separators dropped.
        ///
        /// **`words.count` is not a word count. Never show it to a user as
        /// one.** Scribe segments Thai below the word level: the four-letter
        /// word `ช่วย` comes back as three entries (`ช่`, `ว`, `ย`), while
        /// Latin-script terms stay whole (`refactor`, `function`). Measured on
        /// the 8-word test sentence: 27 raw entries → 20 `word` + 7 `spacing`.
        /// Treat these as timed segments for highlighting or alignment, and
        /// take the word count from ``text`` if you need one.
        ///
        /// Because the `spacing` entries are dropped, this array no longer
        /// reconstructs ``text`` — concatenating it loses the spaces that
        /// separated `refactor` from `function`. Use ``text`` for the
        /// transcript; use this only for timings.
        let words: [Word]
        /// The API's confidence that the audio really is in the language it
        /// reported. Defaults to `0` when the field is absent.
        let languageProbability: Double
        /// Wall-clock milliseconds for the whole round trip, measured on this
        /// side of the wire with a monotonic clock — same basis as
        /// ``WhisperClient/Result/elapsedMS``, so the two are comparable.
        let elapsedMS: Double
    }

    enum ClientError: Error, LocalizedError {
        /// No usable `FAL_KEY` on disk. Payload is the path we looked at, so
        /// the message can tell the user exactly what to create.
        case missingKey(String)
        /// The API answered, but not with 2xx. Payload is the status and a
        /// truncated, key-scrubbed prefix of the response body.
        case http(Int, String)
        /// 2xx whose body was not the JSON we expect. Payload is a short
        /// snippet of what actually arrived.
        case decoding(String)
        /// The request never completed — offline, DNS, TLS, timeout.
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingKey(let path):
                return """
                    No FAL_KEY found. Create \(path) containing one line, \
                    `FAL_KEY=<your fal.ai key>`, then `chmod 600` it.
                    """
            case .http(let status, let body):
                return "fal.ai returned HTTP \(status): \(body)"
            case .decoding(let snippet):
                return "Could not parse the fal.ai response: \(snippet)"
            case .transport(let reason):
                return "Could not reach fal.ai: \(reason)"
            }
        }
    }

    // MARK: - Tunables

    /// Scribe v2 endpoint. Synchronous — it holds the connection open and
    /// answers with the transcript, so there is no job/poll cycle to run.
    static let endpoint = URL(string: "https://fal.run/fal-ai/elevenlabs/speech-to-text/scribe-v2")!

    /// Seconds to wait for the transcript before giving up.
    ///
    /// Sized for *usefulness*, not maximum patience. The measured round trip
    /// is ~3–3.5 s, so 15 s is already ~4–5x headroom for a long utterance, a
    /// slow uplink, or a queued fal region. Past that, the answer is worth
    /// nothing: this client is a delayed accuracy pass, and a correction that
    /// lands tens of seconds late targets text the caret has long moved past.
    /// Worse, main.swift allows only ONE of these requests in flight at a
    /// time, so a hung request does not merely lose its own correction — it
    /// silently blocks every subsequent correction until it resolves. With
    /// the old 60 s value, a single network drop mid-dictation meant a full
    /// minute of corrections blackout. Fail fast and free the gate.
    static let requestTimeout: TimeInterval = 15

    /// Ceiling on the whole transfer (`timeoutIntervalForResource`): the
    /// request timeout plus a little slack for a response already trickling
    /// in. Kept nearly as tight as ``requestTimeout``, for the same reason —
    /// while this runs, the one-in-flight gate in main.swift is held.
    static let resourceTimeout: TimeInterval = 20

    /// fal's documented ceiling on `keyterms`.
    static let maxKeyterms = 100
    /// fal's documented ceiling on the length of one keyterm.
    static let maxKeytermLength = 50

    /// How much of a failing response body to keep in ``ClientError/http(_:_:)``.
    /// Enough to read fal's `{"detail": ...}`, short enough not to dump a page
    /// of HTML from some intermediate proxy into a log line.
    private static let errorBodyPrefix = 400

    /// Where the key lives, relative to the user's home directory.
    private static let keyFileComponents = [".config", "thaidictate", "env"]
    /// The variable we look for inside that file. Not `private`: it is the
    /// default argument of ``loadKey(from:name:)``, so it has to be at least
    /// as visible as that function.
    static let keyName = "FAL_KEY"
    /// The *optional* admin-scoped variable that file may carry.
    ///
    /// VESTIGIAL AS SHIPPED, and named as such so nobody wires against it
    /// expecting a live feature: its only consumer was the fal credit-balance
    /// probe, which was deleted when Gemini replaced fal as the cloud pass
    /// (see the cloud-provider note in `main.swift`). ``FalBillingClient`` is
    /// retained on disk but wholly unreferenced. Kept — rather than removed —
    /// only because the fal path as a whole is retained to make that swap
    /// reversible; if fal is ever unretired, this is where its second key
    /// name lives. Nothing reads it today.
    static let adminKeyName = "FAL_ADMIN_KEY"

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
    ///   unreadable, or contains no `FAL_KEY=` assignment.
    init() throws {
        try self.init(keyFileURL: Self.defaultKeyFileURL())
    }

    /// Designated init, parameterised on the key file so it can be pointed at
    /// a fixture. Production callers use ``init()``.
    init(keyFileURL: URL) throws {
        self.apiKey = try Self.loadKey(from: keyFileURL)

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
    /// constructing an unconfigured client. It exists so call sites can ask
    /// the question without caring how the answer is arrived at.
    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Key loading

    /// `~/.config/thaidictate/env`, resolved through `FileManager` so the
    /// tilde is a real home directory and not a literal path component.
    static func defaultKeyFileURL() -> URL {
        var url = FileManager.default.homeDirectoryForCurrentUser
        for component in keyFileComponents {
            url.appendPathComponent(component)
        }
        return url
    }

    /// Parses `<name>=<value>` out of a dotenv-style file.
    ///
    /// Tolerates comments, blank lines, `export ` prefixes, surrounding
    /// quotes, and spaces around the `=`. Everything else is ignored.
    ///
    /// The parser is deliberately variable-name-agnostic, and that generality
    /// is now load-bearing for a different reason than it was written for: the
    /// shipping cloud pass is Gemini, and ``GeminiClient`` reads its own
    /// `GOOGLE_API_KEY` out of this same file through this same function. The
    /// original motive — a second `FAL_ADMIN_KEY` line for the fal balance
    /// probe — is gone with that probe (see ``adminKeyName``).
    ///
    /// CALLERS MUST PASS `name:` EXPLICITLY when they are not the fal path.
    /// The default is ``keyName`` (`FAL_KEY`), so an omitted label silently
    /// hands back the *fal* secret; a caller that then puts it in a Google
    /// auth header would ship one vendor's key to another. ``GeminiClient``
    /// passes it explicitly and says so at its call site.
    ///
    /// - Parameters:
    ///   - url: The dotenv-style file to read.
    ///   - name: Which assignment to return. Defaults to ``keyName``.
    /// - Throws: ``ClientError/missingKey(_:)``, carrying the path, for every
    ///   failure — absent file, unreadable file, no assignment, empty value.
    ///   Never traps, and never returns an empty string. Note the thrown
    ///   message names `FAL_KEY` literally, which is now wrong for every
    ///   caller except the retained-but-unwired fal path. ``GeminiClient``
    ///   therefore does not propagate it: it catches and re-throws its own
    ///   ``GeminiClient/ClientError/missingKey(_:)`` naming `GOOGLE_API_KEY`,
    ///   so the user is told to create the key they actually lack.
    static func loadKey(from url: URL, name: String = keyName) throws -> String {
        // `Data(contentsOf:)` rather than `String(contentsOf:)`: the String
        // overload without an explicit encoding is deprecated on current SDKs.
        guard let data = try? Data(contentsOf: url) else {
            throw ClientError.missingKey(url.path)
        }
        let contents = String(decoding: data, as: UTF8.self)

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }

            guard let eq = line.firstIndex(of: "=") else { continue }
            // `assigned`, not `name`: the parameter owns that identifier now.
            // Shadowing it here would silently turn the guard into a tautology
            // and hand back whichever assignment came first in the file.
            let assigned = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard assigned == name else { continue }

            var value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
            // Strip one matched pair of surrounding quotes, if present.
            if value.count >= 2,
               let first = value.first, let last = value.last,
               first == last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { break }
            return value
        }

        throw ClientError.missingKey(url.path)
    }

    // MARK: - Transcription

    /// Send one complete WAV and return what Scribe heard.
    ///
    /// - Parameters:
    ///   - wav: Complete 16 kHz mono 16-bit WAV bytes, header included. The
    ///     bytes are base64'd into a `data:` URI in the request body (see the
    ///     type documentation), so expect the on-wire payload to be about
    ///     4/3 the size of this buffer.
    ///   - keyterms: Bias vocabulary — technical words the model would
    ///     otherwise transliterate into Thai. Clamped to fal's limits; pass as
    ///     many as you like and let ``sanitize(keyterms:)`` do the trimming.
    /// - Returns: The transcript, word timings, language confidence, and the
    ///   measured round-trip time.
    func transcribe(wav: Data, keyterms: [String]) async throws -> Result {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The one place the key touches the wire. Nothing else reads `apiKey`
        // except the scrubber in `redacting(_:)`.
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")

        let payload = RequestBody(
            audioURL: "data:audio/wav;base64," + wav.base64EncodedString(),
            languageCode: "tha",          // ISO-639-3. Not "th". See type docs.
            diarize: false,
            tagAudioEvents: false,
            keyterms: Self.sanitize(keyterms: keyterms)
        )

        let encoder = JSONEncoder()
        do {
            request.httpBody = try encoder.encode(payload)
        } catch {
            // Encoding a struct of Strings and Bools should not fail; if it
            // somehow does, report it without echoing the body.
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
            // ("The request timed out"); it never contains our headers.
            throw ClientError.transport(error.localizedDescription)
        }

        let elapsedMS = Self.milliseconds(started.duration(to: clock.now))

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw ClientError.http(status, Self.snippet(of: data, redact: redacting))
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw ClientError.decoding(Self.snippet(of: data, redact: redacting))
        }

        // `type` is "word" for transcript segments and "spacing" for the
        // literal " " separators between them; the API interleaves both in one
        // array. Keep only the former. Note this is *not* a word filter — a
        // Thai word arrives as several "word" entries. See `Result.words`.
        let words: [Word] = (decoded.words ?? []).compactMap { entry in
            guard entry.type == nil || entry.type == "word" else { return nil }
            let text = entry.text ?? ""
            guard !text.isEmpty else { return nil }
            return Word(text: text, start: entry.start ?? 0, end: entry.end ?? 0)
        }

        return Result(
            text: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: words,
            languageProbability: decoded.languageProbability ?? 0,
            elapsedMS: elapsedMS
        )
    }

    // MARK: - Keyterms

    /// Clamp a caller's bias vocabulary to fal's documented limits.
    ///
    /// Trims each term, drops the empties (an empty string is a plausible
    /// 422), truncates anything past ``maxKeytermLength`` characters, and
    /// keeps at most ``maxKeyterms`` terms. Truncating is the deliberate
    /// choice over erroring: a slightly shortened bias list still produces a
    /// usable transcript, whereas a rejected request produces nothing.
    static func sanitize(keyterms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(min(keyterms.count, maxKeyterms))

        for term in keyterms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clipped = trimmed.count > maxKeytermLength
                ? String(trimmed.prefix(maxKeytermLength))
                : trimmed
            guard seen.insert(clipped).inserted else { continue }
            out.append(clipped)
            if out.count == maxKeyterms { break }
        }
        return out
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let audioURL: String
        let languageCode: String
        let diarize: Bool
        let tagAudioEvents: Bool
        let keyterms: [String]

        enum CodingKeys: String, CodingKey {
            case audioURL = "audio_url"
            case languageCode = "language_code"
            case diarize
            case tagAudioEvents = "tag_audio_events"
            case keyterms
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(audioURL, forKey: .audioURL)
            try c.encode(languageCode, forKey: .languageCode)
            try c.encode(diarize, forKey: .diarize)
            try c.encode(tagAudioEvents, forKey: .tagAudioEvents)
            // Omit rather than send `[]`; an empty bias list is not a request
            // for empty bias, it is the absence of one.
            if !keyterms.isEmpty {
                try c.encode(keyterms, forKey: .keyterms)
            }
        }
    }

    /// Only the fields we actually consume. `JSONDecoder` ignores everything
    /// else, so extra fields fal adds later cannot break decoding.
    private struct ResponseBody: Decodable {
        let text: String
        let languageProbability: Double?
        let words: [WordEntry]?

        enum CodingKeys: String, CodingKey {
            case text
            case languageProbability = "language_probability"
            case words
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.text = try c.decode(String.self, forKey: .text)
            self.languageProbability =
                try c.decodeIfPresent(Double.self, forKey: .languageProbability)
            self.words = try c.decodeIfPresent([WordEntry].self, forKey: .words)
        }
    }

    /// One entry of the `words` array.
    ///
    /// Everything is optional and `speaker_id` is not declared at all. The
    /// array mixes words with `"spacing"` entries whose timings may be absent,
    /// and decoding happens *before* we filter by `type` — so a single odd
    /// entry must not be able to throw away an otherwise good transcript.
    private struct WordEntry: Decodable {
        let text: String?
        let start: Double?
        let end: Double?
        let type: String?
    }

    // MARK: - Helpers

    /// Remove the API key from a string that is about to escape into an error.
    ///
    /// fal has no reason to echo the key back, but a proxy or a verbose error
    /// page might, and an error value is exactly the thing that ends up in a
    /// log. This makes the guarantee mechanical rather than assumed.
    private func redacting(_ text: String) -> String {
        text.replacingOccurrences(of: apiKey, with: "<redacted>")
    }

    /// A short, printable prefix of a response body, with the key already removed.
    ///
    /// ORDER IS LOAD-BEARING: this decodes the WHOLE body, hands it to `redact` to
    /// scrub, and truncates only afterwards. The obvious arrangement — truncate first,
    /// scrub the prefix — has a hole: a key echoed back so that it straddles the
    /// `errorBodyPrefix` cut is severed, and `redacting(_:)` then finds no occurrence of
    /// the whole key to replace, so the surviving head of it escapes into the error
    /// string and from there into the log. That is the exact leak this scrubber exists
    /// to make impossible, so the scrub must see text no shorter than what is printed.
    /// `FalBillingClient` and `GeminiClient` compose theirs the same way; keep all three
    /// in step. Taking `redact` as a parameter (rather than reading `apiKey`) is what
    /// lets this stay `static` while still scrubbing an instance's key.
    private static func snippet(of data: Data, redact: (String) -> String) -> String {
        guard !data.isEmpty else { return "<empty body>" }
        let full = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if full.isEmpty { return "<\(data.count) bytes of non-text>" }
        let scrubbed = redact(full)
        if scrubbed.count <= errorBodyPrefix { return scrubbed }
        return String(scrubbed.prefix(errorBodyPrefix)) + "…"
    }

    /// `Duration` → milliseconds. Same conversion ``WhisperClient`` uses, so
    /// the two clients' `elapsedMS` values mean the same thing.
    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
