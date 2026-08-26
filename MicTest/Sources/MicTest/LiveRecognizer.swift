//
//  LiveRecognizer — realtime, on-device, word-by-word Thai speech recognition
//
//  This replaces a round trip to a local whisper server that cost ~2100 ms per utterance and
//  could only ever produce text *after* the user stopped talking. `SFSpeechRecognizer` in
//  on-device mode streams a growing transcription while the user is still speaking, which is
//  what makes "type into another app as you talk" possible at all.
//
//  Why the LEGACY Speech API and not `SpeechAnalyzer`/`SpeechTranscriber`:
//  the macOS 26 API does not support Thai. Measured on this machine (macOS 26.5):
//  `SpeechTranscriber` has no th-TH asset, while `SFSpeechRecognizer(locale: "th-TH")`
//  reports `isAvailable == true` AND `supportsOnDeviceRecognition == true`. So the older,
//  "deprecated-adjacent" API is the only one that can do this job, and it does it well.
//
//  ── THE ISOLATION RULE — do not weaken it ──────────────────────────────────────────────
//
//  `append(_:)` is called directly from AVFAudio's realtime render thread, from inside an
//  `installTap` closure. This app already hard-crashed once with EXC_BREAKPOINT inside
//  `_dispatch_assert_queue_fail`, called from `swift_task_isCurrentExecutor`, because a tap
//  closure silently inherited `@MainActor` isolation and was then invoked off the render
//  thread. The runtime asked "am I on the main executor?", found a render thread, and killed
//  the process. Therefore:
//
//    * This type is NOT `@MainActor` and must never become one.
//    * `@unchecked Sendable` is honest: an `OSAllocatedUnfairLock` provides the mutual
//      exclusion the compiler cannot see. Unfair (not `NSLock`) because unfair locks
//      participate in priority donation — a low-priority restart on the session queue must
//      never leave the high-priority audio thread spinning.
//    * `append` does no file I/O, no `print`, no UI, no `MainActor.assumeIsolated`, no
//      allocation, and holds the lock for exactly one pointer read. Everything else happens
//      outside the critical section.
//    * The `onPartial` / `onFinal` / `onState` callbacks are `@Sendable` and fire on whatever
//      thread Speech chose. This class deliberately does NOT hop to the main actor — that is
//      the consumer's job, and doing it here would reintroduce the exact crash above.
//

import AVFAudio
import Foundation
import Speech
import os

final class LiveRecognizer: @unchecked Sendable {

    // MARK: - Public surface

    enum State: Sendable {
        case idle
        case listening
        /// Carries a human-readable reason: unsupported locale, availability loss, a
        /// recognition error we are recovering from, or a permanent give-up.
        case unavailable(String)
    }

    enum RecognizerError: Error, CustomStringConvertible {
        /// No `SFSpeechRecognizer` exists for this locale on this system.
        case localeUnsupported(String)
        /// The recognizer exists but `isAvailable` is false right now.
        case recognizerUnavailable(String)
        /// The recognizer exists and is available, but cannot run without the network.
        case onDeviceUnsupported(String)
        /// `recognitionTask(with:resultHandler:)` handed back nothing.
        case taskCreationFailed(String)

        var description: String {
            switch self {
            case .localeUnsupported(let d): return "locale unsupported: \(d)"
            case .recognizerUnavailable(let d): return "recognizer unavailable: \(d)"
            case .onDeviceUnsupported(let d): return "on-device recognition unsupported: \(d)"
            case .taskCreationFailed(let d): return "cannot start recognition task: \(d)"
            }
        }
    }

    /// The only locale this recognizer is built for. Thai is the whole point of the file.
    static let localeIdentifier = "th-TH"

