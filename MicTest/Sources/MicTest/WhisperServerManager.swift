//
//  WhisperServerManager — owns a resident whisper.cpp `whisper-server` child on loopback
//
//  Lifted from _archive/PhayaVoice/Sources/PhayaVoice/WhisperServerManager.swift and made
//  MicTest-native: no `Settings`, no `LocalTranscriber`, no `trace()`. The reason to keep a
//  server resident is unchanged — a cold `whisper-cli` run pays the model load on every
//  utterance; a server pays it once. Measured 2026-09-03 on this machine (M4 Pro, macOS
//  26.5.1, whisper-cpp 1.8.4, ggml-large-v3-turbo, `-l th`, Metal): the server is ready
//  ~2 s after launch (1.27 s in this file's lifecycle test, weights already in the page
//  cache; whisper's own `load time = 947.51 ms`), then a 5.7 s clip answers in 631-670 ms
//  and a 20 s clip in 1044-1066 ms, byte-stable across repeats
//  (MicTest/TEST-2026-09-03-turbo-server-5clip.txt).
//  The archive quoted 4.08 s per cold `whisper-cli` run and ~0.9 s per warm 3.5 s
//  utterance; those were `ggml-large-v3` (3.1 GB) numbers and are superseded by the above.
//
//  What this file owns, and what it does not:
//    * It spawns, reclaims, restarts and stops ONE `whisper-server`. It does not transcribe:
//      `WhisperClient` does that, against the `/inference` URL `ensureReady` hands back.
//    * It does not call the app's `trace()`, which lives in main.swift — this file has to
//      compile on its own. Everything it has to say goes into `log`, a bounded ring that
//      main.swift can forward through `recentLog(_:)`.
//
//  ── THE BINARY IS NAMED BY PATH, NEVER RESOLVED THROUGH $PATH ────────────────────────────
//
//  The child receives the user's microphone audio. Resolving `whisper-server` through the
//  environment would let whoever controls `$PATH` pick the executable that gets it, so only
//  explicit locations are tried: MicTest's Application Support runtime, then
//  /opt/homebrew/bin and /usr/local/bin. A listener is reclaimed only when its pinned
//  executable (`lsof`, then `proc_pidpath`), PID, and port match this manager's pidfile.
//  Another app's server is never adopted, even if it runs the same executable: its model,
//  language and lifetime belong to that app. Unknown occupied ports are skipped.
//
//  ── NO `--convert`, AND A CHILD ENVIRONMENT OF THREE VARIABLES ──────────────────────────
//
//  The archive launched with `--convert --tmp-dir`, which makes server.cpp v1.8.4 write
//  every request's audio to a temp file and run `ffmpeg` through `std::system` (line 324)
//  — a per-utterance disk copy of the microphone plus a `/bin/sh` spawn, for input this
//  app never sends: `AudioPipeline.Chunk.wav` is already 16 kHz mono 16-bit, the one
//  format whisper.cpp reads natively (and v1.8.4's non-convert path resamples through
//  miniaudio anyway, common-whisper.cpp line 49). Dropping it also removes the only
//  reason the child needed a PATH, so the environment is built from scratch — PATH
//  pinned to the system directories, HOME, TMPDIR — rather than inherited minus
//  `DYLD_*`: a harness-launched app carries the shell's exports (any `*_KEY`) into the
//  child, where `ps -Eww` shows them to the same user. Measured 2026-09-03 by the app's
//  launch preload, no `--convert`, that three-variable environment (`ps -Eww` on the
//  child showed exactly PATH, TMPDIR, HOME): ready in 1.26 s and 0.64 s across two
//  launches, `warmUp()` transcribed jfk.wav (105 chars) in 3.8 s and 2.6 s. So the ggml
//  Metal backend needs nothing from the environment (its shader library is embedded, per
//  the server's own startup banner).
//
//  The earlier executable-only adoption check is now stricter: an unknown listener
//  receives no HTTP probe or inference. Only an owned or reclaimed listener is probed.
//
//  ── WHY READINESS IS AN HTTP PROBE, NOT A TRANSCRIPTION ─────────────────────────────────
//
//  server.cpp v1.8.4 loads the model (line 706) BEFORE binding the port (line 1208), so a
//  TCP accept already proves the weights are resident; `GET /health` (line 1170) answers
//  `{"status":"ok"}` carrying the `Server: whisper.cpp` header the server stamps on every
//  response (line 718). That is the whole readiness check. Posting a tiny silent WAV was
//  rejected on measurement: this model does not report silence, it invents speech for it
//  (`โปรดติดตามตอนต่อไป` for 1-5 s of zeros — WhisperClient.swift, `speechText(from:)`), so
//  a silent probe proves nothing `/health` does not, costs an inference, and teaches the
//  reader that silent audio is safe to send. What no probe can tell is WHICH model (or
//  which `-l`) another app's server holds: `/health` reports only `status`.
//
//  ── THE FIRST REQUEST IS SLOW, SO `warmUp()` SPENDS IT ON A BUNDLED CLIP ────────────────
//
//  Measured 2026-09-03 on an M4 Pro: after `ensureReady`, the first `/inference` of a
//  fresh process pays Metal shader compilation, ~1-2 s, before the steady-state numbers
//  above apply. `warmUp()` posts Homebrew's jfk.wav (11 s of English speech, 16 kHz mono)
//  so that cost lands before the user's first utterance rather than on it. Requests are
//  serialised server-side (`/inference` takes `whisper_mutex`, line 807), so an utterance
//  that arrives mid-warm-up waits behind it — bounded by the warm-up's own duration.
//
//  What that duration is, measured 2026-09-03 by this file's lifecycle test: the warm-up
//  took 2.6 s, and the SAME clip re-sent twice took 3.3 s and 2.2 s. English speech decoded
//  under `-l th` trips whisper's temperature fallbacks (`fallbacks = 11 p / 6 h` across
//  those three requests, per the server's own timings), so jfk.wav shows the first-request
//  cost being paid but cannot show the 650 ms steady state — that number is Thai speech. A
//  single-pass warm-up (`temperature_inc=0`, a per-request field the server resets after
//  each request: server.cpp lines 573-575 and 1125) was not tried and is not claimed.
//
//  ── ISOLATION ───────────────────────────────────────────────────────────────────────────
//
//  An `actor`, not a `@MainActor` class: readiness polling runs for seconds, the model load
//  for ~2 s, none of it UI state, and the main thread has a HUD to drive meanwhile. Nothing
//  here hops to the main actor. The two things that cannot be actor-isolated — the pipe
//  drains, which fire on a private Dispatch queue, and `emergencyStop()`, which has to run
//  synchronously inside `applicationWillTerminate` — go through `Mutex` (`Synchronization`)
//  and touch nothing else.
//

import Foundation
import Synchronization

// MARK: - Errors

/// Everything that can go wrong owning a `whisper-server` child.
///
/// Thrown by `WhisperServerManager.ensureReady(timeout:progress:)`. `description` is one
/// short, actionable line, meant to be shown or traced as-is.
enum WhisperServerError: Error, CustomStringConvertible, Sendable {
    /// No executable at any of `WhisperServerManager.binaryCandidates`.
    case binaryMissing(candidates: [String])
    /// No usable ggml model. The payload says where it looked, or which configured file
    /// was unreadable.
    case modelMissing(String)
    /// Every candidate port is occupied by a listener this manager does not own.
    case noFreePort(base: Int, tried: [Int])
    /// `Process.run()` itself failed, or a `stop()` landed while the start was in flight.
    case launchFailed(String)
    /// The child died while loading the model: a bad or truncated model, OOM, an external
    /// kill.
    case exitedDuringStartup(status: Int32, log: String)
    /// The port never answered within the allotted time.
    case readinessTimeout(seconds: Double, log: String)

    var description: String {
        switch self {
        case .binaryMissing(let candidates):
            return "whisper-server not found at \(candidates.joined(separator: " or "))"
                + " — brew install whisper-cpp"
        case .modelMissing(let detail):
            return "whisper model unavailable — \(detail)"
        case .noFreePort(let base, let tried):
            let list = tried.map(String.init).joined(separator: ", ")
            return "ports \(list) are in use by servers this app does not own"
                + " (base port \(base))"
        case .launchFailed(let reason):
            return "could not launch whisper-server: \(reason)"
        case .exitedDuringStartup(let status, let log):
            return "whisper-server exited (status \(status)) while loading the model. \(log)"
        case .readinessTimeout(let seconds, let log):
            return "whisper-server did not answer within \(Int(seconds))s. \(log)"
        }
    }
}

