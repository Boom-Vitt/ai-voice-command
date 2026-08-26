import Foundation
import Synchronization

// MARK: - Errors

/// Everything that can go wrong owning a `whisper-server` child process.
///
/// `WhisperServerManager` throws these; `LocalTranscriber` converts them into
/// a `TranscriptionResult` with a short, actionable `error` string (the
/// `Transcriber` contract forbids throwing).
enum WhisperServerError: Error, CustomStringConvertible, Sendable {
    /// The `whisper-server` binary was not found or is not executable.
    case binaryMissing(String)
    /// The ggml model file is absent or unreadable.
    case modelMissing(String)
    /// Every candidate port is occupied by something that is not whisper-server.
    case noFreePort(base: Int, tried: [Int])
    /// `Process.run()` itself failed.
    case launchFailed(String)
    /// The child died while loading the model (bad model, OOM, killed).
    case exitedDuringStartup(status: Int32, log: String)
    /// The port never answered within the allotted time.
    case readinessTimeout(seconds: Double, log: String)
    /// A restart loop hit its cap.
    case restartLimitReached(attempts: Int, log: String)

    var description: String {
        switch self {
        case .binaryMissing(let path):
            return "whisper-server not found at \(path) — install whisper.cpp (brew install whisper-cpp)"
        case .modelMissing(let path):
            return "whisper model not found at \(path)"
        case .noFreePort(let base, let tried):
            return "ports \(tried.map(String.init).joined(separator: ", ")) are in use by something that is not whisper-server (base port \(base))"
        case .launchFailed(let reason):
            return "could not launch whisper-server: \(reason)"
        case .exitedDuringStartup(let status, let log):
            return "whisper-server exited (status \(status)) while loading the model. \(log)"
        case .readinessTimeout(let seconds, let log):
            return "whisper-server did not answer within \(Int(seconds))s. \(log)"
        case .restartLimitReached(let attempts, let log):
            return "whisper-server crashed \(attempts) times, giving up. \(log)"
        }
    }
}

// MARK: - Progress

/// Coarse startup progress, so the UI can say "loading model…" during the
/// multi-second load of a 3 GB ggml file.
enum WhisperServerProgress: Sendable, Equatable {
    /// Deciding which port to use.
    case selectingPort(base: Int)
    /// A healthy whisper-server was already listening; we adopted it and will
    /// never kill it.
    case adoptedExisting(port: Int)
    /// Child process spawned; the model load starts now.
    case launching(port: Int)
    /// Still waiting for the port to answer. `elapsed` is seconds since launch.
    case loadingModel(elapsed: TimeInterval)
    /// Server answered a health probe.
    case ready(port: Int, elapsed: TimeInterval)
}

// MARK: - Log ring

/// A small, bounded, thread-safe line buffer for child stdout/stderr.
///
/// `FileHandle.readabilityHandler` fires on a private Dispatch queue, so the
/// sink it writes into must be `Sendable` and independently synchronised —
/// it cannot touch actor-isolated state. `Mutex` (Swift 6 `Synchronization`)
/// gives that without an `@unchecked` escape hatch.
final class WhisperLogRing: Sendable {
    private let capacity: Int
    private let lines = Mutex<[String]>([])

    init(capacity: Int = 200) {
        self.capacity = max(8, capacity)
    }

    /// Appends a raw chunk of child output, splitting it into lines.
    func append(chunk: String) {
        let incoming = chunk
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return }
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

    /// The most recent lines as one single-line string, for embedding in errors.
    func tailSummary(_ count: Int = 6) -> String {
        let t = tail(count)
        return t.isEmpty ? "(no output captured)" : "last output: " + t.joined(separator: " | ")
    }
}

// MARK: - Manager

