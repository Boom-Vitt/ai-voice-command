import Foundation

/// Minimal HTTP client for a resident local `whisper-server` (whisper.cpp).
///
/// # The server this talks to
///
/// This client does **not** own or start a server. `WhisperServerManager`
/// does, and hands main.swift the `/inference` URL whose port this client is
/// built with. The child it launches — whisper-cpp 1.8.4 from Homebrew — is
/// started exactly like this:
///
/// ```
/// /opt/homebrew/bin/whisper-server \
///     -m ~/.cache/hyperframes/whisper/models/ggml-large-v3-turbo.bin \
///     --host 127.0.0.1 --port 8177 -l th
/// ```
///
/// Three consequences of that invocation matter to every caller:
///
/// * **The model is whatever `-m` named, and this client cannot ask which.**
///   `GET /health` answers `{"status":"ok"}` or `{"status":"loading model"}`
///   and nothing more, and no reply format names the model: `json` is
///   `{"text"}` and `verbose_json` is `task`/`language`/`duration`/`text`/
///   `segments` (the 1.8.4 binary's strings; not exercised by this client).
///   The `params.model` path in `MicTest/TEST-2026-09-03-turbo-bakeoff.json`
///   is *whisper-cli's* `-oj` output, a different binary. So ``modelName`` is a
///   label stored at init, used for ``displayName`` and nothing else, and it
///   drifts silently if the server is relaunched with a different `-m`.
/// * **Speed depends on that model.** `ggml-large-v3-turbo` — the one file in
///   that models directory today, and the one every 2026-09-03 measurement
///   used (`MicTest/TEST-2026-09-03-turbo-server-5clip.txt`) — answers 5.7 s of
///   Thai in 631–670 ms warm and 20 s in 1044–1066 ms. The earlier
///   `ggml-large-v3` took a few seconds for a few seconds of audio; the silence
///   table in ``speechText(from:)`` was measured on *that* model and has not
///   been re-measured on turbo. See ``requestTimeout``.
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
/// part, then `language`, `response_format=json`, and — only when the caller
/// supplied a glossary — a `prompt` part rendered by ``promptString(from:)``.
/// The reply is `{"text": "..."}`. This shape is copied verbatim from
/// `_archive/PhayaVoice/Sources/PhayaVoice/LocalTranscriber.swift`, which is
/// already proven against this exact server — do not "improve" it without
/// testing against a live server first. `prompt` is whisper's initial prompt:
/// the decoder reads it as text that came *before* the audio and continues in
/// its style, which is why the format of that text, not just its words,
/// decides whether it helps or wrecks the Thai. The measurement is on
/// ``promptString(from:)``.
///
/// # Concurrency
///
/// `Sendable`, with no mutable stored state and no actor isolation of any kind.
/// Every method is safe to call from any background `Task`; nothing here
/// touches the main actor or any UI.
///
/// # As a `CorrectionProvider`
///
/// The conformance at the bottom of this file is the shape main.swift's
/// correction pass drives: `transcribe(wav:keyterms:)` is
/// ``transcribe(wav:)`` with the glossary prompt attached, reported with
/// `audioTokens: 0` because a local server keeps no token ledger. Whether the
/// pass uses it is main.swift's `CorrectionProviderKind` setting (`local`,
/// the default when a model and the binary exist), reached through
/// `LocalWhisperProvider`, which builds one of these per request from the
/// port `WhisperServerManager.ensureReady()` returns. There is no fallback
/// between providers at runtime: the setting names one engine, and that
/// engine's failure is traced as a failure, never answered by the other.
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
    /// longer utterance can push well past that. `ggml-large-v3-turbo`, the
    /// model loaded on this Mac today, is faster (5.7 s of audio in 631–670 ms,
    /// 20 s in 1044–1066 ms, warm, 2026-09-03) and the ceiling stays where it
    /// is: it is sized for the slow case, not the usual one. A short timeout
    /// here shows up to the user as "transcription randomly fails", which is
    /// far worse than waiting. 30 s is long enough to never fire in normal use
    /// and short enough that a wedged server does not hang the app forever.
    static let requestTimeout: TimeInterval = 30

    /// Timeout for ``isReachable()``. A liveness probe must answer fast or not
    /// at all — on loopback, anything slower than this is effectively down.
    static let probeTimeout: TimeInterval = 2

    /// The language the server was started with (`-l th`). Sent for agreement
    /// only; it cannot override the server-side setting. See the type doc.
    static let serverLanguage = "th"

    /// What ``modelName`` is when the caller does not say: the model file
    /// present in `~/.cache/hyperframes/whisper/models/` on this Mac today and
    /// the one every 2026-09-03 measurement used. A stored label — the type
    /// documentation explains why the server cannot simply be asked.
    static let defaultModelName = "large-v3-turbo"

    // MARK: - Stored state (all immutable)

    /// Loopback port the server is listening on.
    let port: Int

    /// Label for the model the server is believed to be running, e.g.
    /// `large-v3-turbo`. Read by ``displayName`` and nothing else. Stored,
    /// because the server does not report it — see the type documentation —
    /// so relaunching with a different `-m` and not updating this leaves the
    /// traces naming the wrong model, and nothing else wrong.
    let modelName: String

    /// `POST` target. Precomputed so the hot path allocates nothing extra.
    private let inferenceURL: URL
    /// Identity/health probe target (`GET /`).
    private let rootURL: URL
    /// One ephemeral session for the life of this client. Ephemeral so nothing
    /// is ever written to a cache or cookie store on disk.
    private let session: URLSession

    // MARK: - Init

    init(port: Int = 8177, modelName: String = WhisperClient.defaultModelName) {
        self.port = port
        self.modelName = modelName
        // Force-unwrap is safe: the only interpolated value is an Int.
        self.inferenceURL = URL(string: "http://127.0.0.1:\(port)/inference")!
        self.rootURL = URL(string: "http://127.0.0.1:\(port)/")!

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.requestTimeout
        cfg.timeoutIntervalForResource = Self.requestTimeout + 15
        cfg.waitsForConnectivity = false           // loopback: fail fast, never queue
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpMaximumConnectionsPerHost = 2
        // Never follow a redirect: the body is the user's speech, and a 3xx from
        // whatever holds the loopback port must not re-send it anywhere. The
        // measurement is on `RefuseRedirects`.
        self.session = RefuseRedirects.session(configuration: cfg)
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
        try await transcribe(wav: wav, prompt: nil)
    }

    /// ``transcribe(wav:)`` with whisper's initial prompt attached.
    ///
    /// - Parameter prompt: Sent verbatim as the `prompt` form part. `nil` or
    ///   `""` sends no part at all, so the request is byte-for-byte the
    ///   no-prompt one — measured, no prompt beat a bad prompt (see
    ///   ``promptString(from:)``, the only intended source of this string).
    func transcribe(wav: Data, prompt: String?) async throws -> Result {
        let body = Self.multipartBody(wav: wav,
                                      filename: "audio.wav",
                                      language: Self.serverLanguage,
                                      prompt: prompt)

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

    // MARK: - Glossary prompt

    /// Byte ceiling for the `prompt` form part.
    ///
    /// whisper's prompt window is `n_text_ctx / 2` tokens — 224 for this model
    /// (`n_text_ctx = 448` in the server's model-load log). Past that the
    /// decoder keeps the *last* 224 tokens and drops the front (whisper.cpp
    /// takes `prompt_past.end() - n_take ..< end()`), so an over-long prompt
    /// loses its opening and its first terms, silently. The archived client set
    /// 800 by budgeting ~4 UTF-8 bytes per token for an ASCII comma list. The
    /// sentence format below spends more of its bytes on Thai, which is
    /// unlikely to tokenise as economically as ASCII, so 800 bytes sits nearer
    /// the window here than it did there. Nobody has counted tokens for this
    /// format — the number is inherited, not re-measured. For scale: P2, the
    /// measured 8-term sentence, is 177 bytes; this generator's sentence for
    /// the same eight terms is 178; the app's full 20-term glossary renders
    /// to 452.
    static let maxPromptBytes = 800

    /// Thai connectives that carry the glossary as one sentence, cycled in this
    /// order between consecutive terms. All four occur in the measured prompt
    /// (`P2` in `MicTest/TEST-2026-09-03-turbo-server-5clip.txt`).
    private static let promptConnectives = ["แล้ว", "กับ", "ก่อน", "แล้วค่อย"]

    /// Opens the carrier sentence — "today [I] will …" — so the first term lands
    /// in a verb slot, as `deploy` did in the measured prompt.
    private static let promptOpening = "วันนี้จะ"

    /// Render the glossary as whisper's initial prompt: **a Thai sentence that
    /// happens to contain the terms, not a list of them.**
    ///
    /// # Why a sentence — measured; do not simplify this back to a comma list
    ///
    /// Same server, same `ggml-large-v3-turbo`, five synthetic clips, 2026-09-03
    /// (`MicTest/TEST-2026-09-03-turbo-server-5clip.txt`):
    ///
    /// | prompt                                           | exact | EN kept |
    /// |--------------------------------------------------|-------|---------|
    /// | none                                             | 2/5   | 1/8     |
    /// | P1 `deploy, refactor, function, commit, push, …` | 1/5   | 7/8     |
    /// | P2, the sentence quoted below                    | 4/5   | 7/8     |
    ///
    /// P2 was `วันนี้จะ deploy แล้ว commit กับ push ขึ้น branch main ก่อน meeting
    /// ตอนบ่าย แล้วค่อย refactor function`.
    ///
    /// The comma list rescued the English and wrecked the Thai around it —
    /// `meeting, to an abiding 3 oz.` for "meeting ตอนบ่าย 3 โมง", `ninoi` for
    /// "นี้หน่อย", commas sprayed between words — because whisper treats the
    /// prompt as preceding transcript and continues in its style. The sentence
    /// kept the same English with the Thai intact and no punctuation. The
    /// no-prompt row is also why an empty glossary sends **no** `prompt` part:
    /// no prompt beat a bad prompt, so nothing goes out unless there is
    /// something to say.
    ///
    /// # What this renders
    ///
    /// ``promptOpening``, then the terms joined by ``promptConnectives`` in
    /// rotation:
    ///
    ///     วันนี้จะ deploy แล้ว commit กับ branch ก่อน main แล้วค่อย refactor แล้ว push …
    ///
    /// That is P2's *shape*, not its bytes: P2 was written by hand with
    /// term-specific slots (`push ขึ้น branch main`) no generator can produce for
    /// an arbitrary list. The generated sentence WAS then scored, 2026-09-04
    /// (`MicTest/TEST-2026-09-04-prompt-connectives.txt`, shape A, run 1): on
    /// the same five clips the generated 8-term sentence scores **3/5 exact,
    /// 5/8 EN** — cs3 `refactor function` is the loss against hand-written P2 —
    /// while the app's real 20-term glossary, rendered by this function to the
    /// 452 bytes the launch trace reports, scores **4/5, 7/8** (run 2). So the
    /// 4/5 in the table above is earned by the app's prompt, not by the 8-term
    /// demo. Same file, the caveat: every connective set echoes a connective
    /// into the transcript somewhere (`ผมใช้ peter แล้วค่อย …` for a spoken
    /// `กับ`), and removing connectives removes the echo AND the accuracy
    /// (D: 3/5, 6/8). Seven shapes were tried; none beat the rotation below on
    /// leak, exact and EN together, so it stands.
    ///
    /// # Budget
    ///
    /// Terms go through `CloudKeyFile.clampTerms` (trim, drop blanks, clip at 50
    /// characters, de-duplicate, at most 100) — the same clamp the Gemini path
    /// applies, so both providers see one list. Internal whitespace collapses to
    /// a single space so a term can never break the sentence onto a second line.
    /// Each term is then appended with its connective only if the whole piece
    /// fits under ``maxPromptBytes``; a term that does not fit is dropped whole
    /// and the next one is tried, so one oversized entry costs itself and not
    /// everything after it. A term is never cut: a fragment biases the decoder
    /// toward the fragment, and a byte-level cut could also land inside a Thai
    /// cluster (base consonant plus vowel and tone marks), which `String` holds
    /// as one `Character`. Only whole `String`s are appended, so the output ends
    /// on a complete `Character` by construction.
    ///
    /// - Returns: `""` for an empty or all-blank glossary — the caller must then
    ///   omit the `prompt` part rather than send an empty one.
    static func promptString(from keyterms: [String]) -> String {
        promptRendering(from: keyterms).sentence
    }

    /// What ``promptString(from:)`` rendered and what it dropped.
    ///
    /// `kept` and `dropped` count clamped terms, so `kept + dropped` is the
    /// list after `CloudKeyFile.clampTerms`, not the caller's raw list. Only this
    /// function knows which terms survived the byte cap, so main.swift traces
    /// these two numbers at capture start: a user's own glossary term silently
    /// falling off the end of the prompt is the exact failure the user reported
    /// (`time` never appearing), and a count of zero dropped is the only proof it
    /// did not happen. Counts only, never the terms — the trace is world-readable.
    static func promptRendering(from keyterms: [String])
        -> (sentence: String, kept: Int, dropped: Int)
    {
        var sentence = ""
        var kept = 0
        var dropped = 0
        for term in CloudKeyFile.clampTerms(keyterms) {
            let word = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let joiner = kept == 0
                ? promptOpening
                : promptConnectives[(kept - 1) % promptConnectives.count]
            let piece = (kept == 0 ? "" : " ") + joiner + " " + word
            guard sentence.utf8.count + piece.utf8.count <= maxPromptBytes else {
                dropped += 1
                continue
            }
            sentence += piece
            kept += 1
        }
        return (sentence, kept, dropped)
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
    /// which is the ordering the server is known to accept. `prompt`, when
    /// present, goes last — the position the archived client used against this
    /// same server.
    ///
    /// - Parameter prompt: whisper's initial prompt. `nil` or `""` emits no
    ///   `prompt` part at all, so the body is identical to the no-prompt one.
    static func multipartBody(wav: Data,
                              filename: String,
                              language: String,
                              prompt: String? = nil) -> (data: Data, boundary: String) {
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
        // The legacy correction path already uses an Apple speech witness.
        // Reserve model VAD for the separate primary-transcription client.
        appendField("vad", "false")
        // Omitted, not emptied, when there is nothing to say: an empty glossary
        // should reproduce the measured no-prompt request exactly, and leaving
        // the part out is the one way to be sure of that whatever the server
        // makes of a zero-length prompt (not measured).
        if let prompt, !prompt.isEmpty {
            appendField("prompt", prompt)
        }

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

// MARK: - CorrectionProvider

extension WhisperClient: CorrectionProvider {

    /// e.g. `local whisper (large-v3-turbo)`. ``modelName`` is stored, not
    /// reported by the server — see the type documentation.
    var displayName: String { "local whisper (\(modelName))" }

    /// Everything goes to `127.0.0.1`; see the type documentation.
    var sendsAudioOffDevice: Bool { false }

    /// ``isReachable()``: a positive probe also means the model is loaded. Not
    /// cached — each call is one loopback `GET /` bounded by ``probeTimeout``,
    /// and the caller decides how often to ask.
    func isAvailable() async -> Bool {
        await isReachable()
    }

    /// ``transcribe(wav:)`` with the glossary rendered by ``promptString(from:)``.
    ///
    /// `audioTokens` is always `0`: a local server bills nothing and counts
    /// nothing, and `0` is the value main.swift's ledger already skips.
    /// ``speechText(from:)`` has already run on the text, so a silence
    /// hallucination the list knows about comes back as `""`.
    func transcribe(wav: Data, keyterms: [String]) async throws -> CorrectionResult {
        let prompt = Self.promptString(from: keyterms)
        let result = try await transcribe(wav: wav, prompt: prompt.isEmpty ? nil : prompt)
        return CorrectionResult(text: result.text,
                                elapsedMS: result.elapsedMS,
                                audioTokens: 0)
    }
}
