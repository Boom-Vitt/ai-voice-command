import Darwin
import Foundation

/// A standalone fake HTTP server and isolated manager checks. It never discovers real
/// weights, talks to the app's ports, or signals a process it did not create.
@main
struct IsolationTest {
    enum Failure: Error { case failed(String) }

    /// Stops a fast-path health probe at a known suspension point, rather than
    /// guessing whether a real HTTP response raced with process termination.
    actor ProbeGate {
        private var entered = false
        private var entryWaiter: CheckedContinuation<Void, Never>?
        private var resultWaiter: CheckedContinuation<WhisperServerManager.Probe, Never>?

        func probe() async -> WhisperServerManager.Probe {
            await withCheckedContinuation { continuation in
                resultWaiter = continuation
                entered = true
                entryWaiter?.resume()
                entryWaiter = nil
            }
        }

        func waitForEntry() async {
            if entered { return }
            await withCheckedContinuation { entryWaiter = $0 }
        }

        func release(_ result: WhisperServerManager.Probe) {
            precondition(resultWaiter != nil)
            resultWaiter?.resume(returning: result)
            resultWaiter = nil
        }
    }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.failed(label) }
        print("PASS \(label)")
    }

    static func requestLog(model: URL, port: Int) -> URL {
        model.deletingLastPathComponent().appending(path: "requests-\(port).log")
    }

    static func fakeServer(port: Int, model: URL) throws {
        _ = signal(SIGPIPE, SIG_IGN)
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw Failure.failed("socket") }
        defer { close(socketFD) }
        var reuse: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 16) == 0 else { throw Failure.failed("bind/listen \(port)") }
        while true {
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(client, &buffer, buffer.count, 0)
            if count > 0 {
                let line = String(decoding: buffer.prefix(count), as: UTF8.self)
                    .components(separatedBy: "\r\n").first ?? ""
                let log = requestLog(model: model, port: port)
                if !FileManager.default.fileExists(atPath: log.path) {
                    _ = FileManager.default.createFile(atPath: log.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: log)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
                try handle.close()
                let body = "{\"status\":\"ok\"}"
                let reply = "HTTP/1.1 200 OK\r\nServer: whisper.cpp\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = reply.withCString { send(client, $0, reply.utf8.count, 0) }
            }
            close(client)
        }
    }

    static func unusedBasePort() throws -> Int {
        for _ in 0..<100 {
            let base = Int.random(in: 30_000...55_000)
            if (0..<WhisperServerManager.portScanCount).allSatisfy({
                !WhisperServerManager.portIsOccupied(base + $0)
            }) { return base }
        }
        throw Failure.failed("no isolated port range")
    }

    static func startFixture(binary: URL, model: URL, port: Int) async throws -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-m", model.path, "--port", String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<60 {
            if WhisperServerManager.portIsOccupied(port) { return process }
            guard process.isRunning else { throw Failure.failed("fixture exited") }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        throw Failure.failed("fixture did not bind")
    }

    static func stopFixture(_ process: Process) {
        if process.isRunning { process.terminate() }
    }

    static func stopFixtureAndWait(_ process: Process) async throws {
        stopFixture(process)
        for _ in 0..<60 {
            if !process.isRunning { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        throw Failure.failed("fixture ignored termination")
    }

    static func writeRecord(scratch: URL, pid: pid_t, port: Int,
                            binary: URL, model: URL, language: String = "th") throws {
        let record: [String: Any] = [
            "pid": pid, "port": port, "binaryPath": binary.resolvingSymlinksInPath().path,
            "modelPath": model.resolvingSymlinksInPath().path, "language": language,
        ]
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: scratch.appending(path: "whisper-server.pid"), options: .atomic)
    }

    static func runCase(_ kind: String, root: URL, binary: URL, unpinnedBinary: URL, model: URL) async throws {
        let scratch = root.appending(path: kind, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let base = try unusedBasePort()
        let actualBinary = kind == "unpinned" ? unpinnedBinary : binary
        let fixture = try await startFixture(binary: actualBinary, model: model, port: base)
        defer { stopFixture(fixture) }
        switch kind {
        case "wrong-port":
            try writeRecord(scratch: scratch, pid: fixture.processIdentifier, port: base + 1,
                            binary: binary, model: model)
        case "wrong-pid":
            try writeRecord(scratch: scratch, pid: getpid(), port: base, binary: binary, model: model)
        case "wrong-model":
            try writeRecord(scratch: scratch, pid: fixture.processIdentifier, port: base,
                            binary: binary, model: model.appendingPathExtension("other"))
        case "unpinned", "reclaim":
            try writeRecord(scratch: scratch, pid: fixture.processIdentifier, port: base,
                            binary: binary, model: model)
        case "legacy-record":
            try Data("\(fixture.processIdentifier) \(base)\n".utf8)
                .write(to: scratch.appending(path: "whisper-server.pid"))
        default: break
        }
        let manager = WhisperServerManager(modelURL: model, preferredPort: base,
                                           scratchDirectory: scratch,
                                           binaryCandidates: [binary.path], vadModelURL: model)
        do {
            let url = try await manager.ensureReady(timeout: 5)
            let ownership = await manager.currentOwnership
            if kind == "reclaim" {
                try check(url.port == base && ownership == .reclaimed,
                          "matching PID, port, executable and configuration reclaimed")
                try check(await manager.isHealthy(), "reclaimed listener healthy")
                // A replacement listener at the same port must not inherit this trust.
                try await stopFixtureAndWait(fixture)
                let replacement = try await startFixture(binary: binary, model: model, port: base)
                defer { stopFixture(replacement) }
                let log = requestLog(model: model, port: base)
                let before = (try? Data(contentsOf: log)) ?? Data()
                try check(await manager.isHealthy() == false, "replacement PID is not healthy as our orphan")
                if case .skipped = await manager.warmUp() {
                    try check(true, "warm-up refuses replacement listener")
                } else { throw Failure.failed("warm-up trusted replacement listener") }
                try check(((try? Data(contentsOf: log)) ?? Data()) == before,
                          "replacement receives no health or inference request")
                await manager.stop()
                try check(replacement.isRunning, "stop leaves replacement listener alive")
                try await stopFixtureAndWait(replacement)
            } else {
                try check(url.port == base + 1 && ownership == .owned,
                          "\(kind): unknown listener skipped for next free port")
                try check(!FileManager.default.fileExists(atPath: requestLog(model: model, port: base).path),
                          "\(kind): unknown listener receives no HTTP or audio")
                try check(await manager.isHealthy(), "\(kind): own listener healthy")
                await manager.stop()
                try check(fixture.isRunning, "\(kind): stopping manager preserves unrelated listener")
                try check(!WhisperServerManager.portIsOccupied(base + 1), "\(kind): own port released")
            }
            try await stopFixtureAndWait(fixture)
        } catch {
            await manager.stop()
            throw error
        }
    }

    static func discoveryChecks(root: URL, binary: URL) throws {
        let owned = root.appending(path: "models-owned", directoryHint: .isDirectory)
        let fallback = root.appending(path: "models-fallback", directoryHint: .isDirectory)
        for directory in [owned, fallback] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["ggml-large-v3.bin", "ggml-large-v3-turbo.bin", "ggml-silero-v6.2.0.bin"] {
                let file = directory.appending(path: name)
                _ = FileManager.default.createFile(atPath: file.path, contents: nil)
                let handle = try FileHandle(forWritingTo: file)
                try handle.truncate(atOffset: UInt64(WhisperServerManager.minimumModelBytes))
                try handle.close()
            }
        }
        let discovered = WhisperServerManager.discoverModels(in: [owned, fallback], preferredDirectory: owned)
        try check(discovered.map(\.lastPathComponent) == ["ggml-large-v3.bin", "ggml-large-v3-turbo.bin",
                                                         "ggml-large-v3-turbo.bin", "ggml-large-v3.bin"],
                  "owned full-v3 wins; fallback turbo ranking retained; VAD excluded")
        try check(discovered.first?.deletingLastPathComponent() == owned, "MicTest model directory takes priority")
        try check(WhisperServerManager.binaryCandidates.first == WhisperServerManager.runtimeDirectory
            .appending(path: "bin/whisper-server").path, "MicTest runtime binary is first pinned path")
        try check(WhisperServerManager.modelSearchDirectories(environment: [:]).first
            == WhisperServerManager.modelsDirectory, "MicTest model directory is searched first")
        let legacy = WhisperServerManager(modelURL: owned.appending(path: "ggml-large-v3.bin"),
                                          scratchDirectory: root.appending(path: "legacy-config"),
                                          binaryCandidates: [binary.path],
                                          vadModelURL: owned.appending(path: "ggml-silero-v6.2.0.bin"))
        try check(!legacy.localFinalConfigured, "full model and VAD do not qualify a legacy binary for primary mode")
    }

    static func readinessStopRace(root: URL, binary: URL, model: URL,
                                  vetoOnly: Bool, lateReady: Bool) async throws {
        let name = "readiness-\(vetoOnly ? "veto" : "stop")-\(lateReady ? "ready" : "absent")"
        let scratch = root.appending(path: name, directoryHint: .isDirectory)
        let base = try unusedBasePort()
        let gate = ProbeGate()
        let manager = WhisperServerManager(
            modelURL: model, preferredPort: base, scratchDirectory: scratch,
            binaryCandidates: [binary.path], vadModelURL: model,
            readyProbeOverride: { _ in await gate.probe() })
        do {
            // Initial startup uses the real fake-server health endpoint. Only the
            // existing-listener fast path is gated by this injected probe.
            let initial = try await manager.ensureReady(timeout: 5)
            try check(initial.port == base, "\(name): fixture starts on its isolated port")
            let pending = Task { () -> String? in
                do {
                    _ = try await manager.ensureReady(timeout: 5)
                    return nil
                } catch {
                    return String(describing: error)
                }
            }
            await gate.waitForEntry()
            if vetoOnly {
                // Model a stop queued behind the suspended start in the app's
                // lifecycle chain. It cannot enter the actor until that start ends.
                manager.vetoPendingStart()
            } else {
                // The complete stop occurs while ensureReady is still suspended.
                await manager.stop()
                try check(!WhisperServerManager.portIsOccupied(base),
                          "\(name): stop completed before the old health result resumed")
            }
            await gate.release(lateReady ? .ready : .absent)
            let error = await pending.value
            try check(error?.contains("readiness request superseded by stop") == true,
                      "\(name): stale health result cannot return ready or clear a newer veto")
            let launches = manager.recentLog(200).filter {
                $0.hasPrefix("[manager] launched whisper-server pid")
            }.count
            try check(launches == 1, "\(name): suspended request did not relaunch a process")
            await manager.stop()
            try check(!WhisperServerManager.portIsOccupied(base), "\(name): isolated listener remains stopped")

            // The stop generation invalidates old requests, not future deliberate
            // starts. There is no active listener here, so no gated fast-path probe.
            let restarted = try await manager.ensureReady(timeout: 5)
            let ownership = await manager.currentOwnership
            try check(restarted.port == base && ownership == .owned,
                      "\(name): a later explicit start is still allowed")
            await manager.stop()
        } catch {
            await manager.stop()
            throw error
        }
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--port"),
           let port = Int(arguments[index + 1]), let modelIndex = arguments.firstIndex(of: "-m") {
            guard !arguments.contains("--vad"), !arguments.contains("--vad-model") else {
                throw Failure.failed("legacy binary received unsupported VAD arguments")
            }
            try fakeServer(port: port, model: URL(fileURLWithPath: arguments[modelIndex + 1]))
            return
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "MicTest-isolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let unpinnedBinary = root.appending(path: "unpinned-fixture")
        try FileManager.default.copyItem(at: binary, to: unpinnedBinary)
        let model = root.appending(path: "fixture-model.bin")
        try Data("fixture, never real weights".utf8).write(to: model)
        try discoveryChecks(root: root, binary: binary)
        for kind in ["no-record", "wrong-port", "wrong-pid", "wrong-model", "unpinned", "legacy-record", "reclaim"] {
            try await runCase(kind, root: root, binary: binary, unpinnedBinary: unpinnedBinary, model: model)
        }
        for vetoOnly in [false, true] {
            for lateReady in [false, true] {
                try await readinessStopRace(root: root, binary: binary, model: model,
                                            vetoOnly: vetoOnly, lateReady: lateReady)
            }
        }
        print("ALL ISOLATION CHECKS PASSED")
    }
}