/// Owns the lifecycle of a resident `whisper-server` child process.
///
/// **Why an `actor` and not a `@MainActor` class:** starting the server blocks
/// on a 3.1 GB model load (measured ~2 s warm, longer cold) and readiness
/// polling runs for seconds. None of that state is UI state, and the main
/// thread must stay free to drive the HUD while it happens. An actor gives
/// serialised access to the process handle, ownership flag and restart counter
/// from any concurrency domain without ever hopping to the main thread. The
/// UI observes progress through the `@Sendable` progress callback, which it
/// can bounce onto `@MainActor` itself.
///
/// Keeping this process resident is the whole point of the module: a cold
/// `whisper-cli` run costs 4.08 s, of which 2.04 s is model load; a warm
/// server answers a 3.5 s utterance in ~0.9 s.
actor WhisperServerManager {

    /// Who started the process we are talking to.
    enum Ownership: Sendable, Equatable {
        /// Nothing running / nothing adopted.
        case none
        /// A whisper-server was already listening before us. Never kill it.
        case adopted
        /// We spawned it, so we may terminate and restart it.
        case owned
    }

    /// Process-wide instance used by the app.
    static let shared = WhisperServerManager()

    // Configuration (immutable for the life of the manager).
    private let binaryPath: String
    private let modelPath: String
    private let basePort: Int
    private let launchLanguage: String
    private let portScanCount: Int
    private let maxRestartAttempts: Int

    // Mutable, actor-isolated state.
    private var child: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var ownership: Ownership = .none
    private var activePort: Int?
    /// Incremented on every launch. A termination handler whose epoch is stale
    /// belongs to a process we already replaced and must be ignored, otherwise
    /// a late exit from generation N triggers a spurious restart of N+1.
    private var epoch: Int = 0
    private var restartAttempts: Int = 0
    /// Exit record for the most recently reaped child. `waitUntilReady` needs
    /// this because the termination handler clears `child` before the waiter
    /// gets a chance to observe `!isRunning` — without it a child that dies
    /// during the model load looks identical to one that is merely slow.
    private var exitedEpoch: Int?
    private var exitedStatus: Int32 = 0
    /// A crash restart has been armed and has not yet produced a new child.
    private var restartPending: Bool = false
    private var stopRequested: Bool = false
    private var startTask: Task<Void, Error>?
    /// Identifies the in-flight start, so a completing start never clears a
    /// *newer* one that replaced it.
    private var startTaskID: Int = 0
    private var restartTask: Task<Void, Never>?
    private var launchedAt: Date?

    /// Diagnostics buffer, drained continuously from the child's pipes.
    let log = WhisperLogRing(capacity: 200)

    private let probeSession: URLSession

    /// - Parameters:
    ///   - binaryPath: `whisper-server` executable. Defaults to the first of
    ///     `/opt/homebrew/bin`, `/usr/local/bin` that exists.
    ///   - modelPath: ggml model. Defaults to `Settings.shared.modelPath`.
    ///   - basePort: first port to try. Defaults to `Settings.shared.whisperPort` (8177).
    ///   - language: `-l` flag for the child. Defaults to `Settings.shared.language`.
    ///   - portScanCount: how many consecutive ports to consider (default 4).
    ///   - maxRestartAttempts: crash-restart cap (default 3).
    init(binaryPath: String? = nil,
         modelPath: String? = nil,
         basePort: Int? = nil,
         language: String? = nil,
         portScanCount: Int = 4,
         maxRestartAttempts: Int = 3) {
        self.binaryPath = binaryPath ?? Self.defaultBinaryPath()
        self.modelPath = modelPath ?? Settings.shared.modelPath
        self.basePort = basePort ?? Settings.shared.whisperPort
        self.launchLanguage = language ?? Settings.shared.language
        self.portScanCount = max(1, portScanCount)
        self.maxRestartAttempts = max(0, maxRestartAttempts)

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 3
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.probeSession = URLSession(configuration: cfg)
    }

    // MARK: Public API

    /// The port we are currently bound to (or adopted), if any.
    var port: Int? { activePort }

    /// Whether the running server is ours (`owned`), someone else's
    /// (`adopted`), or absent (`none`).
    var currentOwnership: Ownership { ownership }

    /// `POST` target for transcription, once a port is known.
    var inferenceURL: URL? {
        activePort.flatMap { URL(string: "http://127.0.0.1:\($0)/inference") }
    }

    /// Recent child output, for diagnostics.
    func recentLog(_ count: Int = 20) -> [String] { log.tail(count) }

    /// Launch (or adopt) a whisper-server bound to loopback only.
    ///
    /// Idempotent in three ways:
    /// * a healthy server we already own is left alone;
    /// * a healthy whisper-server already listening on a candidate port is
    ///   **adopted** — no second child is spawned, and `stop()` will not kill it;
    /// * concurrent callers share one in-flight start.
    ///
    /// Returns as soon as the child is spawned; call ``waitUntilReady(timeout:progress:)``
    /// to wait for the model to finish loading.
    func start(progress: (@Sendable (WhisperServerProgress) -> Void)? = nil) async throws {
        stopRequested = false      // an explicit start cancels a previous stop
        try await startShared(progress: progress)
    }

    /// Single-flight start. **Every** launch path goes through here — the
    /// public `start()` and the crash-restart alike. Launching around it would
    /// let a caller retrying a failed request and the crash-restart timer both
    /// reach `launch()` for the same port, orphaning a 3.1 GB child whose
    /// termination handler is then discarded as stale.
    private func startShared(progress: (@Sendable (WhisperServerProgress) -> Void)?) async throws {
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

    /// Poll the port until the server answers, bounded by `timeout`.
    ///
    /// Fails fast (rather than burning the whole timeout) if a child we own
    /// dies during the model load — a bad model path or an OOM shows up as an
    /// exit, not as silence.
    ///
    /// - Parameters:
    ///   - timeout: seconds to wait. 60 s is generous for a cold 3.1 GB load.
    ///   - progress: called roughly twice a second with `.loadingModel`.
    @discardableResult
    func waitUntilReady(timeout: TimeInterval = 60,
                        progress: (@Sendable (WhisperServerProgress) -> Void)? = nil) async throws -> Int {
        guard let port = activePort else {
            throw WhisperServerError.launchFailed("waitUntilReady called before start()")
        }
        let began = launchedAt ?? Date()
        let deadline = Date().addingTimeInterval(timeout)
        var announced = Date.distantPast
        // Only an owned child can die on us; an adopted server is not ours to watch.
        let watchEpoch = (ownership == .owned) ? epoch : Int.min

        while true {
            try Task.checkCancellation()

            // A restart may have moved us to a different port.
            let port = activePort ?? port
            if await Self.probeIsWhisper(port: port, session: probeSession) {
                let elapsed = Date().timeIntervalSince(began)
                restartAttempts = 0
                log.note("[manager] ready on port \(port) after \(String(format: "%.2f", elapsed))s")
                progress?(.ready(port: port, elapsed: elapsed))
                return port
            }

            // Liveness. Two shapes: the termination handler already reaped the
            // child (`exitedEpoch`), or it has not run yet but the process is
            // gone. Either way, keep waiting only while a restart is inbound.
            if let dead = exitedEpoch, dead == watchEpoch, !restartPending {
                throw WhisperServerError.exitedDuringStartup(status: exitedStatus, log: log.tailSummary())
            }
            if ownership == .owned, let child, !child.isRunning {
                let status = child.terminationStatus
                releasePipes()   // capture the child's dying words before quoting them
                throw WhisperServerError.exitedDuringStartup(status: status, log: log.tailSummary())
            }

            if Date() >= deadline {
                throw WhisperServerError.readinessTimeout(seconds: timeout, log: log.tailSummary())
            }

            if Date().timeIntervalSince(announced) >= 0.5 {
                announced = Date()
                progress?(.loadingModel(elapsed: Date().timeIntervalSince(began)))
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Convenience used by `LocalTranscriber`: start if needed, wait for
    /// readiness, and hand back the `/inference` URL.
    @discardableResult
    func ensureReady(timeout: TimeInterval = 60,
                     progress: (@Sendable (WhisperServerProgress) -> Void)? = nil) async throws -> URL {
        if let port = activePort, await Self.probeIsWhisper(port: port, session: probeSession) {
            return URL(string: "http://127.0.0.1:\(port)/inference")!
        }
        try await start(progress: progress)
        let port = try await waitUntilReady(timeout: timeout, progress: progress)
        return URL(string: "http://127.0.0.1:\(port)/inference")!
    }

    /// True when a server is listening on our port and identifies as whisper.cpp.
    ///
    /// Note the honest limit: whisper.cpp's HTTP surface does not report which
    /// model is loaded, so for an *adopted* server this proves liveness, not
    /// that `ggml-large-v3` in particular is resident.
    func isHealthy() async -> Bool {
        guard let port = activePort else { return false }
        if ownership == .owned, let child, !child.isRunning { return false }
        return await Self.probeIsWhisper(port: port, session: probeSession)
    }

    /// Terminate the child **only if we started it**.
    ///
    /// A server that was already running when we arrived (`.adopted`) is left
    /// untouched; we merely forget about it.
    func stop() async {
        stopRequested = true
        restartPending = false
        startTask?.cancel(); startTask = nil
        restartTask?.cancel(); restartTask = nil

        guard ownership == .owned, let child else {
            if ownership == .adopted {
                log.note("[manager] stop(): server on port \(activePort.map(String.init) ?? "?") was already running before us — leaving it alive")
            }
            ownership = .none
            activePort = nil
            self.child = nil
            releasePipes()
            return
        }

        epoch &+= 1 // invalidate the termination handler: this exit is expected
        log.note("[manager] stop(): terminating our whisper-server (pid \(child.processIdentifier))")
        if child.isRunning { child.terminate() }

        // Bounded wait. Never call waitUntilExit() — it would block a
        // cooperative thread for seconds.
        var waited: TimeInterval = 0
        while child.isRunning && waited < 3.0 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        if child.isRunning {
            log.note("[manager] SIGTERM ignored after 3s, sending SIGKILL")
            kill(child.processIdentifier, SIGKILL)
            waited = 0
            while child.isRunning && waited < 1.0 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 0.05
            }
        }

        self.child = nil
        ownership = .none
        activePort = nil
        launchedAt = nil
        releasePipes()
    }

    /// One-line snapshot for logs and error reports.
    func diagnostics() -> String {
        let pid = child?.processIdentifier.description ?? "-"
        return "port=\(activePort.map(String.init) ?? "-") ownership=\(ownership) pid=\(pid) restarts=\(restartAttempts) binary=\(binaryPath) model=\(modelPath)"
    }

    // MARK: Start implementation

    private func performStart(progress: (@Sendable (WhisperServerProgress) -> Void)?) async throws {
        try Task.checkCancellation()

        // Already ours and alive?
        if ownership == .owned, let running = child, running.isRunning, activePort != nil {
            return
        }
        // Already adopted and still answering?
        if ownership == .adopted, let port = activePort,
           await Self.probeIsWhisper(port: port, session: probeSession) {
            progress?(.adoptedExisting(port: port))
            return
        }

        progress?(.selectingPort(base: basePort))
        let candidates = (0..<portScanCount).map { basePort + $0 }

        // Pass 1: adopt any candidate that is already a healthy whisper-server.
        for candidate in candidates {
            if await Self.probeIsWhisper(port: candidate, session: probeSession) {
                ownership = .adopted
                activePort = candidate
                launchedAt = Date()
                child = nil
                log.note("[manager] adopted pre-existing whisper-server on port \(candidate) (we will not stop it)")
                progress?(.adoptedExisting(port: candidate))
                return
            }
        }

        // Pre-flight: fail with a precise reason rather than a timeout.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: binaryPath, isDirectory: &isDir), !isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw WhisperServerError.binaryMissing(binaryPath)
        }
        guard FileManager.default.isReadableFile(atPath: modelPath) else {
            throw WhisperServerError.modelMissing(modelPath)
        }

        // Pass 2: first candidate with nothing listening on it.
        var chosen: Int?
        for candidate in candidates where !Self.portIsOccupied(candidate) {
            chosen = candidate
            break
        }
        guard let launchPort = chosen else {
            throw WhisperServerError.noFreePort(base: basePort, tried: candidates)
        }
        if launchPort != basePort {
            log.note("[manager] port \(basePort) is taken by a non-whisper process; using \(launchPort)")
        }

        try launch(on: launchPort)
        progress?(.launching(port: launchPort))
    }

    /// Spawn the child. Pipes are wired **before** `run()` so no output can
    /// ever fill an undrained kernel pipe buffer and wedge the child.
    private func launch(on launchPort: Int) throws {
        // No suspension point between here and `process.run()`, so actor
        // isolation makes this an airtight last-moment check: a `stop()` that
        // landed while we were probing must not leave a child behind.
        guard !stopRequested else {
            throw WhisperServerError.launchFailed("stop() was requested while the server was starting")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",     // loopback only, never 0.0.0.0
            "--port", String(launchPort),
            "-l", launchLanguage,
        ]
        process.environment = ProcessInfo.processInfo.environment
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
            let reason = proc.terminationReason
            guard let self else { return }
            Task { await self.childDidExit(epoch: launchEpoch, status: status, uncaughtSignal: reason == .uncaughtSignal) }
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
        log.note("[manager] launched whisper-server pid \(process.processIdentifier) on 127.0.0.1:\(launchPort) model=\((modelPath as NSString).lastPathComponent)")
    }

    /// Continuously drain a child pipe into the ring buffer.
    ///
    /// An undrained pipe is a real deadlock: whisper.cpp writes several KB of
    /// backend/model banner on startup, which is enough to fill the 64 KB pipe
    /// buffer over a long session and block the child mid-write.
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

    /// Detach the drains, but only after a final non-blocking read: the child's
    /// last lines are exactly the ones a startup failure needs to report, and
    /// the dispatch queue may not have delivered them yet.
    private func releasePipes() {
        drainRemaining(stdoutPipe)
        drainRemaining(stderrPipe)
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// Synchronously read whatever is still buffered, without ever blocking.
    ///
    /// `FileHandle.availableData` would block while the write end is open, so
    /// this goes to `read(2)` on a non-blocking fd and stops at EOF/EAGAIN. The
    /// readability handler is detached first; if it happens to be mid-callback
    /// a chunk may be split, which the ring buffer tolerates.
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

    // MARK: Crash handling

    private func childDidExit(epoch exitEpoch: Int, status: Int32, uncaughtSignal: Bool) async {
        // Stale handler from a process we already replaced or killed.
        guard exitEpoch == epoch else { return }

        let how = uncaughtSignal ? "signal \(status)" : "status \(status)"
        log.note("[manager] whisper-server exited (\(how))")
        exitedEpoch = exitEpoch
        exitedStatus = status
        child = nil
        ownership = .none
        let deadPort = activePort
        activePort = nil
        releasePipes()

        guard !stopRequested else { return }
        guard restartAttempts < maxRestartAttempts else {
            log.note("[manager] restart limit (\(maxRestartAttempts)) reached — not restarting")
            return
        }
        restartAttempts += 1
        restartPending = true
        let attempt = restartAttempts
        let backoff = min(4.0, 0.5 * pow(2.0, Double(attempt - 1)))  // 0.5s, 1s, 2s
        log.note("[manager] restart \(attempt)/\(maxRestartAttempts) on port \(deadPort.map(String.init) ?? "?") in \(backoff)s")

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

    // MARK: Probes

    /// Is *anything* accepting connections on 127.0.0.1:port?
    ///
    /// Non-blocking connect + bounded `poll`, so a black-hole listener cannot
    /// stall startup. Only used during port selection.
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

    /// Does the listener on `port` identify itself as whisper.cpp?
    ///
    /// whisper.cpp's httplib server stamps `Server: whisper.cpp` on **every**
    /// response including 404s, which makes `GET /` a reliable identity probe.
    /// Because the port is only bound after the model finishes loading, a
    /// positive probe also means "model resident".
    nonisolated static func probeIsWhisper(port: Int, session: URLSession) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
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

    private nonisolated static func defaultBinaryPath() -> String {
        let candidates = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }
}
