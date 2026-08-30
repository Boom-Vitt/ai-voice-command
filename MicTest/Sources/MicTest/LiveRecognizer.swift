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
//    * `append` does no file I/O, no `print`, no UI, no `MainActor.assumeIsolated` and no
//      allocation. It holds this class's lock for two pointer reads, then hands the buffer
//      to Speech and to `AudioReplayRing.write` — one more uncontended lock take and a
//      bounded memcpy of at most one tap buffer (~16 KB). That is the entire cost of the
//      replay mechanism on the render thread, and it is deliberately the only thing that
//      has ever been added to this path.
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
        /// recognition error we are recovering from, or — past `maxConsecutiveFailures` —
        /// the `persistent recognition failure` report the consumer's watchdog matches on
        /// to escalate to a full capture restart. Effectively never a give-up: while
        /// `isStarted`, every emission of this case has another attempt scheduled behind
        /// it. The one exception is `restart`'s catch, which reports "restart failed" and
        /// schedules nothing — reachable only if `recognizer` were nil, which cannot happen
        /// after a successful `start()`.
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
    /// every request young enough that the wedge window is never reached. The 20 s cadence
    /// is unchanged and load-bearing. During normal pause-punctuated speech this watchdog
    /// rarely fires (natural pauses finalise long before 20 s).
    ///
    /// ── HOW THE SEAM IS CROSSED: FLUSH, THEN REPLAY (see `beginFlushRotation`) ─────────
    /// Rotation used to be OVERLAPPED: a replacement request was created while the old one
    /// kept running, on the theory that the consumer would only see the boundary once the
    /// replacement produced its first partial. Measured 21 of 21 rotations: the overlap
    /// never overlapped. Creating the second request killed the first — the owner died with
    /// kAFAssistantErrorDomain 1110 or a final in the SAME second — so the replacement heard
    /// audio only from its own creation instant, and the owner was cancelled WITHOUT
    /// `endAudio()`. Everything it had heard since its last emitted partial was therefore
    /// transcribed by nobody: an app-independent hole in the typed text at every 20 s of
    /// continuous speech, which is precisely the "words get cut everywhere" report.
    ///
    /// Now the owner is FLUSHED (`endAudio()`), and the successor is handed the audio that
    /// arrived after the flush, replayed out of `AudioReplayRing`. The two halves meet
    /// sample-exactly: the flushed final covers `[start, t0]`, the replay covers
    /// `[t0, now]`, where `t0` is one value of the ring's monotonic sample counter recorded
    /// in the same critical section that stops feeding the old request.
    ///
    /// What that restores, beyond the missing words: FINALS. One per seam. The old rotation
    /// cancelled without a final, so a long dictation produced none at all, which is why
    /// the consumer's reconciliation had to be rebuilt around re-anchoring partials.
    ///
    /// Cost at the seam: the successor's first partial now arrives ~0.5-1 s later than the
    /// old (illusory) cutover, because it has to hear the replayed window first. That is
    /// latency, not loss, and the old cutover's "seamlessness" was measured to be a gap.
    ///
    /// ── WEDGE MARGIN IS NOW MEASURED IN AUDIO CONSUMED, NOT WALL CLOCK ────────────────
    /// A successor is born having already swallowed the replay window, so when its own
    /// rotation timer fires at 20 s of wall clock it has consumed 20 s + the window. An
    /// ordinary seam gives ~20.5-22 s; the worst chain this app can build — an 8 s error
    /// backoff — gives ~28 s. Still inside the measured ~35 s wedge, but that is the
    /// tightest case in the design, and it is why the ring is 12 s and not larger.
    private static let sessionRotationSeconds: Double = 20

    /// How long to wait for a flushed final before giving up and retiring the request:
    /// after a deliberate `stop()` (bounded so `stop()` can never leak a live task), and
    /// after a rotation flush (bounded so a silent flush — which answers with neither a
    /// final nor an error — cannot leave the capture sitting on a request that will never
    /// speak again).
    private static let finalFlushTimeoutSeconds: Double = 2.0

    /// Restart backoff after a recognition error. Speech throttles aggressive clients
    /// (kAFAssistantErrorDomain 1101/1107 and friends), and a tight restart loop is exactly
    /// what triggers it, so failures back off exponentially from here.
    private static let restartBaseDelaySeconds: Double = 0.3
    private static let restartMaxDelaySeconds: Double = 8.0

    /// The point at which repeated failures stop being routine. A REPORTING threshold, not
    /// a kill switch: past it the recognizer keeps retrying at the capped backoff above and
    /// only the tone of the emitted `.unavailable(...)` changes — from "recognition error
    /// (retry N …)", which the consumer treats as plumbing, to the
    /// `persistent recognition failure` line its watchdog escalates on.
    ///
    /// It used to be a terminal give-up: past the cap this file cleared `isStarted`, dropped
    /// `current`, and never tried again. Trace 14:26-14:29 is why that is gone. Seven
    /// consecutive rotation seams — an outgoing owner erroring with kAFAssistantErrorDomain
    /// 1110 in the same second its warm replacement was promoted, at :19, :39, 14:28:00,
    /// :20, :40, 14:29:00, :20 — tripped it while recovery was succeeding every single time.
    /// The warm-replacement machinery that produced those seams is gone, but the SEAM is
    /// not: a rotation now flushes the owner, and a flush of near-silence answers with 1110
    /// rather than a final. Such an error must still never reach this counter — the error
    /// path recognises it by the session's own flush mark instead of by a pending slot.
    /// The app then held a hot microphone for the remaining twelve minutes of a 906 s
    /// capture and typed nothing: nothing in this file retries after the give-up, and
    /// `append` silently discards every buffer once `current` is nil. Raising this constant
    /// would only have moved that death from 2.5 min to 4 min.
    private static let maxConsecutiveFailures = 6

    // MARK: - Instrumentation

    /// ── THE SEAM PROBE GRADUATED INTO THE MECHANISM ──────────────────────────────────
    /// A one-shot, env-gated probe (`MICTEST_FLUSH_SEAM=1`) used to convert the first
    /// rotation of a run into an `endAudio()` flush purely to measure two numbers: how many
    /// characters the flushed final adds beyond the last partial (what the seam was losing)
    /// and how long the flush takes (what fixing it would cost in latency). Both numbers
    /// are now taken at EVERY seam, because every rotation is a flush — the probe's
    /// measurement is the mechanism's routine trace line (`rotation: flushed final …
    /// +N chars beyond last partial`). The env gate, the per-run arming flag and the
    /// parallel probe rotation are gone with it; nothing about the measurement is.
    ///
    /// Minimum spacing between `partial-lag:` lines. Partials arrive many times per second
    /// and `trace` does synchronous file I/O, so this line is a SAMPLER, not a log: at 1 Hz
    /// it costs one `open`/`write` per second on a thread that is already doing Speech's
    /// work, and the quantity it reports (how far the transcription trails the audio) moves
    /// far too slowly for a higher rate to say anything new.
    private static let partialLagTraceIntervalNanos: UInt64 = 1_000_000_000

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
        /// When the session was created. Trace timing only — the `wall` figure of the
        /// `partial-lag:` line, i.e. how long this request has been alive.
        let createdAt = DispatchTime.now()
        /// Set immediately after `recognitionTask` returns. Only touched under the owner lock.
        var task: SFSpeechRecognitionTask?
        /// Deliberate `stop()`: drain one last final, suppress partials, do not auto-restart.
        var isStopping = false
        /// Fully done — final delivered, or torn down. Guards against double teardown.
        var isFinished = false

        /// ── FLUSH-ROTATION STATE — touched ONLY under `lock`, like `task` ────────────
        /// Character count of the last partial this session delivered as the owner. The
        /// baseline the seam line measures the flushed final against: `final -
        /// lastPartialLength` is exactly the text the OLD rotation threw away, and now the
        /// text this seam recovered. Maintained on every owner partial (one `String.count`
        /// per partial, on Speech's callback thread, outside the lock).
        ///
        /// GRAPHEME CLUSTERS, like every other `len …` figure in this file. For Thai that is
        /// a long way from a UTF-16 length and even further from a sample count: it answers
        /// "how many characters did the seam recover", never "how much audio". Do not size a
        /// replay window or an AX range off it — the window is counted in samples by
        /// `AudioReplayRing`, which is the only honest clock for that job.
        var lastPartialLength = 0
        /// When `beginFlushRotation` sent `endAudio()` on this session. Non-nil is also the
        /// flag "this session is mid-flush" — one field rather than two, so the timestamp
        /// and the flushing-ness can never disagree. `append` stops feeding this session's
        /// request the instant this is set, which is what makes the handover sample-exact.
        var flushStartedAt: DispatchTime?
        /// Whether this flush's single outcome line has been claimed. A flush has three
        /// racing reporters — the flushed final in `handle`, the error path when the flush
        /// answers 1110 instead, and the 2 s net in `beginFlushRotation` — and exactly one
        /// of them must speak. A flush that reports nothing reads in the trace as a seam
        /// that lost nothing, which is the exact ambiguity this file exists to remove.
        var flushOutcomeReported = false

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
    /// `current` slot plus the per-session flags, not by comparing against this counter — a
    /// draining session that `stop()` still owes one final is stale by generation and alive
    /// by flag.
    private var generation = 0
    /// Generation of the DELIVERY OWNER — the session whose partials/finals/idles the
    /// consumer is currently receiving. Advances when `beginSession` installs a session,
    /// which is now the ONLY way delivery changes hands: a rotation flushes the owner and
    /// its successor is built by `beginSession` like any other restart. Every emission-time
    /// staleness check compares against this: a mismatch means a newer session already owns
    /// delivery — its `.listening` has already reset the consumer's typed high-water mark —
    /// so the stale event must be suppressed rather than typed into the successor's
    /// utterance.
    private var newestSessionGeneration = 0
    /// The delivery owner. `append` feeds it (unless it is mid-flush); its events reach the
    /// consumer, subject to the emission-time staleness checks. There is never a second
    /// live session: the overlapped-rotation `pending` slot is gone, because measured 21/21
    /// the overlap never overlapped — creating the second request killed the first.
    private var current: Session?
    private var isStarted = false
    private var contextualStrings: [String] = []
    /// Consecutive restart failures. Reset by a successful RESULT and by nothing else. The
    /// second reset that used to live in `promotePending` is deliberately NOT relocated into
    /// `beginSession`: every backoff restart goes through `beginSession`, so resetting there
    /// would make `persistent recognition failure` unreachable and silently break the
    /// escalation contract main.swift's watchdog depends on. A flush that yields a final IS
    /// a successful result, so a healthy seam still clears the counter on its own.
    private var consecutiveFailures = 0

    /// ── REPLAY STATE (flush-then-replay rotation, and error-backoff recovery) ─────────
    /// The rolling window of the tap's own audio. Written on the audio thread by `append`,
    /// read on `queue` by `beginSession`. See `AudioReplayRing` for the isolation rules and
    /// for why the lock order is always (this lock → the ring's lock).
    private let replayRing = AudioReplayRing()
    /// The tap's format, captured from the first buffer `append` ever sees.
    ///
    /// ── WHY THE RING BOOTSTRAPS FROM A BUFFER INSTEAD OF FROM `start()` ──────────────
    /// The ring must be allocated for the exact format the tap produces, and it must be
    /// allocated OFF the audio thread. The consumer (main.swift) knows that format — it
    /// reads it from the input node — but `start()`'s signature is its call site's, and this
    /// slice is not allowed to touch that file, so the format cannot arrive as an argument
    /// this round. Adding a `prepareReplay(format:)` the consumer never calls would be worse
    /// than useless, and allocating lazily inside `append` is forbidden outright.
    ///
    /// So `append` captures `buffer.format` — a property read, no allocation, exactly once
    /// per capture — and the first off-audio-thread caller to notice a captured-but-
    /// unprepared ring hops to `queue` and allocates there. The honest cost: the first
    /// instants of a capture have no replay coverage. That is irrelevant, because replay
    /// only matters at seams and backoffs, and the earliest of those is 20 s in.
    private var capturedTapFormat: AVAudioFormat?
    /// Set once the ring's preparation has been handed to `queue`, so the several callbacks
    /// that all notice "format captured, ring not prepared" at the same instant schedule it
    /// once. Cleared by `start()`, so a capture that comes up on a different input device
    /// re-prepares.
    private var replayRingPrepareScheduled = false
    /// The open replay window's start, as a value of `AudioReplayRing.totalSamplesWritten`,
    /// or nil when no audio is owed to a successor. Recorded when a rotation flush stops
    /// feeding the owner and when a counted error retires it; consumed by
    /// `beginSession(isRestart:)`, which feeds `[here, now]` into the new request before
    /// installing it.
    ///
    /// FIRST WRITE WINS while the slot is open: a backoff run can chain several failures
    /// (0.3 s → 8 s) and the window must span the WHOLE chain, not restart at the last
    /// failure. The 12 s ring outlives an 8 s chain; a chain that outlives the ring is
    /// reported as truncation rather than silently shortened.
    private var pendingReplayFrom: UInt64?

    /// ── PHASE 0 INSTRUMENTATION STATE ────────────────────────────────────────────────
    /// `uptimeNanoseconds` of the last `partial-lag:` line, or nil if the CURRENT SESSION
    /// has not written one yet. Nil rather than 0 on purpose: 0 is a real (if brief)
    /// uptime, and `now - 0 >= 1 s` is false for the first second after a boot, which would
    /// silently swallow the first line of a run that starts then.
    ///
    /// ── PER SESSION, NOT PER RUN: THE FIRST LINE IS THE PAYLOAD ─────────────────────
    /// Reset in `beginSession`'s install critical section, as well as in `start()`, so the
    /// first admitted partial of every session always traces. That is load-bearing, not
    /// politeness about sampler fairness: a successor's FIRST line is the only place the
    /// replay verdict appears. It is where a `covered` that already spans the replayed
    /// window is read against a `wall` of nearly zero, which is what answers whether the
    /// pre-task appends were retained at all (the assumption named in `beginSession`).
    /// As a purely global 1 Hz sampler that exact line was the one most likely to be
    /// suppressed: at 2-4 partials/s the predecessor has almost always printed within the
    /// previous second, and a seam is precisely when partials are flowing. Nothing else is
    /// lost by the reset — the quantity moves far too slowly for the extra line to repeat
    /// anything.
    private var lastPartialLagTraceAt: UInt64?

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
        // Reset so the first partial of every run is always sampled, even when the previous
        // run ended less than a second ago.
        lastPartialLagTraceAt = nil
        // No successor of this capture is owed audio from the last one. Cleared here rather
        // than only in `stop()` so that an abnormal end (a consumer that dropped us mid
        // capture) cannot leak a window across the gap either.
        pendingReplayFrom = nil
        // Re-captured per capture: the input DEVICE can change between holds of the key, and
        // a ring prepared for the old device's format would reject every buffer.
        capturedTapFormat = nil
        replayRingPrepareScheduled = false
        lock.unlock()
        // Drop the previous capture's audio but keep the allocation (and the monotonic
        // sample counter — see `AudioReplayRing.totalSamplesWritten`). Same-format
        // preparation is then a no-op, so a second capture arms the ring without allocating.
        replayRing.reset()

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
    /// Any open replay window dies here too: it exists to be handed to a SUCCESSOR, and a
    /// deliberate stop has none. The flush semantics below are untouched by the rotation
    /// rework — this is still the one path that delivers a final and then goes idle.
    func stop() {
        lock.lock()
        pendingReplayFrom = nil
        guard isStarted, let session = current else {
            isStarted = false
            current = nil
            generation &+= 1
            lock.unlock()
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
    /// One lock acquisition, two pointer reads, unlock — then `append` outside the critical
    /// section. `SFSpeechAudioBufferRecognitionRequest.append(_:)` is safe to call from the
    /// audio thread; it hands the buffer to Speech's own queue. Nothing here allocates.
    ///
    /// A nil request means the owner is between sessions (stopped, mid auto-restart) or
    /// mid-flush. Audio that reaches no request is NOT dropped any more — that was the bug:
    /// it still lands in `replayRing`, and the successor is fed it before it goes live.
    ///
    /// ── THE RING WRITE IS PART OF THE REALTIME BUDGET, AND SAYS SO ────────────────────
    /// `replayRing.write` is one uncontended lock take plus a memcpy of at most one tap
    /// buffer (1024 frames × 4 bytes × channels ≈ 16 KB). No allocation, no I/O, no tracing
    /// — see `AudioReplayRing`'s header, which inherits this file's isolation rule verbatim.
    /// It is the ONLY thing that has been added to this path, and nothing else may be.
    ///
    /// ── ORDER IS LOAD-BEARING: FLAG READ, THEN FEED, THEN RING ───────────────────────
    /// A rotation flush decides the seam by setting `flushStartedAt` and reading the ring's
    /// sample counter in ONE critical section (`beginFlushRotation`). Given that, and given
    /// that the ring write happens strictly AFTER the flag read here:
    ///
    ///   * a buffer that saw the flag set (so it is NOT in the flushed final) always lands
    ///     in the ring after the seam mark, so it is always replayed — a gap is impossible;
    ///   * a buffer that saw the flag clear (so it IS in the flushed final) may still be
    ///     racing toward the ring when the mark is read, in which case it is replayed too.
    ///
    /// Worst case is therefore ONE tap buffer — ~21 ms, a fraction of a phoneme — heard by
    /// both sides of the seam, and never a millisecond heard by neither. That asymmetry is
    /// the deliberate one: this whole change exists because the old seam dropped audio.
    /// Moving the ring write above `request?.append` reverses it into a possible gap. Don't.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let session = current
        // Same single critical section as before, now answering two questions instead of
        // one: who owns delivery, and has its request already been flushed. A flushing
        // session's request is not to be appended to after `endAudio()` — that is what makes
        // the final's coverage end exactly where the replay window begins. Not an absolute:
        // the flag is read here and acted on after the unlock, which leaves the one narrow
        // window named at the `append` call below.
        let request = (session?.flushStartedAt == nil) ? session?.request : nil
        let needsFormatCapture = (capturedTapFormat == nil)
        lock.unlock()

        // ── THE APPEND-AFTER-`endAudio()` WINDOW, NAMED AND ACCEPTED ─────────────────
        // The flush flag was read above under the lock; the lock is released before this
        // line. This thread can be preempted in between, `beginFlushRotation` can set
        // `flushStartedAt` and send `endAudio()`, and this call then appends to a request
        // that has already been ended. That is undocumented API use, and it stays:
        //
        //   * No audio is lost either way. Such a buffer reaches the ring on the next line,
        //     which is after the seam mark the flush recorded in that same critical section,
        //     so the successor is replayed it. Speech either ignores an append past
        //     `endAudio()` or absorbs it into the flush — under both, the sample is covered
        //     exactly once by the ring, and at worst twice across the seam (see the order
        //     argument above, which already accepts one duplicated tap buffer).
        //   * Closing it would mean holding the lock ACROSS `request.append` — a Speech call
        //     inside the critical section the realtime thread shares with `queue` — which
        //     this file's isolation rule forbids outright.
        //
        // Bounded to the buffers in flight at the instant of one flush, i.e. at most one tap
        // buffer per audio thread, ~21 ms.
        request?.append(buffer)
        replayRing.write(buffer)

        // Once per capture, and a plain property read when it does happen. Kept last so the
        // steady state is one predictable branch. See `capturedTapFormat` for why the format
        // is bootstrapped from a buffer at all.
        if needsFormatCapture {
            let format = buffer.format
            lock.lock()
            if capturedTapFormat == nil { capturedTapFormat = format }
            lock.unlock()
        }
    }

    // MARK: - Contextual biasing

    /// Bias recognition toward these terms — command verbs, branch names, project nouns.
    /// Applied to the live request immediately as well as stored for every future session,
    /// so the caller can update the vocabulary mid-dictation without restarting.
    func setContextualStrings(_ terms: [String]) {
        lock.lock()
        contextualStrings = terms
        let request = current?.request
        lock.unlock()
        request?.contextualStrings = terms
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
    /// - Parameter isRestart: `true` for every transparent restart — utterance boundary,
    ///   error recovery, and now the rotation seam as well, which no longer builds its own
    ///   replacement. A restart must not throw into the caller — there is no caller — so
    ///   failures are reported through `onState` and retried with backoff.
    ///
    /// This is also where an open replay window is consumed: whatever the predecessor could
    /// not transcribe is fed into the fresh request BEFORE it is installed, so it hears the
    /// seam in order and the consumer's first partial already accounts for it.
    private func beginSession(isRestart: Bool) throws {
        guard let recognizer else {
            throw RecognizerError.localeUnsupported(
                "no SFSpeechRecognizer for \(Self.localeIdentifier)")
        }
        // Cheap and idempotent. On a restart this runs on `queue`, which is exactly where
        // the ring's allocation belongs; at first start the format has not been captured yet
        // and this is a no-op (see `capturedTapFormat`).
        prepareReplayRingIfNeeded()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // The entire justification for this file. Off-device would reintroduce network
        // latency and ship the user's microphone to a server.
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        // ── REPLAY BEFORE INSTALL ─────────────────────────────────────────────────────
        // Read, but deliberately NOT cleared, here: the slot is cleared in the same critical
        // section that installs the session below. If this function returns early after the
        // replay — a `stop()` racing us — the window must survive, or the audio just fed
        // into a request that is about to be discarded would be lost for good.
        //
        // The feed happens while no session is installed, so `append` cannot interleave live
        // audio into this request mid-replay; the ring's chase loop converges against a
        // writer that is only filling the ring, not the request.
        //
        // ── THE ONE ASSUMPTION THIS MECHANISM RESTS ON, NAMED SO IT CAN BE CHECKED ────
        // Audio is appended to the request BEFORE `recognitionTask(with:)` is called below,
        // i.e. the request is assumed to hold what it is given until its task starts
        // draining it. That is not something the type checker can settle, and if it is
        // false the replay is a silent no-op that still traces `replay: fed 1.8s` — the
        // worst kind of failure, which is why it is written down here rather than assumed.
        //
        // The discriminator is already in the trace: at the first seam, compare the
        // `replay: fed Xs` line with the successor's first `partial-lag:` line. If the
        // pre-task audio is retained, `covered=` starts high — roughly the window — because
        // the request really did hear it. If `covered=` starts near zero, it did not, and
        // the fix is to move `recognitionTask` above the replay and accept that partials
        // arriving before the install are dropped by the alive check (cheap: partials are
        // cumulative, so the first one after the install still carries the window's text).
        //
        // Do NOT "pre-emptively" reorder without that evidence. Creating the task first
        // opens a real hazard in exchange for an imagined one: a window that ends in silence
        // can make Speech finalise before the install, and a final delivered to a
        // not-yet-installed session is discarded as a ghost — leaving a spent task installed
        // as the delivery owner, silent until the next rotation.
        lock.lock()
        let replayFrom = pendingReplayFrom
        lock.unlock()
        var replayReport: AudioReplayRing.ReplayReport?
        if let replayFrom {
            replayReport = replayRing.replay(from: replayFrom, into: request)
        }
        if let replayReport, let replayFrom {
            Self.trace("replay: fed \(String(format: "%.1f", replayReport.seconds))s "
                + "(\(replayReport.buffers) buffers) from sample \(replayFrom); residual "
                + "\(String(format: "%.0f", replayReport.residualMilliseconds)) ms dropped")
            if replayReport.truncatedSeconds > 0 {
                Self.trace("replay: window outlived the "
                    + "\(String(format: "%.0f", AudioReplayRing.capacitySeconds)) s ring — "
                    + "\(String(format: "%.1f", replayReport.truncatedSeconds))s of its "
                    + "oldest audio was evicted before a request could hear it")
            }
            if let note = replayReport.note {
                Self.trace("replay: \(note)")
            }
        }

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
        // Retire the window HERE, not at the read above, and only if it is still the one we
        // replayed: a fresh mark recorded while we were replaying (a late error from the
        // predecessor) belongs to the NEXT successor and must not be swallowed.
        if pendingReplayFrom == replayFrom { pendingReplayFrom = nil }
        // Per SESSION, not per run: the sampler restarts here so the first admitted partial
        // of every session always writes its line. That first line is the diagnostic
        // payload, not a formality — see `lastPartialLagTraceAt`. Done in this critical
        // section, after the `isStarted` guard above, so an install that aborts cannot
        // clobber the live session's sampler.
        lastPartialLagTraceAt = nil
        lock.unlock()

        // ── THE BOUNDARY IS ANNOUNCED BEFORE THE TASK EXISTS — DELIBERATE ────────────
        // `.listening` is what resets the consumer's typed high-water mark, i.e. the ledger
        // every partial is diffed against. It is emitted HERE, between the install and
        // `recognitionTask(with:)`, so that no partial of this session can reach the
        // consumer ahead of it: before the task exists there is nothing to deliver one.
        //
        // It used to be emitted at the END of this function, after the task was created and
        // the rotation timer armed. That left a window — task alive, `.listening` not yet
        // posted — in which a first partial passed both the alive check and the ownership
        // check and landed on the consumer while the PREDECESSOR's ledger was still
        // installed. Diffed against that ledger the successor's text shares almost no
        // prefix, so the consumer sees whole-ledger divergence and can re-type the entire
        // window. The window was always there; the replay above made it REACHABLE, because
        // the request is now pre-fed 0.5-2 s of audio before its task exists, so Speech
        // starts with a backlog and can answer almost immediately. Emitting first makes the
        // ordering structural instead of a race the successor merely usually loses.
        //
        // Not any earlier either: `newestSessionGeneration` moves in the critical section
        // just above, and it is what makes a predecessor's in-flight partial fail the
        // ownership re-read in `handle`. Emitting before the install would reopen the same
        // hazard from the other side — a stale partial landing after the new `.listening`.
        //
        // A `stop()` that lands after the emit and before the `installed` re-check below is
        // harmless: the consumer sees `.listening` then `.idle`, in that order, through the
        // same FIFO event box, and no partial can sit between them because the task is
        // cancelled below before it has an owner to deliver to. A `stop()` that lands during
        // the trace write on the next line can still invert the pair — `emitState` runs the
        // callback outside the lock, so nothing orders its `.idle` against the `.listening`
        // this thread has not posted yet, and the consumer is briefly told it is listening
        // with no task behind it. That exposure is one synchronous file write wide, is
        // unchanged by this move (the emit previously sat after the same trace call, just
        // further down), and is deliberately not closed here: re-reading `isStarted` to gate
        // the emit would make the boundary conditional again, which is the exact property
        // this ordering exists to remove.
        //
        // Rotation accounting is only readable if every generation that takes over delivery
        // says so — the seams of the 14:26-14:29 run had to be reconstructed by inference
        // because this path traced nothing. Every handover now comes through here, so this
        // one line plus the `rotation:`/`replay:` lines above it are the complete record of
        // a seam. Lifecycle-rate, a couple of lines per rotation cycle at most, and never on
        // the audio path: `beginSession` runs on the caller's thread or on `queue`, both
        // safe for a small append — and it is outside the lock, which its file I/O requires.
        Self.trace("session: generation \(session.generation) installed as delivery owner "
            + "(\(isRestart ? "restart" : "first start"))")
        emitState(.listening)

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
        // A stopping session is stale by generation but is still owed exactly one final.
        let isDraining = session.isStopping && !session.isFinished
        if result != nil && error == nil {
            consecutiveFailures = 0
        }
        // Every Speech callback in this file routes through here — `beginSession` installs
        // the only result closure there is — so this is the one choke point that sees EVERY
        // error, before any staleness guard downstream gets a chance to swallow it. Recorded
        // unconditionally, ahead of the alive-, stopping- and ownership-checks below,
        // precisely because those are the guards that made the 15:25-15:26 errors invisible.
        // Observation only: nothing downstream reads these fields, so no dispatch decision
        // changes.
        if let serviceError {
            lastServiceErrorAt = serviceError.at
            lastServiceErrorText = serviceError.text
        }
        // The ring is armed from the first callback that finds a captured format, which in
        // practice is the first partial of a capture — a second or two of speech in, and
        // ~19 s before the earliest seam that could need it. Read in THIS critical section
        // rather than its own, so the hot partial path pays nothing for it.
        let scheduleRingPrepare = !replayRingPrepareScheduled && capturedTapFormat != nil
        lock.unlock()

        if scheduleRingPrepare {
            // Hopped to `queue`: this is Speech's callback thread and the ring's allocation
            // is 2.3 MB per channel. `prepareReplayRingIfNeeded` re-reads the flag under the
            // lock, so the handful of callbacks that can notice this at once cost one
            // preparation between them.
            queue.async { [weak self] in self?.prepareReplayRingIfNeeded() }
        }

        // Ghost from a cancelled task. Drop it before it can write into the new session.
        // Liveness is identity: a finished session is never left installed in `current`
        // (every teardown clears the slot in the same critical section), so `current ===
        // session` is authoritative.
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
                // ── CLAIM THE SEAM'S ONE OUTCOME LINE ────────────────────────────────
                // Read and claimed in the SAME critical section that reads staleness, so
                // this final, the error path and the 2 s net in `beginFlushRotation` can
                // never both report the same flush. Nil here means "this session was not
                // mid-flush" — an ordinary utterance-boundary final, the common case.
                let flushStartedAt = session.flushOutcomeReported ? nil : session.flushStartedAt
                if flushStartedAt != nil { session.flushOutcomeReported = true }
                let flushBaseline = session.lastPartialLength
                lock.unlock()

                // Emitted before the delivery/suppression fork below, because it measures
                // the FLUSH, not the delivery: whether this final then lands in the user's
                // document or is suppressed as stale, the `+chars` figure is exactly what
                // the old cancel-without-endAudio rotation dropped on the floor at this
                // seam, and what this one recovered. (The suppression lines below report the
                // delivery half.) Once env-gated as a probe; now every seam is measured,
                // because every seam is a flush.
                if let flushStartedAt {
                    let ms = Double(DispatchTime.now().uptimeNanoseconds
                        &- flushStartedAt.uptimeNanoseconds) / 1_000_000
                    let gained = max(0, text.count - flushBaseline)
                    // A baseline of 0 means the flushed session delivered no partial at all
                    // (silence, or a wedge) — then `gained` is the whole final, which is NOT
                    // seam recovery and must never be averaged in with the real numbers.
                    let baselineNote = flushBaseline == 0 ? " [no partial yet — not seam loss]" : ""
                    Self.trace("rotation: flushed final after "
                        + "\(String(format: "%.0f", ms)) ms, "
                        + "+\(gained) chars beyond last partial "
                        + "(final \(text.count) vs last partial \(flushBaseline))"
                        + baselineNote)
                }

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
                    // The same re-read protects the non-stopping path: a flush that took
                    // longer than the 2 s net gets its successor stood up ahead of it, and
                    // that successor's `.listening` has already reset the consumer's
                    // high-water mark, so this final can no longer be typed.
                    //
                    // What that costs, stated honestly: the successor's replay window opens
                    // at the flush instant `t0`, so it re-hears `[t0, now]` but NOT
                    // `[last partial, t0]` — the span only this final covered. On this path
                    // that span is lost. It is the rare path (a flush that misses a 2 s
                    // deadline) and it is the same span the flush-error path loses; closing
                    // it would mean marking a ring sample at every emitted partial, which is
                    // a follow-up, not this change.
                    guard !superseded else {
                        Self.trace("recognizer: suppressed stale final (len \(text.count)) "
                            + "— a newer session already owns delivery (the flush outran its "
                            + "2 s net); its audio after the flush is covered by the replay "
                            + "window" + coArrivingError)
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
                    // ── UTTERANCE BOUNDARY (AND ROTATION SEAM): STAND UP A SUCCESSOR ────
                    // SFSpeechRecognizer finalises after a pause and then goes permanently
                    // quiet: the task is done and no further audio is ever recognised. For
                    // continuous dictation that would mean the user has to re-press the key
                    // after every sentence. So on every non-deliberate final we stand up a
                    // successor — one path now, for both the natural pause and the 20 s
                    // rotation flush, because a flush produces an ordinary final and lands
                    // right here. From the consumer's point of view nothing happened except
                    // another `onFinal` followed by `.listening`.
                    //
                    // ── THE ORDERING main.swift DEPENDS ON, ASSERTED HERE ──────────────
                    // Two halves, and `.listening` must land strictly between them: after
                    // this final, and before the successor's first partial.
                    //
                    // FINAL then `.listening` — inherent. `emitFinal` above posts to the
                    // consumer's event box on THIS (Speech's) thread, before `restart`
                    // submits anything to `queue`; `.listening` is emitted from inside that
                    // queue block. The box is FIFO, so the consumer always types the final
                    // via `deliver(isFinal: true)` BEFORE `.listening` resets its typed
                    // high-water mark. That is what makes the seam's recovered text land in
                    // the document instead of being reset away.
                    //
                    // `.listening` then the successor's FIRST PARTIAL — structural, but only
                    // since the emit was moved. It is now issued between the install and
                    // `recognitionTask(with:)` in `beginSession`, so at the instant the
                    // consumer sees the boundary the successor has no task and therefore no
                    // way to have produced a partial. While `.listening` was emitted at the
                    // end of `beginSession` this half was merely probable, and the replay
                    // made it fail: a request pre-fed 0.5-2 s of audio can answer as soon as
                    // its task starts, and a first partial that overtook `.listening` was
                    // diffed against the PREDECESSOR's ledger — near-zero common prefix,
                    // whole-ledger divergence, worst case the whole window typed twice.
                    //
                    // Together they are why replayed audio does not duplicate: the ledger
                    // reset at `main.swift:2709-2718` happens between the final and the
                    // successor's first partial, and the successor only ever re-speaks audio
                    // the final did not cover.
                    //
                    // An ordinary pause boundary records no replay window on purpose: Speech
                    // finalises on detected silence, so the audio dropped during this hop is
                    // that silence. Only a FLUSH (`beginFlushRotation`) and a counted error
                    // open a window, because only they cut a request off mid-speech.
                    //
                    // Hopped to the session queue rather than done inline: we are currently
                    // inside the OLD task's callback frame, and creating its successor from
                    // there invites re-entrancy against a concurrent `stop()`.
                    restart(after: 0, reason: nil)
                }
            } else if !session.isStopping {
                // Partials from a stopping session are suppressed — see `stop()`. The
                // ownership re-read mirrors the stale-final guard: a partial that passed the
                // alive check a moment before a successor was installed must not land after
                // that successor's `.listening` has reset the consumer's high-water mark.
                //
                // Sampled BEFORE the lock and reused for both the admission decision and
                // the `wall` figure below, so the two can never disagree by a scheduling
                // hiccup. `uptimeNanoseconds` is a `mach_absolute_time` read — cheaper than
                // the lock acquisition that follows it, and safe to take anywhere.
                let nowNanos = DispatchTime.now().uptimeNanoseconds
                // Counted outside the lock (`String.count` walks grapheme clusters, which is
                // not work to do inside a critical section the audio thread contends for)
                // and now unconditionally, where the probe once made it opt-in: every
                // rotation is a flush, so every session's last partial is the baseline its
                // seam line will be measured against. One grapheme walk per partial, on
                // Speech's callback thread, against a string Speech itself just built.
                let partialLength = text.count
                lock.lock()
                let owner = (newestSessionGeneration == session.generation)
                // One critical section for all three owner-scoped reads and writes — the
                // ownership re-read, the ≥1 s admission decision for the lag line, and the
                // seam baseline — rather than three lock takes per partial.
                var admitLagTrace = false
                if owner {
                    // Admitted when nothing has been written yet in this run, or the last
                    // line is at least a second old. A suppressed partial formats nothing
                    // and does not so much as touch `segments` — the same discipline as the
                    // co-arriving-error block below, where both message variants live
                    // inside the `if let` on purpose.
                    admitLagTrace = lastPartialLagTraceAt.map {
                        nowNanos &- $0 >= Self.partialLagTraceIntervalNanos
                    } ?? true
                    if admitLagTrace { lastPartialLagTraceAt = nowNanos }
                    session.lastPartialLength = partialLength
                }
                lock.unlock()
                // Hot path: `error` is nil for effectively every partial, and then this is
                // one optional test and nothing else — no Date, no interpolation, no
                // allocation. Both message variants live INSIDE the binding on purpose.
                if let error {
                    traceCoArrivingError(error, owner
                        ? "a delivered partial (len \(text.count))"
                        : "a partial dropped by the ownership re-read (len \(text.count))")
                }
                // ── HOW FAR BEHIND THE MICROPHONE THE TYPED TEXT IS ───────────────────
                // `covered` is the end of the last segment Speech has committed to — i.e.
                // how much of the audio this transcription actually accounts for — and
                // `wall` is how long the session has been alive. Their difference is the
                // recognizer's own lag: audio it has swallowed but not yet spoken for.
                //
                // It sized the replay ring, and it still earns its place after the ring
                // exists, for two reasons. It is the only view of a request going QUIET
                // while audio keeps flowing — a growing `lag` with no partials is the
                // signature of the ~35 s wedge the rotation cadence exists to dodge — and it
                // is the number that says how much the flush at each seam still has to
                // finalise, which is what the seam's `+N chars` figure then confirms.
                //
                // The line is written even when `segments` is empty or every timestamp is
                // zero, which on-device th-TH may well do. That is not a failed measurement,
                // it is the measurement: `covered=0.0s` with a growing `wall` says "this
                // locale reports no timing", which is precisely why the replay window is
                // counted in SAMPLES by `AudioReplayRing` and not in segment timestamps.
                //
                // `wall` is SESSION age, not capture age — it restarts at every rotation and
                // at every backoff restart, so `lag` is a within-session figure and is not
                // comparable across a seam. At a seam the two clocks deliberately disagree:
                // `covered` counts from the head of this REQUEST's audio, which is the
                // replayed window, while `wall` counts from `Session.createdAt`, set after
                // the replay. So a successor born from a replay reads its first `lag` as
                // NEGATIVE by roughly the window — that is the replay working, and it is the
                // verdict on the pre-task-append assumption named in `beginSession`. A first
                // `lag` near zero at a seam is the failing case: the request kept nothing it
                // was fed before its task existed.
                //
                // Costs one sampled write per second and formats nothing when suppressed.
                if admitLagTrace {
                    let segments = result.bestTranscription.segments
                    let covered = segments.last.map { $0.timestamp + $0.duration } ?? 0
                    let wall = Double(nowNanos &- session.createdAt.uptimeNanoseconds)
                        / 1_000_000_000
                    Self.trace("partial-lag: "
                        + "covered=\(String(format: "%.1f", covered))s "
                        + "wall=\(String(format: "%.1f", wall))s "
                        + "lag=\(String(format: "%.1f", wall - covered))s "
                        + "segs=\(segments.count)")
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
        // throttling a chatty client, an asset being swapped out, and — most often of all —
        // the 20 s rotation seam, where a flush of near-silence answers with
        // kAFAssistantErrorDomain 1110 instead of a final. The flush case short-circuits
        // everything below (see "A SEAM IS NOT A FAILURE"); otherwise the honest response is
        // to report the error and stand a new request back up, with backoff so we do not
        // become the reason we are being throttled.
        //
        // ── M4: THE BACKOFF WINDOW OPENS HERE, BEFORE THE TEARDOWN ───────────────────
        // Read BEFORE `finish`, because `finish` clears `current` and from that instant
        // `append` is feeding no request at all — every buffer between here and the
        // successor's install is audio only the ring will have. A backoff can be 8 s long,
        // and 8 s of speech silently dropped is the same class of bug as the rotation seam.
        // Only STORED further down, in the counted branch: a stale generation's error must
        // not open a window on the live owner's behalf.
        let replayMark = replayRing.totalSamplesWritten
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

        // ── A SEAM IS NOT A FAILURE ───────────────────────────────────────────────────
        // Checked BEFORE `consecutiveFailures` moves and before anything is emitted.
        //
        // The 20 s rotation has a seam, and it always will: `beginFlushRotation` sends
        // `endAudio()`, and when the tail it is flushing is near-silence Speech answers with
        // kAFAssistantErrorDomain 1110 ("No speech detected") instead of a final. Counting
        // those was the whole of the 14:26-14:29 bug — the counter falls back to 0 only on a
        // successful result, so seven benign seams in a row reached the old give-up and
        // killed a 906 s capture. The mechanism that produced them (a warm replacement
        // promoted at the seam) is gone; the seam is not, so neither is this exemption.
        //
        // What identifies it now is the session's OWN flush mark rather than the contents of
        // a shared pending slot — the flush set `flushStartedAt` in the same critical section
        // that recorded the replay window, so an error on a flushing session is by
        // construction the answer to that flush. No increment, and deliberately no
        // `.unavailable(...)` either: the consumer lost no audio (the window covers
        // everything after the flush) and a HUD flash at every seam would be both false and
        // ugly. The trace line is the seam's only record, so it carries the error's
        // domain/code — the pair that made the original diagnosis possible.
        //
        // What this path DOES lose, stated plainly: the flush's own `[last emitted partial,
        // flush instant]` span, which only the final would have covered. That is the
        // near-silence the error is reporting, so in practice it is a fragment or nothing at
        // all; closing it properly would mean marking a ring sample at every emitted partial
        // and is a follow-up, not this change.
        //
        // Read in ONE critical section: an error from a retired generation must never
        // restart on the live owner's behalf, and a concurrent `stop()` must not be undone.
        lock.lock()
        let flushSeam = session.flushStartedAt != nil
            && isStarted
            && newestSessionGeneration == session.generation
        let seamUnreported = flushSeam && !session.flushOutcomeReported
        if seamUnreported { session.flushOutcomeReported = true }
        lock.unlock()
        if flushSeam {
            if seamUnreported {
                Self.trace("rotation: flush answered with an error instead of a final on "
                    + "session \(session.generation) — near-silence at the seam; not counted "
                    + "(consecutiveFailures unchanged); the replay window already covers the "
                    + "audio after the flush — " + Self.describeRecognizerError(error))
            }
            // Zero delay, like the flushed-final path: the window is already recorded and
            // the successor is what consumes it. Nothing here is a reason to back off.
            restart(after: 0, reason: nil)
            return
        }

        lock.lock()
        let wanted = isStarted
        // Ownership re-read, same discipline as the stale-final guard: if a successor was
        // installed while this error was in flight, the error belongs to a session that is
        // already history — do not count it, do not report it, and above all do not restart
        // on top of the live successor.
        let ownerAtError = (newestSessionGeneration == session.generation)
        if ownerAtError {
            consecutiveFailures += 1
            // M4. FIRST WRITE WINS: a backoff run chains failures (0.3 s → 8 s) and the
            // window must span the whole chain, so a later failure never moves the start
            // forward over audio no successor has heard yet. `beginSession` clears the slot
            // only when it actually installs a successor.
            //
            // Also gated on `wanted`, unlike the counter above: a window exists to be handed
            // to a successor, and a stopped recognizer will not build one. (`start()` clears
            // the slot regardless, so this is tidiness, not correctness.)
            if wanted, pendingReplayFrom == nil { pendingReplayFrom = replayMark }
        }
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
        // Reaching this line means a GENUINE failure of the live owner: not a rotation seam
        // (those returned above, uncounted), not a stale generation, not a stopped
        // recognizer. The replay window opened above, so whatever the user says during the
        // backoff still reaches the successor — but the failure itself is real and the
        // escalation contract below is what the consumer's watchdog acts on.
        let delay = min(Self.restartBaseDelaySeconds * pow(2, Double(failures - 1)),
                        Self.restartMaxDelaySeconds)

        // ── NO GIVE-UP: WHILE THE USER WANTS DICTATION, WE KEEP TRYING ────────────────
        // Past `maxConsecutiveFailures` this used to clear `isStarted`, drop `current`,
        // orphan any replacement and stop for good. It was a dead end in the most literal
        // sense: no path in this file restarts after it, and `append` drops every buffer
        // once `current` is nil, so the app went on holding a hot microphone and capturing
        // perfect audio into nothing. That is exactly the 14:26-14:29 failure — seven
        // rotation-seam errors reached the counter, the give-up fired at 14:29:20, and the
        // remaining twelve minutes of a 906 s Thai capture produced not one character while
        // the frames counter proved zero dropped buffers.
        //
        // Now the retry never stops while `isStarted`: the backoff is already capped at
        // `restartMaxDelaySeconds` (8 s), a sustainable poll for a recognizer that may well
        // recover on its own — asset swap finished, throttling expired, daemon restarted —
        // and `stop()` remains the one thing that ends it. The audio spoken during those
        // 8 s is no longer thrown away either: it is in the ring, and the successor is fed
        // it (this is M4 — the same one mechanism as the rotation seam, not a second one).
        //
        // What changes past the threshold is the tone of the report, not the behaviour.
        //
        // ── THE TOKEN `persistent recognition failure` IS AN INTERFACE ────────────────
        // main.swift matches that exact lowercase substring to escalate to a full capture
        // restart — the recovery this file cannot perform for itself, because it owns no
        // audio engine. It must appear verbatim on EVERY emission of this state and on no
        // other message, so do not reword it, do not capitalise it, and do not let it drift
        // apart across the two files. The failure count rides along so the watchdog can see
        // how deep the hole is; the vendor text stays last, where it cannot displace the
        // token.
        //
        // The sub-threshold line keeps the word "retry", which the consumer classifies as
        // routine plumbing and hides from the HUD; the escalation line deliberately avoids
        // that word ("trying", not "retrying") so it can never be swallowed as routine.
        if failures > Self.maxConsecutiveFailures {
            emitState(.unavailable(
                "persistent recognition failure — \(failures) consecutive failures, still "
                + "trying every \(String(format: "%.1f", delay)) s: \(message)"))
        } else {
            emitState(.unavailable("recognition error (retry \(failures) in \(String(format: "%.1f", delay)) s): \(message)"))
        }
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

    /// Arm the 20 s rotation watchdog for a session. Armed at session CREATION, which is now
    /// the same instant it becomes the delivery owner — there is no longer a warm
    /// replacement whose clock starts early. If the session is no longer current when the
    /// timer fires, it is already gone and this is a no-op (a stopped session, a session
    /// retired by an error).
    ///
    /// One-shot, and every path that retires a session stands up a successor which arms its
    /// own: that is the invariant to preserve. A session that ends up live with a spent
    /// timer runs unrotated into the measured ~35 s wedge, which is the failure this whole
    /// cadence exists to prevent.
    private func armRotationTimer(for session: Session) {
        queue.asyncAfter(deadline: .now() + Self.sessionRotationSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillLive = (self.current === session)
            self.lock.unlock()
            guard stillLive else { return }
            self.beginFlushRotation(of: session)
        }
    }

    // MARK: - Flush-then-replay rotation

    /// The 20 s watchdog. Flush the owner, and hand its successor the audio the flush could
    /// not cover.
    ///
    /// ── WHAT THIS REPLACES, AND WHY ───────────────────────────────────────────────────
    /// The previous rotation was OVERLAPPED: a replacement request was created while the old
    /// one kept running, on the theory that the old one would keep delivering until the
    /// replacement produced its first partial. Measured across 21 of 21 rotations, that is
    /// not what happens. Creating the second request KILLS the first — the owner delivered a
    /// final or errored with kAFAssistantErrorDomain 1110 in the SAME second, every time,
    /// and the 6 s "silent overlap" fallback fired exactly zero times. So the replacement
    /// heard audio only from its own creation instant, the owner was cancelled without
    /// `endAudio()`, and everything the owner had heard since its last emitted partial was
    /// transcribed by NOBODY. That is a hole in the typed text at every 20 s of continuous
    /// speech, in every application — the "words get cut everywhere" report.
    ///
    /// Flush-then-replay closes it sample-exactly rather than approximately:
    ///
    ///   * the owner is told `endAudio()`, so Speech finalises everything it has heard —
    ///     the final covers `[session start, t0]` and is DELIVERED, not discarded;
    ///   * `t0` is one value of `AudioReplayRing.totalSamplesWritten`, recorded in the same
    ///     critical section that stops `append` feeding this request, so the two boundaries
    ///     are the same boundary;
    ///   * `beginSession` feeds `[t0, now]` out of the ring into the successor before
    ///     installing it, so the successor's first partial already accounts for the seam.
    ///
    /// No fuzzy text-level seam dedup is involved anywhere, deliberately: matching two
    /// different transcriptions of the same audio in a script without spaces is how you eat
    /// words, which is the bug being fixed.
    ///
    /// It also restores FINALS. The old rotation cancelled without one, so a long continuous
    /// dictation produced no final at all and the consumer had nothing to reconcile its
    /// typed ledger against — the absence that forced the re-anchoring design. There is now
    /// one final per seam, delivered before the successor's `.listening` resets that ledger.
    ///
    /// Exactly one outcome line is written for every flush, by whichever of the three
    /// reporters gets there first: the flushed final in `handle`, the error path when the
    /// flush answers 1110 instead, or the 2 s net below. A flush that reported nothing would
    /// read in the trace as a seam that lost nothing.
    private func beginFlushRotation(of session: Session) {
        lock.lock()
        // Same preconditions as any teardown, in one critical section: a retired owner must
        // not be flushed, and a session already mid-flush owns its own seam.
        let live = isStarted && current === session && !session.isFinished
            && session.flushStartedAt == nil
        if live {
            session.flushStartedAt = DispatchTime.now()
            // ── THE SEAM, DECIDED IN ONE CRITICAL SECTION ────────────────────────────
            // Setting the flush mark is what makes `append` stop feeding this request, and
            // reading the ring's counter here — in the SAME critical section, before any
            // buffer can observe the flag — is what makes the replay window start exactly
            // where the final's coverage ends. Doing these two things apart is how a seam
            // grows a hole.
            //
            // This nests the ring's lock inside ours. The order is always (this lock → ring
            // lock) and can never cycle: `AudioReplayRing` has no callbacks, no delegate and
            // no reference to this object, so there is no path that takes them the other way
            // round. See that file's header, which states the same invariant from its side.
            //
            // FIRST WRITE WINS, consistent with the M4 backoff rule: an unconsumed window
            // means a successor is still owed audio, and keeping the older (wider) start can
            // only ever replay a little too much, never too little. In practice the slot is
            // always nil here — a rotation only fires on a live owner, and a live owner
            // means the previous window was consumed when it was installed.
            if pendingReplayFrom == nil {
                pendingReplayFrom = replayRing.totalSamplesWritten
            }
        }
        let baseline = session.lastPartialLength
        lock.unlock()

        guard live else { return }

        Self.trace("rotation: flushing owner \(session.generation) at "
            + "\(String(format: "%.0f", Self.sessionRotationSeconds)) s (endAudio); "
            + "last partial len \(baseline)")
        session.request.endAudio()

        // ── THE NET ──────────────────────────────────────────────────────────────────
        // Its guard is the FLUSH's state, not the session's liveness, because the two
        // diverge on the case that matters most: a flush of pure silence answers with
        // neither a final nor an error, and a flush of near-silence answers with an error
        // that has already retired the session and scheduled its own restart by the time
        // this fires. Guarding on liveness alone would return silently on the first and
        // leave the capture sitting on a request that will never speak again.
        //
        // Nothing is lost by giving up here: the replay window was recorded at the flush, so
        // the successor is fed everything the missing final would have been asked about
        // after `t0`. (What the missing final alone covered — `[last partial, t0]` — is not
        // recoverable on this path; see the same note in the error path.)
        queue.asyncAfter(deadline: .now() + Self.finalFlushTimeoutSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let unreported = !session.flushOutcomeReported
            if unreported { session.flushOutcomeReported = true }
            let stuck = self.isStarted && self.current === session && !session.isFinished
            self.lock.unlock()
            if unreported {
                Self.trace("rotation: flushed final never arrived within "
                    + "\(String(format: "%.0f", Self.finalFlushTimeoutSeconds)) s on session "
                    + "\(session.generation); "
                    + (stuck ? "retiring the owner and restarting — the replay window covers "
                             + "the audio after the flush"
                             : "the session was already retired (see the error above); its "
                             + "restart owns the seam"))
            }
            guard stuck else { return }
            self.finish(session, deliverIdle: false)
            self.restart(after: 0, reason: nil)
        }
    }

    /// Allocate the replay ring for the tap's format, once, off the audio thread.
    ///
    /// Idempotent and safe to call from anywhere except `append`: the first caller to find a
    /// captured format claims the job under the lock, everyone else returns immediately. It
    /// is called from `beginSession` (already on `queue` for every restart) and, so the ring
    /// is armed long before the first seam, from the first Speech callback that notices a
    /// captured-but-unprepared ring — see `capturedTapFormat` for why the format has to be
    /// bootstrapped from a buffer at all.
    private func prepareReplayRingIfNeeded() {
        lock.lock()
        let format = capturedTapFormat
        let alreadyClaimed = replayRingPrepareScheduled
        if format != nil { replayRingPrepareScheduled = true }
        lock.unlock()

        guard let format, !alreadyClaimed else { return }

        switch replayRing.prepare(format: format) {
        case .prepared(let summary):
            Self.trace("replay: ring armed — \(summary)")
        case .unchanged:
            break
        case .unsupported(let reason):
            // Not fatal and not silent: dictation still works, but every seam and every
            // backoff from here on loses its audio the way they did before this mechanism
            // existed, and the trace has to say so rather than let `replay: fed 0.0s` lines
            // be read as "there was nothing to replay".
            Self.trace("replay: ring UNAVAILABLE — \(reason); seams and backoffs will lose "
                + "the audio they cannot hand over")
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
    /// callback thread or on `queue`, both safe for a small append, and overwhelmingly on
    /// lifecycle events — rotation flushes, replay reports and stale-flush suppressions, a
    /// few lines per rotation at most. The ONE exception is the `partial-lag:` line,
    /// which is reached from the partial path and is therefore rate-limited to ≥1 s
    /// (`partialLagTraceIntervalNanos`) and formats nothing when suppressed. Any future
    /// per-partial line must earn the same treatment: unsampled, this call would run
    /// several file writes per second on Speech's callback thread.
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
