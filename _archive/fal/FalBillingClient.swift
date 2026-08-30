import Foundation

/// Reads the fal.ai account's remaining credit, for the status-menu line.
///
/// # Why this is not a method on ``FalClient``
///
/// It looks like it belongs there — same vendor, same `Authorization: Key`
/// scheme — and it does not, on four counts, every one of which would have to
/// be smuggled past a shared implementation:
///
/// * **Different host.** Transcription goes to `fal.run`, the inference edge.
///   Billing lives on `api.fal.ai`, the account/platform API. They are
///   separate services that happen to accept the same header format.
/// * **Different credential.** The transcription key is inference-scoped.
///   This endpoint requires an **admin**-scoped key
///   (<https://fal.ai/docs/platform-apis/v1/account/billing>), which is a
///   *different secret* — see ``FalClient/adminKeyName`` (now vestigial: this
///   whole type is retained-but-unreferenced since Gemini replaced fal). An inference key
///   here does not fail obscurely; it 401s or 403s, every time, forever.
/// * **Different timeout budget.** ``FalClient/requestTimeout`` is 15 s
///   because a transcript is worth waiting for. A number on a menu line is
///   not: see ``requestTimeout``.
/// * **Different failure semantics.** ``FalClient`` throws, because a failed
///   transcription is a thing the user needs told. Here, 401/403 is not an
///   error at all — it is the ordinary, permanent state of an account whose
///   key was never given admin scope, and the correct response is to hide the
///   credit line, not to report a fault. Modelling that as a thrown error
///   invites a call site to log it as one on every single refresh.
///
/// # Wire format
///
/// ```
/// GET https://api.fal.ai/v1/account/billing?expand=credits
/// Authorization: Key <FAL_ADMIN_KEY>
/// Accept: application/json
///
/// → { "username": "...",
///     "credits": { "current_balance": 12.34, "currency": "USD" } }
/// ```
///
/// `expand=credits` is what produces the nested `credits` object; without it
/// the response is the account summary alone. A 200 that arrives *without*
/// that object is therefore treated as a failure rather than as a zero
/// balance — reporting "$0.00" to someone who has credit would be worse than
/// reporting nothing. fal's errors are JSON carrying `type`/`message`; the
/// snippet in ``Outcome/failed(_:)`` is enough to read one.
///
/// # This must never affect dictation
///
/// The whole type is advisory. It is driven from AppDelegate's own balance
/// task, never from the transcription path and never sharing the
/// one-request-in-flight gate that ``FalClient`` is subject to, so a slow or
/// broken billing endpoint cannot delay, block, or fail a single word of
/// typed text. ``fetchBalance()`` is `async` and cannot throw precisely so
/// that no caller can accidentally propagate a billing problem into a path
/// that matters.
///
/// # The API key
///
/// Handed in at init. This type performs **no file I/O** — locating and
/// reading the env file is ``FalClient/loadKey(from:name:)``'s job, and
/// deciding whether a key exists at all (and hence whether to show the credit
/// line) belongs to the caller. As in ``FalClient``, the key is never logged
/// and is scrubbed out of every string that escapes.
///
/// # Concurrency
///
/// `Sendable`, no actor isolation, no mutable state, no UI.
///
/// > Note: This type has no call sites yet. The menu wiring in main.swift is
/// > a later slice; it is expected to be uncalled in this change.
struct FalBillingClient: Sendable {

    // MARK: - Public types

    /// Every way this request can end. There is no `throws` and no `Error`:
    /// each outcome is a case a caller has to look at, which is the point —
    /// ``unauthorized(status:)`` is an expected steady state, not a fault,
    /// and making it a thrown error is exactly how it ends up mislabelled in
    /// a log or shown to the user as a breakage.
    enum Outcome: Sendable {
        /// The account's remaining credit, with the round-trip time measured
        /// on this side of the wire (same basis as ``FalClient/Result``).
        case balance(amount: Double, currency: String, elapsedMS: Double)
        /// 401 or 403 — **expected**, and permanent until the user swaps in an
        /// admin-scoped key. Means "this key may not read billing", not "the
        /// key is bad": the very same key may be transcribing happily. Do not
        /// retry on a timer, and do not present it as an error.
        case unauthorized(status: Int)
        /// Transport, decoding, or a non-2xx that was not 401/403 — i.e. every
        /// *transient* failure. Payload is a short, key-scrubbed description
        /// fit for a trace line. Worth retrying later; not worth alarming
        /// anyone about now.
        case failed(String)
    }

    // MARK: - Tunables

    /// The account billing endpoint. `expand=credits` is load-bearing: drop it
    /// and the response has no `credits` object to read.
    static let endpoint = URL(string: "https://api.fal.ai/v1/account/billing?expand=credits")!

    /// Seconds to wait for the balance before giving up.
    ///
    /// Deliberately a third of ``FalClient/requestTimeout``. That one is sized
    /// so a slow transcript still lands, because a late transcript is still
    /// the user's words. This one decorates a menu line: an answer that
    /// arrives after the menu has closed is worth nothing, and the next
    /// refresh is never far away. Fail fast, show the cached number, move on.
    static let requestTimeout: TimeInterval = 5

    /// Ceiling on the whole transfer (`timeoutIntervalForResource`), a little
    /// above ``requestTimeout`` for a response already trickling in.
    static let resourceTimeout: TimeInterval = 8