// MARK: - Progress

/// Coarse startup progress, so the HUD can say "loading model…" during the load.
enum WhisperServerProgress: Sendable, Equatable {
    /// Deciding which port to use.
    case selectingPort(base: Int)
    /// An orphan of this app was reclaimed using its pidfile. The case name is retained
    /// for existing consumers; another app's server is never adopted.
    case adoptedExisting(port: Int)
    /// Child spawned; the model load starts now.
    case launching(port: Int)
    /// Still waiting for the port to answer. `elapsed` is seconds since launch.
    case loadingModel(elapsed: TimeInterval)
    /// `/health` answered.
    case ready(port: Int, elapsed: TimeInterval)
}

// MARK: - Log ring

/// A small, bounded, thread-safe line buffer for the child's stdout/stderr.
///
/// `FileHandle.readabilityHandler` fires on a private Dispatch queue, so the sink it
/// writes into must be `Sendable` and independently synchronised — it cannot touch
/// actor-isolated state. `Mutex` gives that without an `@unchecked` escape hatch.
///
/// Capacity is lines, not bytes. 400 was sized when the child ran under `--convert` and
/// ffmpeg added a measured 30 lines of banner per request. Without the flag, measured
/// 2026-09-03 on 1.8.4 with two jfk.wav requests: 3 stdout lines per request (`Received
/// request: <client filename>`, `Successfully loaded`, `Running whisper.cpp inference`)
/// and ~10 stderr timing lines, no transcript text on either — so the ring holds a few
/// dozen utterances behind the model-load banner. Kept at 400: it is bounded at a few
/// tens of KB either way.
///
/// Not chronological across streams, and do not read it as such: the child's stdout is
/// block-buffered by its own stdio while it is a pipe (server.cpp flushes only inside the
/// progress callback, line 453), so its `printf` lines — `Received request`, `whisper
/// server listening` — surface late, often only at exit, while ffmpeg's output and
/// whisper's stderr arrive at once. Measured: `whisper server listening at` reached the
/// ring AFTER `[manager] stop()`.
final class WhisperLogRing: Sendable {
    private let capacity: Int
    private let lines = Mutex<[String]>([])
    /// Lines ever appended, so a caller can tell "quiet" from "ring wrapped".
    private let appended = Mutex<Int>(0)

    init(capacity: Int = 400) {
        self.capacity = max(8, capacity)
    }

    /// Appends a raw chunk of child output, splitting it into lines.
    func append(chunk: String) {
        let incoming = chunk
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return }
        appended.withLock { $0 += incoming.count }
        lines.withLock { buffer in
            buffer.append(contentsOf: incoming)
            if buffer.count > capacity {
                buffer.removeFirst(buffer.count - capacity)
            }
        }
    }

    /// Appends one line written by the manager itself (not by the child).
    func note(_ line: String) { append(chunk: line) }

    /// The most recent `count` lines, oldest first.
    func tail(_ count: Int = 12) -> [String] {
        lines.withLock { Array($0.suffix(count)) }
    }

    /// Total lines ever appended (child output plus manager notes).
    var totalLines: Int { appended.withLock { $0 } }

    /// The most recent lines as one single-line string, for embedding in errors.
    func tailSummary(_ count: Int = 6) -> String {
        let recent = tail(count)
        guard !recent.isEmpty else { return "(no output captured)" }
        return "last output: " + recent.joined(separator: " | ")
    }
}

// MARK: - Manager