    /// Partial (growing) transcription. Fires many times per utterance, on an arbitrary
    /// thread — the consumer hops to the main actor itself.
    var onPartial: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onPartial }
        set { lock.lock(); defer { lock.unlock() }; _onPartial = newValue }
    }

    /// Final transcription for one utterance. Fires once per utterance boundary.
    var onFinal: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFinal }
        set { lock.lock(); defer { lock.unlock() }; _onFinal = newValue }
    }

    /// State changes and errors, for UI.
    var onState: (@Sendable (State) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onState }
        set { lock.lock(); defer { lock.unlock() }; _onState = newValue }
    }

    // MARK: - Tuning

    /// `SFSpeechRecognizer` enforces a per-request audio limit of roughly one minute — but
    /// the measured failure mode on this machine arrives much earlier: under continuous
    /// no-pause Thai speech, on-device requests went silently dead ("wedged": no partials,
    /// no error, audio still flowing) at ~35 s of request age (trace 14:02), and once at
    /// the old 50 s rotation itself (trace 10:57). A wedged request cannot be revived by
    /// stop()+start() (two consecutive bounces both stayed silent); only a full engine
    /// restart recovers, which costs the user seconds of speech.
    ///
    /// So: rotate every 20 s — comfortably inside the youngest observed wedge — keeping
    /// every request young enough that the wedge window is never reached. Rotation is
    /// OVERLAPPED (see `beginOverlappedRotation`): the replacement request starts while the
    /// old one keeps running and keeps delivering, and the consumer only sees the boundary
    /// when the replacement produces its first partial. The old kill-then-start rotation
    /// put a measured 2-4 s hole in live typing at every seam — `endAudio()` stopped the
    /// old request's contributions and the fresh request needed seconds of audio before its
    /// first partial. The 20 s cadence itself is unchanged and load-bearing. During normal
    /// pause-punctuated speech this watchdog rarely fires (natural pauses finalise long
    /// before 20 s).
    private static let sessionRotationSeconds: Double = 20

    /// Cap on an overlapped rotation. If the replacement session produces no partial this
    /// long after starting (it wedged from birth, or the user was silent through the whole
    /// overlap), give up on a seamless cutover and fall back to the old hard rotation:
    /// `endAudio()` the old request — its flushed final still delivers, because it is still
    /// the delivery owner — then promote the replacement with the normal `.listening`
    /// boundary. The old request reaching ~26-28 s of age during a silent overlap is
    /// acceptable: the measured wedge is a continuous-speech phenomenon, and if speech
    /// resumes mid-overlap the replacement's first partial cuts over anyway.
    private static let overlapFallbackSeconds: Double = 6

    /// After a deliberate `stop()`, how long to wait for the flushed final before giving up
    /// and cancelling the task outright. Bounded so `stop()` can never leak a live task.
    private static let finalFlushTimeoutSeconds: Double = 2.0

    /// Restart backoff after a recognition error. Speech throttles aggressive clients
    /// (kAFAssistantErrorDomain 1101/1107 and friends), and a tight restart loop is exactly
    /// what triggers it, so failures back off exponentially from here.
    private static let restartBaseDelaySeconds: Double = 0.3
    private static let restartMaxDelaySeconds: Double = 8.0

    /// Consecutive failed restarts before we stop trying and report `.unavailable`. Without a
    /// cap a throttled recognizer would retry forever and look like a hang.
    private static let maxConsecutiveFailures = 6

    // MARK: - Session

    /// One recognition request plus its task. Modelled as an object so a callback can capture
    /// its OWN session by reference and compare identity, instead of racing against shared
    /// mutable state it has no lock on.
    private final class Session: @unchecked Sendable {
        /// Monotonic id. `generation == owner.generation` means "still the live session";
        /// anything else is stale and its callbacks are dropped. This is the mechanism that
        /// makes `stop()` immediately followed by `start()` safe.
        let generation: Int
        let request: SFSpeechAudioBufferRecognitionRequest
        /// When the session was created. Trace timing only — how long an overlapped-rotation
        /// replacement took to produce its first partial.
        let createdAt = DispatchTime.now()
        /// Set immediately after `recognitionTask` returns. Only touched under the owner lock.
        var task: SFSpeechRecognitionTask?
        /// Deliberate `stop()`: drain one last final, suppress partials, do not auto-restart.
        var isStopping = false
        /// Fully done — final delivered, or torn down. Guards against double teardown.
        var isFinished = false

        init(generation: Int, request: SFSpeechAudioBufferRecognitionRequest) {
            self.generation = generation
            self.request = request
        }
    }

    // MARK: - Shared state

    /// Guards every stored property below. Held for pointer reads and small mutations only —
    /// never across a Speech API call, and never across a user callback.
    private let lock = OSAllocatedUnfairLock()

    private var _onPartial: (@Sendable (String) -> Void)?
    private var _onFinal: (@Sendable (String) -> Void)?
    private var _onState: (@Sendable (State) -> Void)?

    /// Monotonic allocator for session generations, bumped on every teardown and on every
    /// session creation. Liveness of a callback's session is decided by IDENTITY against the
    /// `current`/`pending` slots plus the per-session flags, not by comparing against this
    /// counter: during an overlapped rotation the newest ALLOCATED generation belongs to the
    /// pending replacement while the older `current` is still the delivery owner.
    private var generation = 0
    /// Generation of the DELIVERY OWNER — the session whose partials/finals/idles the
    /// consumer is currently receiving. Advances when `beginSession` installs a session and
    /// when `promotePending` cuts an overlapped rotation over; it does NOT advance when a
    /// pending replacement is merely created, which is what lets the old session keep
    /// delivering uninterrupted through the overlap. Every emission-time staleness check
    /// compares against this: a mismatch means a newer session already owns delivery — its
    /// `.listening` has already reset the consumer's typed high-water mark — so the stale
    /// event must be suppressed rather than typed into the successor's utterance.
    private var newestSessionGeneration = 0
    /// The delivery owner. `append` feeds it; its events reach the consumer (subject to the
    /// emission-time staleness checks). During an overlapped rotation this remains the OLD
    /// session until cutover/promotion.
    private var current: Session?
    /// The warm replacement during an overlapped rotation (`beginOverlappedRotation`).
    /// While non-nil, `append` feeds BOTH `current` and this session; every event from this
    /// session is suppressed until its first partial promotes it (`promotePending`), at
    /// which point it becomes `current` and the old session is cancelled without a final.
    /// Invariants: `pending != nil` implies `isStarted`; the slot never holds a finished
    /// session; `newestSessionGeneration` never points at a session sitting in this slot.
    private var pending: Session?
    private var isStarted = false
    private var contextualStrings: [String] = []
    /// Consecutive restart failures, reset by any successful result.
    private var consecutiveFailures = 0

    /// ── PROOF-OF-LIFE FROM THE SPEECH SERVICE ────────────────────────────────────────
    /// When the Speech service last handed us an error, and what it was.
    ///
    /// This exists because the recognizer watchdog in main.swift cannot otherwise tell
    /// "the on-device speech daemon is wedged" apart from "the room is noisy and the user
    /// simply paused" — and its third tier `pkill`s `localspeechrecognition`, a macOS
    /// system XPC service. The trace of 15:25-15:26 is the case that forced this: for a
    /// 70-second window an error arrived roughly every 7 s, EVERY one of them was
    /// swallowed by the staleness guards below, and the log recorded only that something
    /// had been suppressed — never which error, never that one had arrived at all on the
    /// uncounted paths. Blind, the watchdog climbed all three tiers and killed a system
    /// service that was in fact answering us every 7 seconds.
    ///
    /// So this is recorded for EVERY error the service delivers, including stale ones from
    /// superseded generations. That is the whole point: a stale error is still proof the
    /// system-wide daemon is alive and talking to this process, which is exactly the fact
    /// the watchdog needs before it escalates to killing it. Deliberately NOT reset
    /// anywhere — it is a monotonic "last heard from" timestamp, not a failure counter, and
    /// clearing it on success would destroy the only evidence the watchdog consults.
    ///
    /// Guarded by `lock` like every other stored property here, and fully `private` on
    /// purpose: this class is `@unchecked Sendable`, so an unsynchronized cross-thread read
    /// of these two is a data race even though only this file writes them. The ONLY reader
    /// is `lastServiceError()`, which takes the lock. Do not widen this back to
    /// `private(set)` for the convenience of a call site.
    private var lastServiceErrorAt: Date?
    private var lastServiceErrorText: String?

    /// All session teardown/creation happens here, never on the audio thread and never on the
    /// Speech callback thread. Serialising it is what keeps "final arrives → restart" from
    /// re-entering while `stop()` is running.
    private let queue = DispatchQueue(label: "LiveRecognizer.session", qos: .userInitiated)

    /// Created once. `SFSpeechRecognizer` is expensive to build and its availability is a live
    /// property, so we hold one and re-read `isAvailable` on every check.
    private let recognizer: SFSpeechRecognizer?

    // MARK: - Init

    init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.localeIdentifier))
    }

    // MARK: - Authorization

    /// Wraps the callback-based `SFSpeechRecognizer.requestAuthorization` in an async
    /// continuation. The `resumed` flag exists because resuming a continuation twice is a
    /// hard crash, and a system callback firing twice is not something we can rule out by
    /// reading documentation.
    ///
    /// Note this only covers *speech* authorization; microphone access is the audio engine's
    /// problem and is requested separately by whoever owns the tap.
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            SFSpeechRecognizer.requestAuthorization { status in
                let alreadyResumed = resumed.withLock { flag -> Bool in
                    defer { flag = true }
                    return flag
                }
                guard !alreadyResumed else { return }
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Capability

    /// True when a th-TH recognizer exists, is available, and supports on-device recognition.
    ///
    /// Deliberately recomputed on every access rather than cached: `isAvailable` genuinely
    /// flips at runtime (asset eviction, system pressure), and a cached `true` would send us
    /// into `start()` only to fail there.
    var isSupported: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    /// The last error the Speech service delivered, and when — the ONLY synchronized way to
    /// read `lastServiceErrorAt`/`lastServiceErrorText`. Read-only and side-effect free: it
    /// takes the lock, copies two values, and returns. Safe to call from any thread EXCEPT
    /// the audio render path (`append`), which must never contend for this lock beyond its
    /// one pointer read.
    ///
    /// Returns nil until the service has errored at least once in this process's lifetime.
    /// A recent timestamp means the daemon answered us recently — see
    /// `lastServiceErrorAt` for why that is the fact a watchdog needs before escalating.
    func lastServiceError() -> (Date, String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let at = lastServiceErrorAt, let text = lastServiceErrorText else { return nil }
        return (at, text)
    }

    // MARK: - Lifecycle

    /// Begin a session. A no-op if one is already running.
    ///
    /// The already-started check comes FIRST, before validation: a second `start()` on a
    /// running session must be a cheap no-op, not a re-litigation of availability that could
    /// throw and tear down a session that is working fine.
    func start() throws {
        lock.lock()
        if isStarted {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            try validateSupport()
        } catch {
            // Surface it to the UI as well as throwing, so a consumer that only wired up
            // `onState` still learns why nothing is happening.
            emitState(.unavailable(String(describing: error)))
            throw error
        }

        lock.lock()
        isStarted = true
        consecutiveFailures = 0
        lock.unlock()

        try beginSession(isRestart: false)
    }

    /// End the current utterance, flush a final result, and stop.
    ///
    /// `endAudio()` rather than a bare `cancel()`: it tells Speech that no more audio is
    /// coming, so it finalises what it has and delivers one last result. That result is still
    /// wanted — it is the tail of what the user actually said — unless a newer session starts
    /// before the flush lands, in which case the stale-final guard in `handle` suppresses it
    /// (see `newestSessionGeneration`). Partials from the stopping
    /// session are suppressed from here on, because after `stop()` (and a possible immediate
    /// `start()`) a late partial would clobber the new session's text in the UI.
    ///
    /// Bumping the generation here is what makes `stop()` + `start()` safe: `append` stops
    /// feeding the old request instantly, and the old task's auto-restart path is disarmed.
    ///
    /// If an overlapped rotation is in flight, the pending replacement dies silently here
    /// too: it never became the delivery owner, so it owes the consumer nothing — the
    /// owner's flush semantics below are unchanged (its final delivers; the replacement is
    /// suppressed).
    func stop() {
        lock.lock()
        let replacement = pending
        pending = nil
        guard isStarted, let session = current else {
            isStarted = false
            current = nil
            generation &+= 1
            lock.unlock()
            if let replacement { finish(replacement, deliverIdle: false) }
            emitState(.idle)
            return
        }
        session.isStopping = true
        isStarted = false
        current = nil
        // The stopping session keeps its old generation, which now differs from `generation`.
        // The alive-check in `handle` treats "stale but stopping and unfinished" as eligible
        // for AT MOST one final — delivered only if no newer session starts before the flush
        // lands (the stale-final guard) — and nothing else.
        generation &+= 1
        lock.unlock()

        // Clearing `pending` under the lock above already makes a concurrent cutover
        // impossible (`promotePending` re-validates identity); this cancels the
        // replacement's task promptly so it cannot run on toward Speech's per-request
        // ceiling. Its late callbacks are dropped by the identity checks in `handle`.
        if let replacement { finish(replacement, deliverIdle: false) }

        session.request.endAudio()

        // Safety net: if Speech never delivers the flushed final (throttled, or the audio was
        // pure silence), cancel so the task cannot outlive the session forever.
        queue.asyncAfter(deadline: .now() + Self.finalFlushTimeoutSeconds) { [weak self] in
            guard let self else { return }
            self.finish(session, deliverIdle: true)
        }
    }

    // MARK: - Realtime audio thread

    /// Called on the REALTIME AUDIO THREAD.
    ///
    /// One lock acquisition, one pointer read, unlock — then `append` outside the critical
    /// section. `SFSpeechAudioBufferRecognitionRequest.append(_:)` is safe to call from the
    /// audio thread; it hands the buffer to Speech's own queue. Nothing here allocates.
    ///
    /// A nil request means we are between sessions (stopped, or mid auto-restart). Dropping a
    /// few milliseconds of audio there is correct: there is nothing to feed it to.
    ///
    /// During an overlapped rotation the SAME buffer feeds both the outgoing request and its
    /// warm replacement — still one lock acquisition, now two pointer reads, and both
    /// `append`s outside the critical section. Duplication is cheap: both requests are
    /// on-device.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = current?.request
        let pendingRequest = pending?.request
        lock.unlock()
        request?.append(buffer)
        pendingRequest?.append(buffer)
    }

    // MARK: - Contextual biasing

    /// Bias recognition toward these terms — command verbs, branch names, project nouns.
    /// Applied to the live request immediately as well as stored for every future session,
    /// so the caller can update the vocabulary mid-dictation without restarting.
    func setContextualStrings(_ terms: [String]) {
        lock.lock()
        contextualStrings = terms
        let request = current?.request
        let pendingRequest = pending?.request
        lock.unlock()
        request?.contextualStrings = terms
        pendingRequest?.contextualStrings = terms
    }

    // MARK: - Session management

    private func validateSupport() throws {
        guard let recognizer else {
            throw RecognizerError.localeUnsupported(
                "no SFSpeechRecognizer for \(Self.localeIdentifier) on this system")
        }
        guard recognizer.isAvailable else {
            throw RecognizerError.recognizerUnavailable(
                "\(Self.localeIdentifier) recognizer exists but isAvailable == false")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw RecognizerError.onDeviceUnsupported(
                "\(Self.localeIdentifier) requires the network; refusing to send audio off-device")
        }
    }

    /// Build a fresh request + task and install it as the current session.
    ///
    /// - Parameter isRestart: `true` for the transparent restarts (utterance boundary with no
    ///   overlap replacement to promote, error recovery). Watchdog rotation no longer comes
    ///   through here — it builds its replacement in `beginOverlappedRotation`. A restart
    ///   must not throw into the caller — there is no caller — so failures are reported
    ///   through `onState` and retried with backoff.
    private func beginSession(isRestart: Bool) throws {
        lock.lock(); discardRetries = 0; lock.unlock()
        guard let recognizer else {
            throw RecognizerError.localeUnsupported(
                "no SFSpeechRecognizer for \(Self.localeIdentifier)")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // The entire justification for this file. Off-device would reintroduce network
        // latency and ship the user's microphone to a server.
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        lock.lock()
        // Still wanted? A `stop()` racing an auto-restart lands here.
        guard isStarted else {
            lock.unlock()
            return
        }
        generation &+= 1
        let session = Session(generation: generation, request: request)
        // Same critical section as the install: `newestSessionGeneration` and `current` must
        // move together, or a draining predecessor's staleness check could miss this
        // successor and deliver a stale final anyway.
        newestSessionGeneration = generation
        request.contextualStrings = contextualStrings
        current = session
        lock.unlock()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Fires on an arbitrary Speech-owned thread. Never hop to the main actor here.
            self?.handle(session: session, result: result, error: error)
        }

        lock.lock()
        session.task = task
        let installed = (current === session)
        lock.unlock()

        guard installed else {
            // `stop()` won the race while we were building. Discard immediately.
            task.cancel()
            return
        }

        // Rotate before Speech's ~1 minute per-request ceiling rather than after it.
        armRotationTimer(for: session)

        emitState(.listening)
        _ = isRestart
    }

    /// The Speech result handler. Arbitrary thread, no isolation, no locks held on entry.
    private func handle(session: Session, result: SFSpeechRecognitionResult?, error: (any Error)?) {
        // Formatted BEFORE the lock: the discipline above is that `lock` covers pointer
        // reads and small mutations only, and `NSError.localizedDescription` can reach into
        // ObjC bundle lookup. Only the two assignments happen in the critical section.
        // One optional, not two, so the timestamp and the text can never disagree.
        let serviceError: (at: Date, text: String)? = error.map {
            (at: Date(), text: Self.describeRecognizerError($0))
        }

        lock.lock()
        let isCurrent = (current === session)
        let isPendingSession = (pending === session)
        // A stopping session is stale by generation but is still owed exactly one final.
        let isDraining = session.isStopping && !session.isFinished
        if result != nil && error == nil {
            consecutiveFailures = 0
        }
        // Every Speech callback in this file routes through here — `beginSession` and
        // `beginOverlappedRotation` both install closures that call `handle` — so this is
        // the one choke point that sees EVERY error, before any staleness guard downstream
        // gets a chance to swallow it. Recorded unconditionally, ahead of the pending-,
        // alive-, stopping- and ownership-checks below, precisely because those are the
        // guards that made the 15:25-15:26 errors invisible. Observation only: nothing
        // downstream reads these fields, so no dispatch decision changes.
        if let serviceError {
            lastServiceErrorAt = serviceError.at
            lastServiceErrorText = serviceError.text
        }
        lock.unlock()

        // A pending replacement (overlapped rotation, pre-cutover) never reaches the
        // consumer through the paths below: its first partial promotes it, anything else
        // retires it. Routed before the alive check because a pending session is neither
        // current nor draining.
        if isPendingSession {
            handlePendingResult(session: session, result: result, error: error)
            return
        }

        // Ghost from a cancelled task. Drop it before it can write into the new session.
        // Liveness is identity: a finished session is never left installed in `current`
        // (every teardown clears the slot in the same critical section), so `current ===
        // session` is authoritative even during an overlapped rotation — when the newest
        // ALLOCATED generation belongs to the pending replacement, not the delivery owner.
        let alive = isCurrent || isDraining
        guard alive else {
            // The quietest discard of the lot: a ghost carrying an ERROR used to vanish
            // here without a single line of trace, which is one of the ways the
            // 15:25-15:26 window looked like silence rather than like a service that was
            // answering every ~7 s. Traced only when an error is actually present — a
            // ghost *result* is not an error discard and would just add noise.
            if let error {
                Self.trace("recognizer: discarded error from dead session "
                    + "\(session.generation) (task already cancelled/retired; not counted) — "
                    + Self.describeRecognizerError(error))
            }
            return
        }

        if let result {
            let text = result.bestTranscription.formattedString

            // ── CO-ARRIVING ERROR: TRACE ONLY, NEVER A DISPATCH DECISION ───────────────
            // Speech can hand back a result and an error in the SAME callback. The whole
            // `if let result` branch returns unconditionally, so such an error never
            // reaches `guard let error` below: it is dropped outright and counted
            // nowhere. That is fine as behaviour — this helper changes NOTHING about it —
            // but it used to also be logged nowhere on most paths. A throttling
            // `kAFAssistantErrorDomain` 1107 riding in beside a good final left a trace
            // that read like an ordinary successful utterance, which is the exact "looks
            // like nothing went wrong" signature this instrumentation pass exists to
            // kill. Every path out of this branch now names it.
            //
            // NOT a duplicate of the unconditional `lastServiceErrorAt` /
            // `lastServiceErrorText` record at the top of `handle`. That one is the
            // watchdog's machine-readable latch and must stay where it is; this one is the
            // human-readable line in /tmp/mictest_trace.txt. Neither replaces the other —
            // do not "deduplicate" them.
            //
            // A nested func called ONLY from inside `if let error` tests is what keeps the
            // partial path free. Partials arrive many times per second, and a partial with
            // no error must never format a Date, build a message, or call
            // `describeRecognizerError`. Do NOT hoist this into an unconditional
            // `let coArrivingError = …` at the top of the branch, and do not lift any
            // interpolation out of a call site into the surrounding scope.
            func traceCoArrivingError(_ error: any Error, _ disposition: String) {
                Self.trace("recognizer: co-arriving error alongside \(disposition) "
                    + "(the result path drops it; not counted) — "
                    + Self.describeRecognizerError(error))
            }

            if result.isFinal {
                finish(session, deliverIdle: false)
                // ── STALE-FINAL GUARD ──────────────────────────────────────────────────
                // Staleness is re-read at EMISSION time, under the lock, not reused from
                // the alive-check above: `stop()` immediately followed by `start()` (the
                // recogniser-watchdog bounce, the drain-cancel re-toggle) installs a
                // successor while this flushed final is still in flight. The successor has
                // already emitted `.listening`, which reset the consumer's typed high-water
                // mark, so delivering this final now would re-type the entire previous
                // utterance. A draining session therefore delivers its final ONLY if no
                // newer session has started since it began. A deliberate stop with no
                // restart still delivers — `newestSessionGeneration` still equals ours —
                // which keeps the "last utterance lands after toggle-off" behaviour intact.
                lock.lock()
                let stopping = session.isStopping
                let superseded = (newestSessionGeneration != session.generation)
                lock.unlock()

                // ── A SECOND, STRUCTURAL DISCARD, NOT A STALENESS ONE ──────────────────
                // The whole `if let result` branch returns unconditionally, so an error
                // delivered ALONGSIDE a result never reaches `guard let error` below: it is
                // dropped outright, counted nowhere, and until now logged nowhere. That is
                // a different bug from the staleness suppressions, so it gets its own
                // wording rather than being folded into them. Computed inside the `isFinal`
                // branch, not at the top of the result branch — finals are rare, partials
                // are not, and this must not allocate per partial. Empty when no error
                // arrived, which leaves the ordinary trace lines byte-identical.
                let coArrivingError = error.map {
                    " — plus a co-arriving error the result path drops: "
                        + Self.describeRecognizerError($0)
                } ?? ""

                if stopping {
                    if superseded {
                        Self.trace("recognizer: suppressed stale flushed final "
                            + "(len \(text.count)) — a newer session started after stop()"
                            + coArrivingError)
                    } else {
                        // The deliberate-stop delivery path. It emits, so it has no
                        // suppression line to carry `coArrivingError` as a suffix — hence
                        // its own line, on the error case only.
                        if let error {
                            traceCoArrivingError(error, "a delivered flushed final "
                                + "(len \(text.count)) from a stopping session")
                        }
                        if !text.isEmpty { emitFinal(text) }
                        emitState(.idle)
                    }
                } else {
                    // The same re-read protects the non-stopping path: an overlapped-
                    // rotation cutover can promote the replacement while this final is in
                    // flight, and the successor's `.listening` has already reset the
                    // consumer's high-water mark.
                    guard !superseded else {
                        Self.trace("recognizer: suppressed stale final (len \(text.count)) "
                            + "— an overlap cutover promoted the replacement while it was "
                            + "in flight" + coArrivingError)
                        return
                    }
                    // The live owner's ordinary final: the single most dangerous place to
                    // lose a co-arriving error, because everything downstream looks like a
                    // clean utterance. Traced before the emit so the trace reads causally.
                    if let error {
                        traceCoArrivingError(error, "a delivered final (len \(text.count)) "
                            + "on the live owner session")
                    }
                    if !text.isEmpty { emitFinal(text) }
                    // ── UTTERANCE BOUNDARY: PROMOTE THE OVERLAP REPLACEMENT, OR RESTART ─
                    // SFSpeechRecognizer finalises after a pause and then goes permanently
                    // quiet: the task is done and no further audio is ever recognised. For
                    // continuous dictation that would mean the user has to re-press the key
                    // after every sentence. So on every non-deliberate final we stand up a
                    // successor. If an overlapped rotation already has a warm replacement
                    // consuming audio, promote IT — this is also how the 6 s overlap
                    // fallback completes: `overlapFallback` flushes the old request, the
                    // final lands here (still the delivery owner, so it delivers), and the
                    // replacement takes over with the normal `.listening` boundary.
                    // Otherwise build a brand-new request and task as always. From the
                    // consumer's point of view nothing happened except another `onFinal`
                    // followed by `.listening`.
                    //
                    // The fresh-request path is hopped to the session queue rather than
                    // done inline: we are currently inside the OLD task's callback frame,
                    // and creating its replacement from there invites re-entrancy against
                    // a concurrent `stop()`.
                    lock.lock()
                    let replacement = pending
                    lock.unlock()
                    var promoted = false
                    if let replacement {
                        promoted = promotePending(replacement, traceMessage:
                            "overlap: promoted replacement session \(replacement.generation) "
                            + "at the old session's utterance boundary")
                    }
                    if !promoted {
                        restart(after: 0, reason: nil)
                    }
                }
            } else if !session.isStopping {
                // Partials from a stopping session are suppressed — see `stop()`. The
                // ownership re-read mirrors the stale-final guard: a partial that passed
                // the alive check a moment before an overlap cutover must not land after
                // the successor's `.listening` has reset the consumer's high-water mark.
                // Pre-cutover, the old session IS the owner, so its partials flow
                // uninterrupted through the whole overlap — that is the entire point.
                lock.lock()
                let owner = (newestSessionGeneration == session.generation)
                lock.unlock()
                // Hot path: `error` is nil for effectively every partial, and then this is
                // one optional test and nothing else — no Date, no interpolation, no
                // allocation. Both message variants live INSIDE the binding on purpose.
                if let error {
                    traceCoArrivingError(error, owner
                        ? "a delivered partial (len \(text.count))"
                        : "a partial dropped by the ownership re-read (len \(text.count))")
                }
                if owner { emitPartial(text) }
            } else if let error {
                // The one path that did nothing whatsoever: a non-final result from a
                // stopping session, whose partials `stop()` suppresses. No emit, no
                // counter, no line — a co-arriving error vanished here completely. This
                // `else if` replaces an implicit empty else; it adds a trace and no
                // control flow, and the `return` below is still the single exit.
                traceCoArrivingError(error, "a suppressed partial "
                    + "(len \(text.count)) from a stopping session")
            }
            return
        }

        guard let error else { return }

        // Errors here are routine, not exceptional: the ~1 minute request ceiling, Speech
        // throttling a chatty client, an asset being swapped out. The honest response is to
        // report it and stand a new request back up, with backoff so we do not become the
        // reason we are being throttled.
        finish(session, deliverIdle: false)
        if session.isStopping {
            // Same rule as the stale-final guard above: once a successor session has
            // started, the state stream belongs to it, and a stale `.idle` from this
            // draining session would flip the consumer to idle while the new session is
            // actively listening.
            lock.lock()
            let superseded = (newestSessionGeneration != session.generation)
            lock.unlock()
            if superseded {
                // The error itself is swallowed here along with the `.idle`, and it is not
                // counted (this path returns before `consecutiveFailures` is touched at
                // all). Naming it is the whole point of this instrumentation pass: at
                // 15:25-15:26 lines exactly like this one repeated every ~7 s and said
                // nothing about what had actually arrived.
                Self.trace("recognizer: suppressed stale idle from draining session "
                    + "(error path) — a newer session started after stop(); error not "
                    + "counted — " + Self.describeRecognizerError(error))
            } else {
                emitState(.idle)
            }
            return
        }

        lock.lock()
        let wanted = isStarted
        // Ownership re-read, same discipline as the stale-final guard: if an overlap
        // cutover promoted the replacement while this error was in flight, the error
        // belongs to a session that is already history — do not count it, do not report
        // it, and above all do not restart on top of the live successor.
        let ownerAtError = (newestSessionGeneration == session.generation)
        if ownerAtError { consecutiveFailures += 1 }
        let failures = consecutiveFailures
        // Captured in the SAME critical section rather than re-read for the trace below:
        // `lock` is not recursive, the trace runs outside it, and taking it a second time
        // just to format a log line would add lock traffic to a path the audio thread also
        // contends for.
        let ownerGeneration = newestSessionGeneration
        lock.unlock()

        guard wanted, ownerAtError else {
            // ── THE DISCARD THAT BLINDED THE WATCHDOG ──────────────────────────────────
            // An error the Speech service genuinely delivered, dropped here without ever
            // reaching `emitState`. The two exit reasons are logged distinguishably ON
            // PURPOSE: main.swift's watchdog has to tell "this generation is retired, the
            // successor is fine" apart from "the recognizer is stopped", and one line
            // saying only "discarded" would recreate the exact ambiguity this pass exists
            // to remove.
            //
            // Note the counter is reported, not assumed: the increment above is gated on
            // `ownerAtError` ALONE, so an owner-generation error with `isStarted == false`
            // HAS already been counted even though it exits here. Logging "not counted"
            // for that case would be a false statement in the one file we go to for the
            // truth. Behaviour is untouched — the guard still returns, the counter is
            // whatever it already was, nothing is emitted.
            let counted = ownerAtError
                ? "counted (consecutiveFailures now \(failures)) but not acted on"
                : "NOT counted (generation \(session.generation) retired; owner is "
                    + "\(ownerGeneration))"
            let stopped = wanted ? "" : "; recognizer is stopped (isStarted == false)"
            Self.trace("recognizer: error arrived and was discarded without reaching the "
                + "consumer — " + counted + stopped + " — "
                + Self.describeRecognizerError(error))
            return
        }

        let message = (error as NSError).localizedDescription
        guard failures <= Self.maxConsecutiveFailures else {
            lock.lock()
            isStarted = false
            current = nil
            let orphanedReplacement = pending
            pending = nil
            generation &+= 1
            lock.unlock()
            // A pending overlap replacement must not outlive the give-up — nothing would
            // ever promote or rotate it.
            if let orphanedReplacement { finish(orphanedReplacement, deliverIdle: false) }
            emitState(.unavailable(
                "gave up after \(failures) consecutive recognition failures: \(message)"))
            return
        }

        // If the delivery owner died mid-overlap, its warm replacement is strictly better
        // than a backoff-delayed fresh request: it already exists and is already consuming
        // audio. Promote it now; the backoff below remains the path when no replacement
        // exists (or a concurrent `stop()` just retired it, in which case `restart`'s own
        // guard makes the fallthrough a no-op).
        lock.lock()
        let replacement = pending
        lock.unlock()
        if let replacement {
            emitState(.unavailable("recognition error (promoting warm replacement): \(message)"))
            if promotePending(replacement, traceMessage:
                "overlap: promoted replacement session \(replacement.generation) after the "
                + "old session errored mid-overlap") {
                return
            }
        }

        let delay = min(Self.restartBaseDelaySeconds * pow(2, Double(failures - 1)),
                        Self.restartMaxDelaySeconds)
        emitState(.unavailable("recognition error (retry \(failures) in \(String(format: "%.1f", delay)) s): \(message)"))
        restart(after: delay, reason: nil)
    }

    /// End a session for good: cancel its task, clear it if it is still current. Idempotent —
    /// the `stop()` timeout and the final result both call it.
    private func finish(_ session: Session, deliverIdle: Bool) {
        lock.lock()
        if session.isFinished {
            lock.unlock()
            return
        }
        session.isFinished = true
        let task = session.task
        session.task = nil
        if current === session {
            current = nil
            generation &+= 1
        }
        // Read in the same critical section that retires the session. `deliverIdle` is only
        // ever true on the `stop()` flush-timeout path; if a newer session has started by
        // the time that timeout fires, its `.idle` is stale and must not land after the
        // successor's `.listening`. (No final is being dropped here: had Speech delivered
        // one, `handle` would already have finished this session and this call would have
        // returned above.)
        let superseded = (newestSessionGeneration != session.generation)
        lock.unlock()

        task?.cancel()
        if deliverIdle {
            if superseded {
                Self.trace("recognizer: suppressed stale idle after final-flush timeout — "
                    + "a newer session started after stop()")
            } else {
                emitState(.idle)
            }
        }
    }

    /// Tear the current session down and stand a new one up. Used by both the utterance
    /// boundary and the error path; `reason`, when present, is reported before the restart.
    private func restart(after delay: TimeInterval, reason: String?) {
        if let reason { emitState(.unavailable(reason)) }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let wanted = self.isStarted && self.current == nil
            self.lock.unlock()
            guard wanted else { return }
            do {
                try self.beginSession(isRestart: true)
            } catch {
                self.emitState(.unavailable("restart failed: \(String(describing: error))"))
            }
        }
    }

    /// Arm the 20 s rotation watchdog for a session. Armed at session CREATION — for a
    /// replacement created mid-overlap that means its wedge clock starts a couple of
    /// seconds before it becomes the delivery owner, ample margin inside the ~35 s wedge
    /// window. If the session is no longer current when the timer fires, it is already
    /// gone and this is a no-op (a discarded replacement, a stopped session).
    private func armRotationTimer(for session: Session) {
        queue.asyncAfter(deadline: .now() + Self.sessionRotationSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillLive = (self.current === session)
            self.lock.unlock()
            guard stillLive else { return }
            self.beginOverlappedRotation(of: session)
        }
    }

    // MARK: - Overlapped rotation

    /// The 20 s watchdog, without the typing hole. The old rotation was kill-then-start:
    /// `endAudio()` the aging request, wait for its flushed final, then build a fresh one —
    /// and the fresh request needed seconds of audio before its first partial, a measured
    /// 2-4 s gap in live typing at every seam. Here the replacement starts EARLY, while the
    /// old request keeps running and keeps delivering to the consumer; `append` feeds both.
    /// The consumer sees nothing at overlap start — no `.listening`, nothing from the
    /// replacement — until the replacement proves itself with its first partial, at which
    /// point `promotePending` cuts ownership over and the old task is cancelled without a
    /// final (everything it heard was already delivered as partials, and the replacement
    /// heard the overlap audio too). If the replacement never partials, `overlapFallback`
    /// reverts to the old behaviour after `overlapFallbackSeconds`.
    private func beginOverlappedRotation(of session: Session) {
        guard let recognizer else { return }  // impossible after a successful start()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        lock.lock()
        guard isStarted, current === session, !session.isFinished, pending == nil else {
            lock.unlock()
            return
        }
        generation &+= 1
        // Deliberately does NOT touch `newestSessionGeneration` or `current`: the old
        // session remains the delivery owner, so its partials keep flowing and — should a
        // `stop()` land mid-overlap — its flush semantics are exactly the non-overlap ones.
        let replacement = Session(generation: generation, request: request)
        request.contextualStrings = contextualStrings
        pending = replacement
        let oldGeneration = session.generation
        lock.unlock()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Fires on an arbitrary Speech-owned thread. Never hop to the main actor here.
            self?.handle(session: replacement, result: result, error: error)
        }

        lock.lock()
        replacement.task = task
        let installed = (pending === replacement)
        lock.unlock()

        guard installed else {
            // `stop()` won the race while we were building. Discard immediately.
            task.cancel()
            return
        }

        Self.trace("overlap: replacement session \(replacement.generation) started "
            + "(old \(oldGeneration) still live)")

        armRotationTimer(for: replacement)

        queue.asyncAfter(deadline: .now() + Self.overlapFallbackSeconds) { [weak self] in
            self?.overlapFallback(old: session, replacement: replacement)
        }
    }

    /// No cutover within `overlapFallbackSeconds`: the replacement wedged from birth, or
    /// the user was silent through the whole overlap. Revert to the old hard rotation:
    /// flush the old request — it is STILL the delivery owner, so its flushed final
    /// delivers through the normal handler, whose utterance-boundary branch then promotes
    /// the replacement with the normal `.listening`. (An error from the flush promotes
    /// through the error path instead.) Pure silence can flush neither a final nor an
    /// error, so a bounded net forces the promotion rather than let the pipeline stall —
    /// today's hard rotation had no such net.
    private func overlapFallback(old: Session, replacement: Session) {
        lock.lock()
        let stillOverlapping = isStarted && current === old && pending === replacement
            && !old.isFinished
        lock.unlock()
        guard stillOverlapping else { return }

        Self.trace("overlap: no cutover after 6s; falling back to hard rotation")
        emitState(.unavailable(
            "rotating request after silent overlap (wedge prevention; measured wedge at ~35 s)"))
        old.request.endAudio()

        queue.asyncAfter(deadline: .now() + Self.finalFlushTimeoutSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stuck = self.isStarted && self.current === old && self.pending === replacement
            self.lock.unlock()
            guard stuck else { return }
            self.finish(old, deliverIdle: false)
            self.promotePending(replacement, traceMessage:
                "overlap: fallback flush produced nothing; promoting replacement session "
                + "\(replacement.generation)")
        }
    }

    /// Cut an overlapped rotation over: make the pending replacement the delivery owner
    /// and emit the ONE `.listening` boundary the consumer expects. The ownership switch —
    /// `current`, `pending`, and `newestSessionGeneration` together — is a single critical
    /// section; from that instant every event of the old session fails the emission-time
    /// staleness checks in `handle`. The old task (when one is still installed) is then
    /// cancelled WITHOUT a final: its partials were already delivered, and the replacement
    /// heard the overlap audio too. Returns false when the replacement is no longer
    /// promotable — `stop()` or a discard won the race — in which case nothing is emitted.
    @discardableResult
    private func promotePending(_ session: Session, traceMessage: String?) -> Bool {
        lock.lock(); discardRetries = 0; lock.unlock()
        lock.lock()
        guard isStarted, pending === session, !session.isFinished else {
            lock.unlock()
            return false
        }
        let old = current
        pending = nil
        current = session
        newestSessionGeneration = session.generation
        lock.unlock()

        if let old { finish(old, deliverIdle: false) }
        if let traceMessage { Self.trace(traceMessage) }
        emitState(.listening)
        return true
    }

    /// Result handler for a PENDING replacement (overlapped rotation, pre-cutover). The
    /// consumer must not hear from this session yet. Its first partial is the cutover
    /// trigger: promote, emit `.listening`, then deliver that very partial. A final or an
    /// error BEFORE any partial means the task is spent — a spent task never produces
    /// another result, so promoting it later would install a dead delivery owner. Retire it
    /// and schedule a fresh replacement attempt in 4 s (`rearmOverlapAfterDiscard`) -- the
    /// fallback guards on `pending === replacement` and so canNOT resolve a discarded
    /// overlap, and the owner's one-shot rotation timer is already spent; without the
    /// re-arm the owner would run unrotated into the ~35 s wedge under continuous speech.
    /// Nothing is lost by the discard itself: the old session heard the same audio and is
    /// still typing it.
    private func handlePendingResult(session: Session,
                                     result: SFSpeechRecognitionResult?,
                                     error: (any Error)?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if !result.isFinal {
                // ── CUTOVER ON FIRST PARTIAL ─────────────────────────────────────────
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                    &- session.createdAt.uptimeNanoseconds) / 1_000_000_000
                let promoted = promotePending(session, traceMessage:
                    "overlap: cutover to session \(session.generation) on first partial "
                    + "after \(String(format: "%.1f", elapsed))s")
                if promoted {
                    emitPartial(text)
                }
                return
            }
            lock.lock()
            let wasPending = (pending === session)
            if wasPending { pending = nil }
            lock.unlock()
            // Only finish a session we actually discarded. If a concurrent path already
            // promoted it to delivery owner, finishing it here would kill the freshly
            // promoted `current`, stranding `isStarted == true` with no session at all
            // (review finding; recovered only by the consumer's watchdog).
            if wasPending {
                finish(session, deliverIdle: false)
                Self.trace("overlap: replacement session \(session.generation) finalized "
                    + "before any partial (len \(text.count)); discarded — old session "
                    + "keeps delivering")
                lock.lock()
                let owner = current
                lock.unlock()
                if let owner { rearmOverlapAfterDiscard(owner: owner) }
            }
            return
        }

        // Bound rather than merely tested, so the error's identity can be traced below.
        // A pre-cutover replacement is never the delivery owner, so its errors reach
        // `consecutiveFailures` on no path at all — this is a silent discard by
        // construction, and under repeated overlap discards (the 4 s re-arm loop) it is a
        // steady source of exactly the every-~7 s errors seen at 15:25-15:26.
        guard let error else { return }
        lock.lock()
        let wasPending = (pending === session)
        if wasPending { pending = nil }
        lock.unlock()
        if wasPending {
            finish(session, deliverIdle: false)
            Self.trace("overlap: replacement session \(session.generation) errored before "
                + "cutover; old session keeps delivering; error not counted — "
                + Self.describeRecognizerError(error))
            lock.lock()
            let owner = current
            lock.unlock()
            if let owner { rearmOverlapAfterDiscard(owner: owner) }
        } else {
            // Lost the race: a concurrent promotion or discard emptied the slot between
            // `handle`'s read and ours. Rare, but it is still an error that reaches no
            // counter and no consumer, so it does not get to be invisible either.
            Self.trace("overlap: error from replacement session \(session.generation) "
                + "arrived after it left the pending slot; not counted — "
                + Self.describeRecognizerError(error))
        }
    }


    /// B1 fix (review finding): a replacement that dies before its first partial used to
    /// leave rotation permanently disarmed -- the owner's own one-shot timer was spent
    /// creating it, and the fallback guards on `pending === replacement`, so under
    /// continuous speech the owner sailed unrotated into the measured ~35 s wedge. Retry
    /// the overlap on a SHORT delay instead of a full 20 s cycle: the owner is already
    /// ~20+ s old when a discard happens, and 4 s keeps the next attempt comfortably
    /// inside the wedge window. Guarded at fire time: only if that session is still the
    /// delivery owner, still started, and no other replacement is pending.
    /// Consecutive discard-retry count; reset whenever any session is promoted or begun.
    /// Caps the retry loop at 3 so a THROTTLED Speech service (error 1107 — the exact
    /// condition repeated request churn causes) is not hammered every 4 s indefinitely;
    /// past the cap the consumer's watchdog owns recovery.
    private var discardRetries = 0

    private func rearmOverlapAfterDiscard(owner: Session) {
        lock.lock()
        discardRetries += 1
        let attempt = discardRetries
        lock.unlock()
        guard attempt <= 3 else {
            Self.trace("overlap: discard-retry cap reached (\(attempt - 1)); leaving recovery to the consumer watchdog")
            return
        }
        queue.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let wanted = self.isStarted && self.current === owner && self.pending == nil
            self.lock.unlock()
            guard wanted else { return }
            Self.trace("overlap: retrying replacement for session \(owner.generation) after discard")
            self.beginOverlappedRotation(of: owner)
        }
    }

    // MARK: - Callback dispatch

    // Each of these reads the closure under the lock and invokes it OUTSIDE the lock. Calling
    // consumer code while holding a lock is how you get a deadlock the first time a consumer
    // calls back into `setContextualStrings` from `onFinal`.

    private func emitPartial(_ text: String) {
        lock.lock(); let callback = _onPartial; lock.unlock()
        callback?(text)
    }

    private func emitFinal(_ text: String) {
        lock.lock(); let callback = _onFinal; lock.unlock()
        callback?(text)
    }

    private func emitState(_ state: State) {
        lock.lock(); let callback = _onState; lock.unlock()
        callback?(state)
    }

    // MARK: - Tracing

    /// Append one line to the same /tmp/mictest_trace.txt the rest of the app traces into,
    /// in the same format as main.swift's `trace()`. Deliberately duplicated rather than
    /// calling that helper, so this file keeps type-checking standalone and stays decoupled
    /// from files that are edited independently. Rules inherited from it: NEVER call this
    /// from the audio path (`append(_:)`) — it does synchronous file I/O — and never pass
    /// transcript text or a key; character counts only. Current call sites fire on Speech's
    /// callback thread or on `queue`, both safe for a small append, and only on lifecycle
    /// events — overlap-rotation milestones and stale-flush suppressions, a few lines per
    /// rotation at most, never per-partial.
    /// One-line identity of an error from the Speech service, for the trace and for
    /// `lastServiceErrorText`.
    ///
    /// `localizedDescription` alone is not enough to act on: the interesting distinctions
    /// live in the domain/code pair. `kAFAssistantErrorDomain 1107` (throttling — we caused
    /// it) demands backing off, while `1101` (no speech detected) is the recognizer working
    /// exactly as designed on a silent room, and the two are indistinguishable from their
    /// prose. The 15:25-15:26 trace could not tell them apart because it recorded neither.
    /// Contains no transcript text, so it is safe for the trace file.
    private static func describeRecognizerError(_ error: any Error) -> String {
        let ns = error as NSError
        return "[domain=\(ns.domain) code=\(ns.code)] \(ns.localizedDescription)"
    }

    private static func trace(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        // ── O_APPEND IS LOAD-BEARING — DO NOT "SIMPLIFY" THIS BACK ─────────────────────
        // This file has TWO concurrent writers and no shared state between them: these
        // calls run on Speech's arbitrary callback thread, while main.swift's recogniser
        // watchdog traces from the main actor at ~1 Hz through its own byte-equivalent
        // helper and its own file handle. The previous implementation opened the file,
        // called `seekToEndOfFile()`, then `write()` — two separate syscalls. Two writers
        // that both resolve end-of-file to offset N both then write AT N, and one line
        // silently overwrites the other. That collision is likeliest during an error
        // storm, when both writers are at their chattiest — so the lines most likely to
        // be lost were exactly the diagnostic lines this instrumentation exists to
        // capture, and the trace file was least trustworthy at the only moment it
        // mattered.
        //
        // With O_APPEND the kernel makes seek-to-end-and-write ONE atomic operation for a
        // regular file, which is precisely the guarantee the seek+write pair lacked. No
        // lock: an NSLock here would not help at all, because the racing writer lives in
        // another file with its own handle and would never take it.
        //
        // Failure stays silent, as before: a failed `open` returns without a line. The old
        // `else { try? data.write(to: url) }` fallback is deliberately NOT carried over.
        // The only case it legitimately served was "file does not exist yet", which
        // O_CREAT now covers directly; as a general fallback it is a hazard, because
        // `Data.write(to:)` REPLACES a file rather than appending to it — reinstating it
        // would risk losing the whole trace instead of one line. (Measured, so the record
        // is straight: when the handle open fails for permissions, that fallback fails
        // too and the existing file survives untouched. Removing it closes a hazard; it
        // is not the bug this rewrite fixes. That bug is the seek/write race above.)
        let fd = open("/tmp/mictest_trace.txt", O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle.write(data)
    }
}