    /// How much of a failing response body to keep in ``Outcome/failed(_:)``.
    ///
    /// Half of ``FalClient``'s 400, on purpose: that budget is sized to hold a
    /// whole `{"detail": …}` in a log, while this one may end up beside a
    /// balance on a menu. Enough to read fal's `{"type","message"}`, short
    /// enough not to paste a proxy's HTML page into the UI. If someone later
    /// decides to unify these two constants, this is the reason not to.
    private static let errorBodyPrefix = 200

    // MARK: - Stored state

    /// The admin-scoped API key. Immutable, never logged, never rendered into
    /// an outcome — see ``redacting(_:)``.
    private let apiKey: String

    /// One ephemeral session for the life of this client, for the same reason
    /// ``FalClient`` uses one: nothing that carries the user's key is written
    /// to a disk cache, cookie jar, or credential store.
    private let session: URLSession

    // MARK: - Init

    /// - Parameter apiKey: An **admin**-scoped fal.ai key. An inference key is
    ///   accepted without complaint and will simply produce
    ///   ``Outcome/unauthorized(status:)`` on every call.
    init(apiKey: String) {
        self.apiKey = apiKey

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.requestTimeout
        cfg.timeoutIntervalForResource = Self.resourceTimeout
        // Never queue silently waiting for a network. Same reasoning as
        // FalClient, with more force: an offline balance check should report
        // "unreachable" now and be retried on the next trigger, not linger.
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Balance

    /// Ask fal.ai what is left on the account.
    ///
    /// Never throws and never traps: every path — transport, HTTP status,
    /// decoding, a 200 whose shape is wrong — lands on an ``Outcome``. A
    /// caller therefore cannot forget the ``Outcome/unauthorized(status:)``
    /// branch, which is the one that decides whether the credit line is shown
    /// at all.
    func fetchBalance() async -> Outcome {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        // No Content-Type: a GET with no body has no content to type.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The one place the key touches the wire. Same scheme as FalClient:
        // fal wants the literal word `Key`, not `Bearer`.
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")

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
            return .failed(Self.snippet(of: redacting(error.localizedDescription)))
        }

        // Measured before any branching, so the number means "time on the
        // wire" and not "time on the wire plus however much parsing the
        // success path happens to do".
        let elapsedMS = Self.milliseconds(started.duration(to: clock.now))

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200...299:
            break
        case 401, 403:
            // Checked BEFORE the generic non-2xx arm, and returned as its own
            // case rather than folded into `.failed`. This is the expected
            // answer for an inference-only key; see `Outcome.unauthorized`.
            return .unauthorized(status: status)
        default:
            return .failed("HTTP \(status) — \(bodySnippet(of: data))")
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            // Labelled, because `.failed` merges what FalClient keeps apart as
            // `.decoding` and `.transport`. Without the prefix a malformed 200
            // and a dead network produce trace lines that read the same.
            return .failed("could not parse the response: \(bodySnippet(of: data))")
        }

        // `credits` is optional in the wire type on purpose: a 200 that came
        // back without it means the `expand=credits` query was ignored or
        // dropped somewhere, not that the balance is zero. Reporting "$0.00"
        // to an account in good standing would be a worse lie than reporting
        // nothing at all, so this is a failure, and a retryable one.
        guard let credits = decoded.credits else {
            return .failed("response carried no credits object")
        }

        return .balance(
            amount: credits.currentBalance,
            currency: credits.currency,
            elapsedMS: elapsedMS
        )
    }

    // MARK: - Wire types

    /// Only the fields we consume. `username` is decoded but unused — it is
    /// documented as present, and naming it here makes that explicit rather
    /// than leaving a reader wondering whether it was missed.
    private struct ResponseBody: Decodable {
        let username: String?
        let credits: Credits?
    }

    /// The `credits` object. Both fields are required *within* it: an object
    /// that is present but missing its balance is a genuinely broken response,
    /// and defaulting the currency would be inventing the units of a number
    /// shown to the user.
    private struct Credits: Decodable {
        let currentBalance: Double
        let currency: String

        enum CodingKeys: String, CodingKey {
            case currentBalance = "current_balance"
            case currency
        }
    }

    // MARK: - Helpers
    //
    // Deliberately local copies of FalClient's equivalents rather than a
    // shared utility: those are `private` there, and widening FalClient's API
    // to serve a menu line would be the tail wagging the dog. Three short
    // functions is the cheaper price.

    /// Remove the API key from a string that is about to escape into an
    /// ``Outcome``.
    ///
    /// fal has no reason to echo the key back, but a proxy or a verbose error
    /// page might, and an outcome is exactly the thing that ends up in a trace
    /// line. This makes the guarantee mechanical rather than assumed.
    private func redacting(_ text: String) -> String {
        text.replacingOccurrences(of: apiKey, with: "<redacted>")
    }

    /// Redact first, *then* truncate.
    ///
    /// The order matters: truncating first could cut through the middle of an
    /// echoed key and leave a prefix of it in the snippet, which no later
    /// redaction can match. Doing it this way, a key can only ever be replaced
    /// whole.
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

    /// `Duration` → milliseconds. Same conversion ``FalClient`` and
    /// ``WhisperClient`` use, so all three `elapsedMS` values are comparable.
    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