/// Owns the lifecycle of one resident `whisper-server` child process. See the file
/// header for the design; the lifecycle in one paragraph:
///
/// `ensureReady` reclaims a ready whisper-server only when its pinned executable, PID,
/// and listening port match this manager's existing pidfile. Other listeners are left
/// alone. Otherwise it spawns one bound to 127.0.0.1 and polls `/health` until the
/// model is resident, then returns the `/inference` URL. `warmUp` spends the slow first
/// request on a bundled clip. A child that crashes is restarted up to
/// `maxRestartAttempts` times with backoff. `stop` terminates a child we spawned —
/// SIGTERM to its process group, SIGKILL after `terminationGraceSeconds` — and forgets an
/// adopted one. `emergencyStop` is the synchronous version for `applicationWillTerminate`.
///
/// What this cannot do: outlive-proof the child against the APP being SIGKILLed. There is
/// no parent-death signal on macOS. The orphan is not a leak that compounds, though: the
/// pid of every child this app launches is written to `<scratch>/whisper-server.pid`, and
/// the next launch, finding a pinned whisper-server on a candidate port whose pid is the
/// one in that file, RECLAIMS it (`Ownership.reclaimed`) — `stop()` and `emergencyStop()`
/// end it exactly as they end a child this run spawned. Without the file it would be
/// merely adopted and would then outlive every later run until reboot. Measured
/// 2026-09-03: `kill -9` of the app left the child (pid in the file) listening; the next
/// launch logged `reclaimed`, and `pgrep -fl whisper-server` was empty after that launch
/// quit.
actor WhisperServerManager {

    /// Who started the process we are talking to.
    enum Ownership: Sendable, Equatable {
        /// Nothing running / nothing adopted.
        case none
        /// Legacy compatibility case. New starts never adopt another app's server.
        case adopted
        /// We spawned it, so we may terminate and restart it.
        case owned
        /// An EARLIER run of this app spawned it and was SIGKILLed before it could stop
        /// it; its pid matched the pidfile. Ours to terminate — but not a `Process` we
        /// hold, so there is no termination handler and no crash restart for it.
        case reclaimed
    }

    /// What `warmUp()` did. Scalars and short reasons only — nothing a log should not hold.
    enum WarmUpOutcome: Sendable, Equatable {
        /// The clip was transcribed; `seconds` is the round trip, shader compile included.
        case warmed(seconds: Double)
        /// This server instance was already warmed by an earlier call.
        case alreadyWarm
        /// Nothing was sent: no server, or no clip on disk. Carries the reason.
        case skipped(String)
        /// The request went out and failed. Carries the reason.
        case failed(String)
    }

    /// Result of one `/health` probe.
    enum Probe: Sendable, Equatable {
        /// whisper.cpp answered 200 — model resident.
        case ready
        /// whisper.cpp answered 503 — mid `/load`. Only reachable on an external server;
        /// our own child binds after loading (server.cpp lines 706 vs 1208).
        case loading
        /// Nothing answered, or whatever answered did not identify as whisper.cpp.
        case absent
    }

    // ── LOCATIONS AND LIMITS ──────────────────────────────────────────────────────────

    /// Runtime owned by MicTest, independent of another app's installation.
    static let runtimeDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/MicTest/whisper", directoryHint: .isDirectory)
    static let modelsDirectory = runtimeDirectory.appending(path: "models", directoryHint: .isDirectory)

    /// Explicit executable paths, never resolved through the inherited PATH.
    static let binaryCandidates = [
        runtimeDirectory.appending(path: "bin/whisper-server").path,
        "/opt/homebrew/bin/whisper-server",
        "/usr/local/bin/whisper-server",
    ]

    /// Homebrew's bundled sample: 11 s of English speech, 16 kHz mono Int16, 352 KB.
    /// Harmless to send, and absent on a machine without whisper-cpp — in which case
    /// `warmUp()` skips silently.
    static let warmUpClipPath = "/opt/homebrew/share/whisper-cpp/jfk.wav"

    /// Matches `WhisperClient.init(port:)`'s default, so a client built without a port
    /// argument talks to the server this manager starts in the common case.
    static let defaultPort = 8177

    /// `-l` for the child. Fixed at launch: the per-request `language` field does not
    /// override it (WhisperClient.swift header). Not `auto` — the sibling harness measured
    /// `auto` identical to `th` on its test clips, and `th` costs no detection pass.
    static let defaultLanguage = "th"

    /// Below this a `ggml-*.bin` is a stub or a partial download, not a model. Mirrors
    /// `MIN_MODEL_BYTES` in thaiasr/thaiasr/providers/local_whisper.py. The counterexample
    /// it exists for: /opt/homebrew/share/whisper-cpp/for-tests-ggml-tiny.bin, 575 KB.
    static let minimumModelBytes: Int64 = 10_000_000

    /// Extra model directories, `:`-joined (Python's `os.pathsep` on macOS), scanned LAST.
    static let modelDirectoryVariable = "WHISPER_MODEL_DIR"

    /// Consecutive ports considered, starting at `preferredPort`.
    static let portScanCount = 4

    /// Crash-restart cap. Manual `ensureReady` calls are not subject to it.
    static let maxRestartAttempts = 3

    /// How long SIGTERM gets before SIGKILL. whisper-server handles SIGTERM by stopping
    /// the listener and freeing the model (server.cpp lines 1226-1231); measured, `stop()`
    /// returned 373 ms after sending it, the child logging `Caught signal 15, shutting
    /// down gracefully...` and its timings on the way out.
    static let terminationGraceSeconds: Double = 3.0

    /// Process-wide instance for the app. Built lazily, so `discoverModel()`'s directory
    /// scan runs on first use, not at load.
    static let shared = WhisperServerManager()

    // ── CONFIGURATION (immutable for the life of the manager) ─────────────────────────

    /// The ggml weights the child is launched with; `nil` when discovery found nothing,
    /// which `ensureReady` reports as `.modelMissing` rather than failing in `init`.
    let modelURL: URL?
    /// Optional Silero weights; enabled per inference request, never by a global --vad.
    let vadModelURL: URL?
    /// `large-v3-turbo` for `ggml-large-v3-turbo.bin`; for display.
    let modelName: String
    let language: String
    let preferredPort: Int
    /// The child's working directory and its `TMPDIR`. Under the app's own temporary
    /// directory so it is writable — a Finder-launched app's cwd is `/`. Nothing is
    /// written there on the request path any more (no `--convert`, see the header); it
    /// exists so the child never inherits an unwritable cwd.
    private let scratchDirectory: URL
    private let executableCandidates: [String]

    // ── MUTABLE, ACTOR-ISOLATED STATE ─────────────────────────────────────────────────

    private var child: Process?
    /// The pid behind `Ownership.reclaimed`; `nil` in every other state. Liveness is
    /// `kill(pid, 0)`, because no `Process` wraps it.
    private var reclaimedPid: pid_t?
    /// `<scratchDirectory>/whisper-server.pid`: PID, port and launch configuration of
    /// the child this manager launched. Legacy PID-only records cannot prove which
    /// model/VAD is resident, so they are not reclaimed.
    private let pidFileURL: URL
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var ownership: Ownership = .none
    private var activePort: Int?
    /// Incremented on every launch. A termination handler whose epoch is stale belongs
    /// to a process we already replaced and must be ignored, otherwise a late exit from
    /// generation N triggers a spurious restart of N+1.
    private var epoch: Int = 0
    /// Incremented on every launch AND every reclaim: identifies the server instance
    /// `warmUp()` has already warmed.
    private var serverGeneration: Int = 0
    private var warmedGeneration: Int?
    private var restartAttempts: Int = 0
    /// Exit record for the most recently reaped child. `waitUntilReady` needs this
    /// because the termination handler clears `child` before the waiter gets a chance to
    /// observe `!isRunning` — without it a child that dies during the model load looks
    /// identical to one that is merely slow.
    private var exitedEpoch: Int?
    private var exitedStatus: Int32 = 0
    /// A crash restart has been armed and has not yet produced a new child.
    private var restartPending: Bool = false
    private var stopRequested: Bool = false
    /// True from the first line of `stop()` until it returns. `stop()` suspends in
    /// `waitForExit` (50 ms polls), and `ensureReady()` is reachable in that window from
    /// a correction the app does not cancel (main.swift `finishCapture` deliberately
    /// leaves `cloudTask` running). Without this flag that call clears `stopRequested`,
    /// `performStart` sees the dead child and launches a new one, and the resuming
    /// `stop()` then clears `child`, the pidfile and `ownedChildPid` under it — a server
    /// nothing tracks, which `emergencyStop()` cannot signal and the next launch adopts.
    private var stopInFlight: Bool = false
    private var startTask: Task<Void, Error>?
    /// Identifies the in-flight start, so a completing start never clears a NEWER one
    /// that replaced it.
    private var startTaskID: Int = 0
    private var restartTask: Task<Void, Never>?
    private var launchedAt: Date?

    /// Diagnostics buffer, drained continuously from the child's pipes. A `let` of a
    /// `Sendable` type, so `recentLog` can read it without entering the actor.
    let log = WhisperLogRing()

    /// Nonisolated mirror of "the pid of a child WE own", for `emergencyStop()`, which
    /// cannot await the actor. `nil` whenever nothing owned is running.
    private let ownedChildPid = Mutex<pid_t?>(nil)
    /// Set by `emergencyStop()`; read by `childDidExit` so the exit it causes is not
    /// mistaken for a crash and restarted while the app is going down.
    private let emergencyStopRequested = Mutex<Bool>(false)
    /// Set by `vetoPendingStart()`, read by `launch(binary:model:on:)`, cleared by the
    /// next `ensureReady()`. `stopRequested` is actor state, so a caller that has decided
    /// to stop cannot set it until its `stop()` runs — and main.swift runs `stop()` only
    /// after the start it cancelled has finished. Cancelling that start does not reach
    /// `performStart`: `startShared` awaits an unstructured inner task via `.value`,
    /// which neither cancels it nor throws to the waiter, so without this flag the
    /// cancelled start still spawned whisper-server and began its 1.6 GB model load,
    /// which the queued `stop()` then SIGTERMed.
    private struct StartControl: Sendable {
        var vetoed = false
        var stopGeneration: UInt64 = 0
    }
    /// A stop can finish while readiness is suspended in a health probe. The
    /// generation prevents that older request from clearing a newer stop veto.
    /// Keep both fields under one lock because vetoPendingStart is nonisolated.
    private let startControl = Mutex(StartControl())

    /// Optional transport seam for deterministic readiness/stop race tests. The
    /// exact owned listener is still verified before this probe is called.
    private let readyProbeOverride: (@Sendable (Int) async -> Probe)?

    /// 2 s timeouts: a loopback probe answers fast or not at all.
    private let probeSession: URLSession
    /// 30 s timeouts, matching `WhisperClient.requestTimeout`: the warm-up is a real
    /// inference and can take a couple of seconds.
    private let inferenceSession: URLSession

    /// - Parameters:
    ///   - modelURL: ggml weights. Defaults to `discoverModel()`; pass a URL to pin one.
    ///   - language: `-l` for the child. Defaults to `"th"`. See `defaultLanguage`.
    ///   - preferredPort: first port tried; up to `portScanCount` consecutive ports are
    ///     considered. Defaults to 8177, `WhisperClient`'s default.
    ///   - scratchDirectory: isolated state and pidfile directory; defaults to the app's
    ///     temporary directory. Tests use their own directory and ports.
    ///   - binaryCandidates: explicitly pinned executable paths. Defaults to the app's
    ///     runtime and Homebrew locations; never a command resolved through PATH.
    ///   - vadModelURL: optional Silero weights. Only the MicTest-owned runtime receives
    ///     --vad-model; requests choose whether VAD is enabled.
    ///   - readyProbeOverride: optional controlled transport for readiness race tests;
    ///     nil uses the normal loopback health request.
    init(modelURL: URL? = WhisperServerManager.discoverModel(),
         language: String = WhisperServerManager.defaultLanguage,
         preferredPort: Int = WhisperServerManager.defaultPort,
         scratchDirectory: URL? = nil,
         binaryCandidates: [String] = WhisperServerManager.binaryCandidates,
         vadModelURL: URL? = WhisperServerManager.discoverVADModel(),
         readyProbeOverride: (@Sendable (Int) async -> Probe)? = nil) {
        self.modelURL = modelURL
        self.vadModelURL = vadModelURL
        self.modelName = modelURL.map(Self.modelShortName(for:)) ?? "(no model found)"
        self.language = language
        self.preferredPort = preferredPort
        self.executableCandidates = binaryCandidates
        self.readyProbeOverride = readyProbeOverride
        let scratchDirectory = scratchDirectory ?? FileManager.default.temporaryDirectory
            .appending(path: "MicTest-whisper-server", directoryHint: .isDirectory)
        self.scratchDirectory = scratchDirectory
        self.pidFileURL = scratchDirectory.appending(path: "whisper-server.pid")

        let probe = URLSessionConfiguration.ephemeral
        probe.timeoutIntervalForRequest = 2
        probe.timeoutIntervalForResource = 3
        probe.waitsForConnectivity = false
        probe.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // `RefuseRedirects`: a 3xx from whatever holds the port must never re-send the
        // request elsewhere. The probe carries no audio; the inference session carries
        // jfk.wav; the rule is one rule for every loopback session in this app.
        self.probeSession = RefuseRedirects.session(configuration: probe)

        let inference = URLSessionConfiguration.ephemeral
        inference.timeoutIntervalForRequest = 30
        inference.timeoutIntervalForResource = 45
        inference.waitsForConnectivity = false
        inference.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        inference.httpMaximumConnectionsPerHost = 1
        self.inferenceSession = RefuseRedirects.session(configuration: inference)
    }

    /// Primary local transcription requires the full model and the app's VAD-capable
    /// runtime. Homebrew fallback binaries keep their older launch arguments.
    nonisolated var localFinalConfigured: Bool {
        guard modelName == "large-v3", let modelURL, let vadModelURL,
              FileManager.default.isReadableFile(atPath: modelURL.path),
              FileManager.default.isReadableFile(atPath: vadModelURL.path),
              let binary = Self.firstExecutable(in: executableCandidates) else { return false }
        return Self.isOwnedRuntimeBinary(binary)
    }

    // MARK: - Public API

    /// The port our owned or reclaimed process is bound to, if any.
    var port: Int? { activePort }

    /// Whether the running server is ours (`owned`), an orphan of an earlier run that
    /// this one took back (`reclaimed`), someone else's (`adopted`), or absent (`none`).
    var currentOwnership: Ownership { ownership }

    /// `POST` target for transcription, once a port is known.
    var inferenceURL: URL? { activePort.map(Self.inferenceURL(port:)) }

    /// One-line snapshot for the trace and for error reports. `await`-able from anywhere.
    var diagnostics: String {
        let pid = child.map { String($0.processIdentifier) }
            ?? reclaimedPid.map(String.init) ?? "-"
        let model = modelURL.map { "\(modelName) (\($0.path))" } ?? "none found"
        let binary = Self.firstExecutable(in: executableCandidates) ?? "missing"
        return "port=\(activePort.map(String.init) ?? "-") ownership=\(ownership) pid=\(pid)"
            + " restarts=\(restartAttempts) language=\(language) model=\(model)"
            + " binary=\(binary) cwd=\(scratchDirectory.path)"
    }

    /// Recent child output and manager notes, oldest first. Synchronous and safe from any
    /// thread, so main.swift can forward it into `trace()` without awaiting.
    nonisolated func recentLog(_ count: Int = 20) -> [String] { log.tail(count) }

    /// Start (or reclaim) a whisper-server bound to loopback, wait until its model is
    /// resident, and hand back the `/inference` URL.
    ///
    /// Idempotent in three ways: a ready server we already own or reclaimed is returned
    /// at once; a ready whisper-server already listening on a candidate port is ADOPTED
    /// (no second child, and `stop()` leaves it alive); concurrent callers share one
    /// in-flight start.
    ///
    /// Fails fast rather than burning the whole timeout when a child we own dies during
    /// the load — a bad model path or an OOM shows up as an exit, not as silence.
    ///
    /// - Parameters:
    ///   - timeout: seconds to wait for readiness. The turbo model was ready in 1.27 s
    ///     here (page-cached) and ~2 s in the bake-off; 60 s covers a cold 3.1 GB
    ///     `large-v3` on a slower disk.
    ///   - progress: called from the actor with coarse stages, roughly twice a second
    ///     while loading. The callback is `@Sendable`; a UI hops to the main actor itself.
    @discardableResult
    func ensureReady(timeout: TimeInterval = 60,
                     progress: (@Sendable (WhisperServerProgress) -> Void)? = nil)
        async throws -> URL
    {
        // A `stop()` suspended in `waitForExit` must not be resurrected by a request that
        // arrives inside its window; the utterance fails with a traced reason instead
        // (`describeCloudError` in main.swift renders `WhisperServerError`).
        guard !stopInFlight else {
            throw WhisperServerError.launchFailed("stop() in progress")
        }
        let requestGeneration = startControl.withLock { $0.stopGeneration }
        try validateReadinessRequest(requestGeneration)
        // Verify the exact owned PID before probing: a former listener may have exited
        // and left this port to another app, even one using the same whisper binary.
        if let port = activePort {
            let trusted = await activeListenerIsTrusted(on: port)
            try validateReadinessRequest(requestGeneration)
            if trusted {
                let health = if let readyProbeOverride {
                    await readyProbeOverride(port)
                } else {
                    await Self.probe(port: port, session: probeSession)
                }
                try validateReadinessRequest(requestGeneration)
                if health == .ready { return Self.inferenceURL(port: port) }
            }
        }
        // Atomically clear only a veto older than this explicit start request.
        // Checking a generation and then clearing a separate Bool would let a
        // synchronous veto land between those two operations and be erased.
        let permitted = startControl.withLock { control in
            guard control.stopGeneration == requestGeneration else { return false }
            control.vetoed = false
            return true
        }
        guard permitted else {
            throw WhisperServerError.launchFailed("readiness request superseded by stop")
        }
        stopRequested = false      // an explicit start cancels a previous stop
        try await startShared(progress: progress)
        try validateReadinessRequest(requestGeneration)
        let port = try await waitUntilReady(timeout: timeout, progress: progress,
                                           expectedStopGeneration: requestGeneration)
        try validateReadinessRequest(requestGeneration)
        return Self.inferenceURL(port: port)
    }

    private func validateReadinessRequest(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard !stopInFlight,
              startControl.withLock({ $0.stopGeneration == generation }) else {
            throw WhisperServerError.launchFailed("readiness request superseded by stop")
        }
    }

    /// True when a server is listening on our port and identifies as whisper.cpp with
    /// its model resident.
    ///
    /// The exact owned listener is checked before `/health`; the health endpoint alone
    /// does not establish ownership or report the loaded model.
    func isHealthy() async -> Bool {
        guard let port = activePort else { return false }
        guard await activeListenerIsTrusted(on: port) else { return false }
        return await Self.probe(port: port, session: probeSession) == .ready
    }

    /// Is the exact process behind `port` ours? A matching executable alone is not
    /// ownership. Reclaimed processes additionally retain the matching pidfile record.
    private func activeListenerIsTrusted(on port: Int) async -> Bool {
        switch ownership {
        case .owned:
            guard let child, child.isRunning else { return false }
            return await Self.pinnedWhisperListener(on: port, candidates: executableCandidates)
                == child.processIdentifier
        case .reclaimed:
            guard let pid = reclaimedPid,
                  let recorded = Self.readPidFile(pidFileURL),
                  recorded.pid == pid, recorded.port == port,
                  recordMatchesConfiguration(recorded) else { return false }
            return await Self.pinnedWhisperListener(on: port, candidates: executableCandidates) == pid
        case .adopted, .none: return false
        }
    }

    /// Spend the slow first request on `warmUpClipPath` so the user's first utterance
    /// does not pay Metal shader compilation. See the file header for the measurement.
    ///
    /// Once per server instance: a second call on the same launch or reclaim returns
    /// `.alreadyWarm` without sending anything. Skips silently (returning the reason) if
    /// no server is up or the clip is absent. The transcript is not logged — only its
    /// length and the round-trip time.
    @discardableResult
    func warmUp() async -> WarmUpOutcome {
        guard let port = activePort else {
            return .skipped("no server is running — call ensureReady first")
        }
        if warmedGeneration == serverGeneration { return .alreadyWarm }
        let generation = serverGeneration

        let clip = URL(fileURLWithPath: Self.warmUpClipPath)
        guard FileManager.default.isReadableFile(atPath: clip.path) else {
            return .skipped("\(clip.path) is absent")
        }
        guard let wav = try? Data(contentsOf: clip), wav.count > 44 else {
            return .skipped("\(clip.path) could not be read")
        }
        guard await activeListenerIsTrusted(on: port) else {
            return .skipped("the listening server is no longer owned by this app")
        }

        let body = Self.multipartBody(wav: wav, filename: clip.lastPathComponent,
                                      language: language)
        var request = URLRequest(url: Self.inferenceURL(port: port))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(body.boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.setValue(String(body.data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body.data

        let clock = ContinuousClock()
        let started = clock.now
        do {
            let (data, response) = try await inferenceSession.data(for: request)
            let seconds = Self.seconds(started.duration(to: clock.now))
            guard let http = response as? HTTPURLResponse else {
                return .failed("non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let snippet = String(decoding: data.prefix(120), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                log.note("[manager] warm-up: HTTP \(http.statusCode) \(snippet)")
                let detail = snippet.isEmpty ? "" : ": \(snippet)"
                return .failed("HTTP \(http.statusCode)\(detail)")
            }
            let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["text"] as? String } ?? ""
            if generation == serverGeneration { warmedGeneration = generation }
            log.note("[manager] warm-up: \(clip.lastPathComponent) transcribed"
                + " (\(text.count) chars) in \(String(format: "%.0f", seconds * 1000)) ms")
            return .warmed(seconds: seconds)
        } catch {
            log.note("[manager] warm-up failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Terminate the child ONLY if we started it.
    ///
    /// A server that was already running when we arrived (`.adopted`) is left untouched;
    /// we merely forget about it. For our own child: SIGTERM to its process group, then
    /// SIGKILL after `terminationGraceSeconds` if it is still there. Group-wide, so any
    /// helper the server spawns goes with it — Foundation starts the child as its own
    /// group leader (measured: child pgid == child pid).
    func stop() async {
        vetoPendingStart()
        stopInFlight = true
        defer { stopInFlight = false }
        stopRequested = true
        restartPending = false
        startTask?.cancel(); startTask = nil
        restartTask?.cancel(); restartTask = nil

        if ownership == .reclaimed, let pid = reclaimedPid {
            // Same signals, same grace, as the owned path below; liveness by `kill(pid,
            // 0)` because launchd, not this process, reaps the orphan (ESRCH once it is
            // gone).
            log.note("[manager] stop(): SIGTERM to reclaimed whisper-server process group"
                + " \(pid)")
            Self.send(SIGTERM, toGroupOf: pid)
            await waitForExit(ofPid: pid, upTo: Self.terminationGraceSeconds)
            if kill(pid, 0) == 0 {
                log.note("[manager] SIGTERM ignored after"
                    + " \(Int(Self.terminationGraceSeconds)) s — SIGKILL")
                Self.send(SIGKILL, toGroupOf: pid)
                await waitForExit(ofPid: pid, upTo: 1.0)
            }
            let outcome = kill(pid, 0) == 0 ? "still running" : "gone"
            log.note("[manager] stop(): reclaimed whisper-server \(outcome)")
            Self.removePidFile(pidFileURL)
            forgetServer()
            return
        }
        guard ownership == .owned, let child else {
            if ownership == .adopted {
                let port = activePort.map(String.init) ?? "?"
                log.note("[manager] stop(): server on port \(port) was running before us"
                    + " — leaving it alive")
            }
            forgetServer()
            return
        }

        epoch &+= 1 // invalidate the termination handler: this exit is expected
        let pid = child.processIdentifier
        log.note("[manager] stop(): SIGTERM to whisper-server process group \(pid)")
        if child.isRunning { Self.send(SIGTERM, toGroupOf: pid) }

        // Bounded wait. Never `waitUntilExit()` — it would block a cooperative thread.
        await waitForExit(of: child, upTo: Self.terminationGraceSeconds)
        if child.isRunning {
            log.note("[manager] SIGTERM ignored after \(Int(Self.terminationGraceSeconds)) s"
                + " — SIGKILL")
            Self.send(SIGKILL, toGroupOf: pid)
            await waitForExit(of: child, upTo: 1.0)
        }
        let outcome = child.isRunning ? "still running" : "gone"
        log.note("[manager] stop(): whisper-server \(outcome)")

        ownedChildPid.withLock { $0 = nil }
        self.child = nil
        Self.removePidFile(pidFileURL)
        forgetServer()
    }

    /// Synchronous SIGTERM to a child we own, from any thread, without awaiting.
    ///
    /// For `applicationWillTerminate` and `atexit`, where there is no time to `await
    /// stop()`: the app exits right after, and a child left behind would keep 1.6 GB of
    /// weights resident and the port taken. An adopted server is not touched. The
    /// termination handler still runs `childDidExit`, which sees the flag set here and
    /// does not schedule a restart. Nothing is waited for: whisper-server exits on its
    /// own SIGTERM handler.
    nonisolated func emergencyStop() {
        vetoPendingStart()
        emergencyStopRequested.withLock { $0 = true }
        guard let pid = ownedChildPid.withLock({ $0 }) else { return }
        Self.send(SIGTERM, toGroupOf: pid)
        // The pidfile goes with it: a stale file would let the next launch match a
        // reused pid. `pidFileURL` is a `let`, so this is synchronous like the rest.
        Self.removePidFile(pidFileURL)
        log.note("[manager] emergencyStop(): SIGTERM to process group \(pid)")
    }

    /// Refuse to spawn a child for a start that is already in flight. For a caller that
    /// cancels a start and then queues `stop()` behind it: the cancellation alone does
    /// not stop `performStart` (see `startControl`), this does, at `launch`. Cleared by
    /// the next `ensureReady()`; a start that has already spawned is unaffected and
    /// `stop()` ends it as usual.
    nonisolated func vetoPendingStart() {
        startControl.withLock {
            $0.vetoed = true
            $0.stopGeneration &+= 1
        }
    }

    // MARK: - Model discovery

    /// Directories scanned for `ggml-*.bin`, in priority order, duplicates removed.
    ///
    /// MicTest's Application Support directory comes first, followed by the legacy
    /// `MODEL_DIRS` in thaiasr/thaiasr/providers/local_whisper.py with one omission:
    /// the harness also scans `./models`, relative to its working directory.
    /// An app has no meaningful working directory (Finder launches it at `/`), so that
    /// entry is dropped. `$WHISPER_MODEL_DIR` — `:`-joined, `~` expanded — comes last.
    static func modelSearchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [
            modelsDirectory,
            home.appending(path: ".cache/hyperframes/whisper/models"),
            home.appending(path: ".cache/whisper"),
            home.appending(path: "Library/Application Support/whisper"),
            URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp/models"),
        ]
        if let extra = environment[modelDirectoryVariable] {
            for part in extra.split(separator: ":") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let expanded = (trimmed as NSString).expandingTildeInPath
                directories.append(URL(fileURLWithPath: expanded, isDirectory: true))
            }
        }
        var seen = Set<String>()
        return directories.filter {
            seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
    }

    /// Every usable `ggml-*.bin` in `directories`, most preferred first.
    ///
    /// Usable means a regular file (symlinks resolved, like the harness's `resolve()`) of
    /// at least `minimumModelBytes`; the same file reached through two directories or
    /// two links counts once. MicTest's own model directory wins, preferring full
    /// `ggml-large-v3.bin` before turbo there. Other directories retain their turbo,
    /// full-v3, then largest-first ordering. Silero VAD weights are not speech models.
    static func discoverModels(in directories: [URL],
                               preferredDirectory: URL = modelsDirectory) -> [URL] {
        struct Candidate {
            let url: URL
            let name: String
            let bytes: Int64
            let rank: Int
            let order: Int
            let appOwned: Bool
        }
        let preferredPath = preferredDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        var seen = Set<String>()
        var candidates: [Candidate] = []
        for (order, directory) in directories.enumerated() {
            let appOwned = directory.standardizedFileURL.resolvingSymlinksInPath().path == preferredPath
            guard let names = try? FileManager.default
                .contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted()
            where name.hasPrefix("ggml-") && name.hasSuffix(".bin")
                && !name.lowercased().hasPrefix("ggml-silero-") {
                let resolved = directory.appending(path: name).resolvingSymlinksInPath()
                guard let bytes = regularFileSize(at: resolved), bytes >= minimumModelBytes,
                      seen.insert(resolved.path).inserted else { continue }
                candidates.append(Candidate(url: resolved, name: name, bytes: bytes,
                                            rank: preferenceRank(of: name, preferFull: appOwned),
                                            order: order, appOwned: appOwned))
            }
        }
        candidates.sort { a, b in
            if a.appOwned != b.appOwned { return a.appOwned }
            if a.rank != b.rank { return a.rank < b.rank }
            if a.rank == 2, a.bytes != b.bytes { return a.bytes > b.bytes }
            if a.order != b.order { return a.order < b.order }
            return a.name < b.name
        }
        return candidates.map(\.url)
    }

    /// `discoverModels(in:)` over `modelSearchDirectories()`.
    static func discoverModels() -> [URL] { discoverModels(in: modelSearchDirectories()) }

    /// The model this machine should run, or `nil` when no usable weights exist.
    static func discoverModel() -> URL? { discoverModels().first }

    static func discoverVADModel() -> URL? {
        let url = modelsDirectory.appending(path: "ggml-silero-v6.2.0.bin")
        guard let bytes = regularFileSize(at: url), bytes > 0,
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The `whisper-server` this manager would launch, or `nil` when no pinned path
    /// holds an executable. The one lookup main.swift may use for its default-provider
    /// rule and its launch trace, so the two files cannot disagree about where the binary
    /// is allowed to live.
    nonisolated static func discoverBinary() -> String? {
        firstExecutable(in: binaryCandidates)
    }

    private nonisolated static func isOwnedRuntimeBinary(_ path: String) -> Bool {
        URL(fileURLWithPath: path).resolvingSymlinksInPath()
            == runtimeDirectory.appending(path: "bin/whisper-server").resolvingSymlinksInPath()
    }

    private nonisolated func launchVADModel(for binary: String) -> URL? {
        guard Self.isOwnedRuntimeBinary(binary), let vadModelURL,
              FileManager.default.isReadableFile(atPath: vadModelURL.path) else { return nil }
        return vadModelURL
    }

    /// `ggml-large-v3-turbo.bin` → `large-v3-turbo`, mirroring `_alias` in the harness.
    static func modelShortName(for url: URL) -> String {
        let name = url.lastPathComponent
        if name.hasPrefix("ggml-") && name.hasSuffix(".bin") {
            return String(name.dropFirst("ggml-".count).dropLast(".bin".count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Size of a regular file, or `nil` for anything else (missing, directory, socket).
    static func regularFileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private static func preferenceRank(of name: String, preferFull: Bool = false) -> Int {
        switch name.lowercased() {
        case "ggml-large-v3-turbo.bin": return preferFull ? 1 : 0
        case "ggml-large-v3.bin": return preferFull ? 0 : 1
        default: return 2
        }
    }

    // MARK: - Start implementation

    /// Single-flight start. EVERY launch path goes through here — `ensureReady` and the
    /// crash-restart alike. Launching around it would let a caller retrying a failed
    /// request and the crash-restart timer both reach `launch(on:)` for the same port,
    /// orphaning a child whose termination handler is then discarded as stale.
    private func startShared(
        progress: (@Sendable (WhisperServerProgress) -> Void)?
    ) async throws {
        if let existing = startTask {
            try await existing.value
            return
        }
        startTaskID &+= 1
        let id = startTaskID
        let task = Task<Void, Error> { [self] in try await performStart(progress: progress) }
        startTask = task
        do {
            try await task.value
            if startTaskID == id { startTask = nil }
        } catch {
            if startTaskID == id { startTask = nil }
            throw error
        }
    }

    private func performStart(
        progress: (@Sendable (WhisperServerProgress) -> Void)?
    ) async throws {
        try Task.checkCancellation()

        // Already ours and alive?
        if ownership == .owned, let running = child, running.isRunning, activePort != nil {
            return
        }
        // Reclaimed and still alive and answering? There is no termination handler for
        // an orphan, so its death is noticed here and in `isHealthy`, never pushed.
        if ownership == .reclaimed, let pid = reclaimedPid {
            if let port = activePort, await activeListenerIsTrusted(on: port),
               await Self.probe(port: port, session: probeSession) == .ready {
                return
            }
            log.note("[manager] reclaimed whisper-server pid \(pid) is gone — starting over")
            Self.removePidFile(pidFileURL)
            forgetServer()
        }
        if ownership == .adopted { forgetServer() }

        progress?(.selectingPort(base: preferredPort))
        let candidates = (0..<Self.portScanCount).map { preferredPort + $0 }

        // Pass 1: reclaim only our recorded orphan. Unknown listeners receive no HTTP
        // request, even if their executable happens to be one we could launch ourselves.
        if let recorded = Self.readPidFile(pidFileURL), candidates.contains(recorded.port),
           recordMatchesConfiguration(recorded),
           let pid = await Self.pinnedWhisperListener(on: recorded.port, candidates: executableCandidates),
           pid == recorded.pid,
           await Self.probe(port: recorded.port, session: probeSession) == .ready {
                guard !stopRequested, !startControl.withLock({ $0.vetoed }) else {
                    throw WhisperServerError.launchFailed("the start was stopped before reclaiming")
                }
                let candidate = recorded.port
                activePort = candidate
                launchedAt = Date()
                child = nil
                serverGeneration &+= 1
                ownership = .reclaimed
                reclaimedPid = pid
                ownedChildPid.withLock { $0 = pid }
                emergencyStopRequested.withLock { $0 = false }
                log.note("[manager] reclaimed whisper-server pid \(pid) on port"
                    + " \(candidate): launched by an earlier run of this app"
                    + " (matching pidfile PID and port) — stop() will end it")
                progress?(.adoptedExisting(port: candidate))
                return
        }

        // Pre-flight: fail with a precise reason rather than a timeout.
        guard let binaryPath = Self.firstExecutable(in: executableCandidates) else {
            throw WhisperServerError.binaryMissing(candidates: executableCandidates)
        }
        guard let modelURL else {
            let searched = Self.modelSearchDirectories().map(\.path).joined(separator: ", ")
            throw WhisperServerError.modelMissing(
                "no ggml-*.bin of at least \(Self.minimumModelBytes / 1_000_000) MB in"
                + " \(searched) — download weights into \(Self.modelsDirectory.path)"
                + " or point \(Self.modelDirectoryVariable) at the directory holding them")
        }
        guard FileManager.default.isReadableFile(atPath: modelURL.path) else {
            throw WhisperServerError.modelMissing("\(modelURL.path) is not readable")
        }

        // Pass 2: first candidate with nothing listening on it.
        guard let launchPort = candidates.first(where: { !Self.portIsOccupied($0) }) else {
            throw WhisperServerError.noFreePort(base: preferredPort, tried: candidates)
        }
        if launchPort != preferredPort {
            log.note("[manager] port \(preferredPort) is taken by a listener this app does not own;"
                + " using \(launchPort)")
        }

        try launch(binary: binaryPath, model: modelURL, on: launchPort)
        progress?(.launching(port: launchPort))
    }

    /// Spawn the child. Pipes are wired BEFORE `run()` so no output can ever fill an
    /// undrained kernel pipe buffer and wedge the child.
    ///
    /// Arguments: exactly `-m <model> --host 127.0.0.1 --port <port> -l <language>`. No
    /// `--convert` — the header says why — and no beam-size flag: the plan records
    /// `-bs 5` as measured (fixes `Python กับ JavaScript`, costs ~1.5x latency, and
    /// hallucinated Vietnamese on one clip that the size-sanity gate would have let
    /// through), and leaves it off for v1.
    private func launch(binary binaryPath: String, model modelURL: URL,
                        on launchPort: Int) throws {
        // No suspension point between here and `process.run()`, so actor isolation makes
        // this a last-moment check: a `stop()` that landed while we were probing must not
        // leave a child behind. `startControl.vetoed` checks for a stop that is still
        // queued behind this start (see the flag).
        guard !stopRequested else {
            throw WhisperServerError.launchFailed("stop() was requested while starting")
        }
        guard !startControl.withLock({ $0.vetoed }) else {
            throw WhisperServerError.launchFailed("the start was vetoed by a pending stop")
        }

        let workingDirectory = Self.ensureDirectory(scratchDirectory)
            ? scratchDirectory : FileManager.default.temporaryDirectory

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "-m", modelURL.path,
            "--host", "127.0.0.1",     // loopback only, never 0.0.0.0
            "--port", String(launchPort),
            "-l", language,
        ]
        if let vadModel = launchVADModel(for: binaryPath) {
            process.arguments?.append(contentsOf: ["--vad-model", vadModel.path])
        }
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.childEnvironment(temporaryDirectory: workingDirectory)
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        attachDrain(outPipe)
        attachDrain(errPipe)

        epoch &+= 1
        let launchEpoch = epoch
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let signalled = proc.terminationReason == .uncaughtSignal
            guard let self else { return }
            Task {
                await self.childDidExit(epoch: launchEpoch, status: status,
                                        uncaughtSignal: signalled)
            }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw WhisperServerError.launchFailed(error.localizedDescription)
        }

        child = process
        exitedEpoch = nil
        restartPending = false
        stdoutPipe = outPipe
        stderrPipe = errPipe
        ownership = .owned
        activePort = launchPort
        launchedAt = Date()
        serverGeneration &+= 1
        emergencyStopRequested.withLock { $0 = false }
        ownedChildPid.withLock { $0 = process.processIdentifier }
        writePidFile(pidFileURL, pid: process.processIdentifier, port: launchPort,
                     binary: binaryPath, model: modelURL)
        log.note("[manager] launched whisper-server pid \(process.processIdentifier)"
            + " on 127.0.0.1:\(launchPort) model=\(modelURL.lastPathComponent)"
            + " -l \(language)")
    }

    /// The child's environment, built from scratch: PATH pinned to the system directories
    /// (the server spawns nothing without `--convert`, so this is belt and braces), HOME,
    /// and a TMPDIR under the app's own scratch directory. Nothing is inherited — not
    /// `DYLD_*`, which could inject code into the process that receives the microphone,
    /// and not the shell exports a harness launch carries (see the header for the
    /// measurement that the Metal backend needs none of them).
    private static func childEnvironment(temporaryDirectory: URL) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": temporaryDirectory.path,
        ]
    }

    /// Continuously drain a child pipe into the ring buffer.
    ///
    /// An undrained pipe is a real deadlock: whisper.cpp writes several KB of backend and
    /// model banner on startup and a line per request after that (under the archive's
    /// `--convert` it was 30 lines per request). A 64 KB pipe buffer fills eventually
    /// either way, and a child blocked mid-write stops answering requests while `/health`
    /// keeps saying it is fine.
    private func attachDrain(_ pipe: Pipe) {
        let ring = log
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {                       // EOF
                handle.readabilityHandler = nil
                return
            }
            ring.append(chunk: String(decoding: data, as: UTF8.self))
        }
    }

    /// Detach the drains, but only after a final non-blocking read: the child's last
    /// lines are exactly the ones a startup failure needs to report, and the dispatch
    /// queue may not have delivered them yet.
    private func releasePipes() {
        drainRemaining(stdoutPipe)
        drainRemaining(stderrPipe)
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// Synchronously read whatever is still buffered, without ever blocking.
    ///
    /// `FileHandle.availableData` would block while the write end is open, so this goes to
    /// `read(2)` on a non-blocking fd and stops at EOF/EAGAIN. The readability handler is
    /// detached first; if it happens to be mid-callback a chunk may be split, which the
    /// ring buffer tolerates.
    private func drainRemaining(_ pipe: Pipe?) {
        guard let pipe else { return }
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }          // 0 = EOF, -1 = EAGAIN
            log.append(chunk: String(decoding: buffer[0..<count], as: UTF8.self))
        }
    }

    // MARK: - Readiness

    /// Poll `/health` until the server answers, bounded by `timeout`.
    private func waitUntilReady(
        timeout: TimeInterval,
        progress: (@Sendable (WhisperServerProgress) -> Void)?,
        expectedStopGeneration: UInt64? = nil
    ) async throws -> Int {
        let requestGeneration = expectedStopGeneration
            ?? startControl.withLock { $0.stopGeneration }
        try validateReadinessRequest(requestGeneration)
        guard let initialPort = activePort else {
            throw WhisperServerError.launchFailed("waitUntilReady called before a start")
        }
        let began = launchedAt ?? Date()
        let deadline = Date().addingTimeInterval(timeout)
        var announced = Date.distantPast
        // Only an owned child can die on us; an adopted server is not ours to watch.
        let watchEpoch = (ownership == .owned) ? epoch : Int.min

        while true {
            try validateReadinessRequest(requestGeneration)

            // A restart may have moved us to a different port.
            let port = activePort ?? initialPort
            let trusted = await activeListenerIsTrusted(on: port)
            try validateReadinessRequest(requestGeneration)
            let ready: Bool
            if trusted {
                ready = await Self.probe(port: port, session: probeSession) == .ready
                try validateReadinessRequest(requestGeneration)
            } else {
                ready = false
            }
            if ready {
                let elapsed = Date().timeIntervalSince(began)
                restartAttempts = 0
                log.note("[manager] ready on port \(port) after"
                    + " \(String(format: "%.2f", elapsed)) s")
                progress?(.ready(port: port, elapsed: elapsed))
                return port
            }

            // Liveness. Two shapes: the termination handler already reaped the child
            // (`exitedEpoch`), or it has not run yet but the process is gone. Either way,
            // keep waiting only while a restart is inbound.
            if let dead = exitedEpoch, dead == watchEpoch, !restartPending {
                throw WhisperServerError.exitedDuringStartup(status: exitedStatus,
                                                             log: log.tailSummary())
            }
            if ownership == .owned, let child, !child.isRunning {
                let status = child.terminationStatus
                releasePipes()   // capture the child's dying words before quoting them
                throw WhisperServerError.exitedDuringStartup(status: status,
                                                             log: log.tailSummary())
            }

            if Date() >= deadline {
                throw WhisperServerError.readinessTimeout(seconds: timeout,
                                                          log: log.tailSummary())
            }

            if Date().timeIntervalSince(announced) >= 0.5 {
                announced = Date()
                progress?(.loadingModel(elapsed: Date().timeIntervalSince(began)))
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    // MARK: - Crash handling

    private func childDidExit(epoch exitEpoch: Int, status: Int32, uncaughtSignal: Bool) {
        // Stale handler from a process we already replaced or stopped.
        guard exitEpoch == epoch else { return }

        let how = uncaughtSignal ? "signal \(status)" : "status \(status)"
        log.note("[manager] whisper-server exited (\(how))")
        exitedEpoch = exitEpoch
        exitedStatus = status
        ownedChildPid.withLock { $0 = nil }
        Self.removePidFile(pidFileURL)
        child = nil
        ownership = .none
        let deadPort = activePort
        activePort = nil
        releasePipes()

        let emergency = emergencyStopRequested.withLock { $0 }
        guard !stopRequested, !emergency else { return }
        guard restartAttempts < Self.maxRestartAttempts else {
            log.note("[manager] restart limit (\(Self.maxRestartAttempts)) reached"
                + " — not restarting")
            return
        }
        restartAttempts += 1
        restartPending = true
        let attempt = restartAttempts
        let backoff = min(4.0, 0.5 * pow(2.0, Double(attempt - 1)))  // 0.5 s, 1 s, 2 s
        log.note("[manager] restart \(attempt)/\(Self.maxRestartAttempts) on port"
            + " \(deadPort.map(String.init) ?? "?") in \(backoff) s")

        restartTask?.cancel()
        restartTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(backoff))
            await self.attemptRestart()
        }
    }

    private func attemptRestart() async {
        guard !stopRequested, ownership == .none, child == nil else { return }
        do {
            try await startShared(progress: nil)
            _ = try await waitUntilReady(timeout: 60, progress: nil)
        } catch {
            restartPending = false
            log.note("[manager] restart failed: \(error)")
        }
    }

    // MARK: - Small helpers

    private func forgetServer() {
        if ownership == .reclaimed { ownedChildPid.withLock { $0 = nil } }
        reclaimedPid = nil
        ownership = .none
        activePort = nil
        launchedAt = nil
        releasePipes()
    }

    private func waitForExit(of process: Process, upTo seconds: Double) async {
        var waited = 0.0
        while process.isRunning && waited < seconds {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
    }

    /// `waitForExit(of:upTo:)` for a reclaimed pid: `kill(pid, 0)` succeeds while the
    /// process exists (ESRCH once launchd has reaped it).
    private func waitForExit(ofPid pid: pid_t, upTo seconds: Double) async {
        var waited = 0.0
        while kill(pid, 0) == 0 && waited < seconds {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
    }

    // MARK: - Pidfile

    private struct PidRecord: Codable, Sendable {
        let pid: pid_t
        let port: Int
        let binaryPath: String
        let modelPath: String
        let language: String
        let vadModelPath: String?
    }

    /// A pidfile must prove the configuration as well as ownership. Otherwise a
    /// full-v3 request could reclaim this app's older turbo-only server after an upgrade.
    private nonisolated func recordMatchesConfiguration(_ record: PidRecord) -> Bool {
        guard let binary = Self.firstExecutable(in: executableCandidates), let modelURL else { return false }
        return record.binaryPath == URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
            && record.modelPath == modelURL.resolvingSymlinksInPath().path
            && record.language == language
            && record.vadModelPath == launchVADModel(for: binary)?.resolvingSymlinksInPath().path
    }

    /// Owner-readable JSON, written atomically. A failed write is logged; the Process
    /// remains owned by this run, but a later launch will not reclaim it without proof.
    private nonisolated func writePidFile(_ url: URL, pid: pid_t, port: Int,
                                         binary: String, model: URL) {
        do {
            let record = PidRecord(pid: pid, port: port,
                                   binaryPath: URL(fileURLWithPath: binary).resolvingSymlinksInPath().path,
                                   modelPath: model.resolvingSymlinksInPath().path,
                                   language: language,
                                   vadModelPath: launchVADModel(for: binary)?.resolvingSymlinksInPath().path)
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
        } catch {
            log.note("[manager] could not write pidfile \(url.path): \(error)")
        }
    }

    /// Old two-field records are deliberately insufficient: they name no model or VAD.
    private nonisolated static func readPidFile(_ url: URL) -> PidRecord? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(PidRecord.self, from: data),
              record.pid > 0, (1...65535).contains(record.port) else { return nil }
        return record
    }

    private nonisolated static func removePidFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// `kill(2)` the child's whole process group, falling back to the pid alone if the
    /// group signal is refused (a future Foundation that stops making the child a group
    /// leader). The `pid > 0` guard is load-bearing: `kill(-0, …)` and `kill(-1, …)`
    /// address every process this user owns.
    private nonisolated static func send(_ sig: Int32, toGroupOf pid: pid_t) {
        guard pid > 0 else { return }
        if kill(-pid, sig) != 0 { _ = kill(pid, sig) }
    }

    private nonisolated static func inferenceURL(port: Int) -> URL {
        // Force-unwrap is safe: the only interpolated value is an Int.
        URL(string: "http://127.0.0.1:\(port)/inference")!
    }

    /// Is the process listening on `127.0.0.1:port` one of `binaryCandidates`?
    ///
    /// Two steps, both off the actor: `lsof -nP -iTCP:<port> -sTCP:LISTEN -Fp` names the
    /// pid (measured 2026-09-03: 39 ms, exit 1 with no output when nothing listens), and
    /// `proc_pidpath` names its executable. Both sides are compared with symlinks resolved
    /// because `/opt/homebrew/bin/whisper-server` is a link into the Cellar and the kernel
    /// reports the real path. `false` on any doubt: an unreadable pid, a path outside the
    /// pinned list, or an `lsof` that could not run — the outcome of doubt is "do not send
    /// audio here", never "probably fine".
    nonisolated static func listenerIsPinnedWhisper(on port: Int) async -> Bool {
        await pinnedWhisperListener(on: port) != nil
    }

    /// `listenerIsPinnedWhisper(on:)`, returning the listener's pid when it IS one of
    /// the pinned executables — Pass 1 compares that pid with the pidfile to tell an
    /// orphan of this app from a server someone else started.
    nonisolated static func pinnedWhisperListener(on port: Int,
                                                 candidates: [String] = binaryCandidates) async -> pid_t? {
        let pid = await Task.detached(priority: .utility) {
            Self.listeningPID(on: port)
        }.value
        guard let pid, let path = Self.executablePath(of: pid) else { return nil }
        let actual = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let pinned = candidates.contains {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == actual
        }
        return pinned ? pid : nil
    }

    /// Pid of the process listening on `127.0.0.1:port`, via `/usr/sbin/lsof`. Blocks for
    /// the spawn (tens of milliseconds) — call it from a detached task, not the actor.
    private nonisolated static func listeningPID(on port: Int) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP@127.0.0.1:\(port)", "-sTCP:LISTEN", "-Fp"]
        process.environment = [:]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // `-Fp` prints one `p<pid>` line per process. Several processes can hold one
        // listening port only via inheritance; the first is the parent, which is the
        // one whose executable matters.
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        where line.hasPrefix("p") {
            if let pid = pid_t(line.dropFirst()) { return pid }
        }
        return nil
    }

    /// `proc_pidpath(2)`: the executable behind `pid`, or `nil` if the kernel refuses.
    private nonisolated static func executablePath(of pid: pid_t) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` is `4 * MAXPATHLEN` in <sys/proc_info.h>; the macro
        // itself does not import into Swift, the two constants it is built from do.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    private nonisolated static func firstExecutable(in candidates: [String]) -> String? {
        candidates.first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    @discardableResult
    private nonisolated static func ensureDirectory(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    // MARK: - Probes

    /// Is ANYTHING accepting connections on 127.0.0.1:port?
    ///
    /// Non-blocking connect + bounded `poll`, so a black-hole listener cannot stall
    /// startup. Only used during port selection.
    nonisolated static func portIsOccupied(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }   // ECONNREFUSED ⇒ free

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 250) > 0 else { return false }

        var sockErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &len) == 0 else { return false }
        return sockErr == 0
    }

    /// Does the listener on `port` identify itself as whisper.cpp, and is it ready?
    ///
    /// Identity is the `Server: whisper.cpp` header, set as a default header on every
    /// response (server.cpp v1.8.4 line 718) — including the 404 an older build without a
    /// `/health` route would return, which then still counts as ready, because every build
    /// binds only after its model is loaded. A listener without the header is `.absent`:
    /// some other service on the port is the case this exists to distinguish, and the
    /// outcome for it is "skip this port", not "wait for it".
    nonisolated static func probe(port: Int, session: URLSession) async -> Probe {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return .absent }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  let server = http.value(forHTTPHeaderField: "Server"),
                  server.localizedCaseInsensitiveContains("whisper") else { return .absent }
            return http.statusCode == 503 ? .loading : .ready
        } catch {
            return .absent
        }
    }

    // MARK: - Multipart

    /// Hand-rolled `multipart/form-data` body for `POST /inference`, for `warmUp()`.
    ///
    /// A deliberate copy of `WhisperClient.multipartBody(wav:filename:language:)` rather
    /// than a call to it: this file must compile on its own while that file is being
    /// edited, and the wire format is small. Every detail is load-bearing for
    /// cpp-httplib's strict parser: CRLF everywhere (bare LF parses as one malformed part
    /// and the server answers an empty `text` with HTTP 200), a blank line after each
    /// part's headers, a CRLF after the raw file bytes, and a closing `--boundary--`.
    static func multipartBody(wav: Data, filename: String,
                              language: String) -> (data: Data, boundary: String) {
        let stamp = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let boundary = "----MicTestWarmUp\(stamp)"
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
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\""
            + crlf)
        append("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(wav)
        append(crlf)

        appendField("language", language)
        appendField("response_format", "json")

        append("--\(boundary)--\(crlf)")
        return (body, boundary)
    }
}
