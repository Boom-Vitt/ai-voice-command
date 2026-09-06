import Foundation

@main
struct LifecycleTest {
    static func ms(_ d: Duration) -> String {
        let c = d.components
        return String(format: "%.0f ms", Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
    }

    static func shell(_ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func post(_ wav: Data, to url: URL, language: String) async -> (ms: String, text: String, status: Int) {
        let body = WhisperServerManager.multipartBody(wav: wav, filename: "jfk.wav", language: language)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data
        let clock = ContinuousClock(); let t = clock.now
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let text = (obj?["text"] as? String ?? String(decoding: data.prefix(200), as: UTF8.self))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (ms(t.duration(to: clock.now)), text, status)
        } catch {
            return (ms(t.duration(to: clock.now)), "ERROR \(error.localizedDescription)", -1)
        }
    }

    static func main() async {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "PASS " : "FAIL ") + what)
            if !ok { failures += 1 }
        }
        let clock = ContinuousClock()
        let manager = WhisperServerManager()          // defaults: discoverModel(), "th", 8177
        print("model:", manager.modelName, "->", manager.modelURL?.path ?? "nil")
        print("before: pgrep ->", shell(["/usr/bin/pgrep", "-fl", "whisper-server"]).out.isEmpty ? "(none)" : "SOMETHING RUNNING")

        // 1. ensureReady
        var t = clock.now
        let url: URL
        do {
            url = try await manager.ensureReady(timeout: 60) { p in print("   progress:", p) }
        } catch {
            print("ensureReady FAILED:", error)
            print(manager.recentLog(40).joined(separator: "\n"))
            exit(1)
        }
        let readyMs = ms(t.duration(to: clock.now))
        print("ensureReady ->", url, "in", readyMs)
        check(url.absoluteString == "http://127.0.0.1:8177/inference", "inference URL is 127.0.0.1:8177/inference")
        let diag = await manager.diagnostics
        print("diagnostics:", diag)
        check(await manager.currentOwnership == .owned, "ownership == owned")

        // pid / process group
        var childPid: pid_t = 0
        if let range = diag.range(of: "pid="), let n = Int32(diag[range.upperBound...].prefix { $0.isNumber }) { childPid = n }
        print("child pid:", childPid, "pgid:", getpgid(childPid), "our pgid:", getpgid(getpid()))
        check(childPid > 0 && getpgid(childPid) == childPid, "child is its own process-group leader (kill(-pid) reaches its group)")
        print(shell(["/bin/ps", "-o", "pid,pgid,ppid,command", "-p", String(childPid)]).out)
        let lsof = shell(["/usr/sbin/lsof", "-nP", "-a", "-p", String(childPid), "-iTCP", "-sTCP:LISTEN"]).out
        print("listening sockets:\n" + lsof)
        check(lsof.contains("127.0.0.1:8177") && !lsof.contains("*:8177"), "bound to 127.0.0.1 only")

        // 2. isHealthy
        t = clock.now
        let healthy = await manager.isHealthy()
        print("isHealthy ->", healthy, "in", ms(t.duration(to: clock.now)))
        check(healthy, "isHealthy after ready")

        // 3. warmUp (first request of this process: Metal shader compile)
        let linesBefore = manager.log.totalLines
        t = clock.now
        let outcome = await manager.warmUp()
        print("warmUp ->", outcome, "wall", ms(t.duration(to: clock.now)))
        if case .warmed = outcome { check(true, "warmUp transcribed jfk.wav") } else { check(false, "warmUp transcribed jfk.wav") }
        let again = await manager.warmUp()
        check(again == .alreadyWarm, "second warmUp -> alreadyWarm (\(again))")
        let linesPerRequest = manager.log.totalLines - linesBefore
        print("log lines added by one --convert request:", linesPerRequest)

        // 4. steady state: the same clip twice more (only the bundled jfk.wav is ever sent)
        let wav = try! Data(contentsOf: URL(fileURLWithPath: WhisperServerManager.warmUpClipPath))
        let second = await post(wav, to: url, language: "th")
        print("2nd jfk.wav POST -> HTTP \(second.status) in \(second.ms): \(second.text.count) chars")
        let third = await post(wav, to: url, language: "th")
        print("3rd jfk.wav POST -> HTTP \(third.status) in \(third.ms): \(third.text.count) chars")
        print("   text (jfk.wav under -l th):", third.text.prefix(120))
        check(second.status == 200 && third.status == 200, "steady-state requests answered 200 (through --convert/ffmpeg)")

        // temp files: --convert must leave nothing behind
        let tmp = FileManager.default.temporaryDirectory.appending(path: "MicTest-whisper-server").path
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []
        print("scratch dir", tmp, "contents:", leftovers)
        check(leftovers.isEmpty, "--convert temp files cleaned up by the server")

        // 5. stop
        t = clock.now
        await manager.stop()
        print("stop in", ms(t.duration(to: clock.now)))
        check(await manager.currentOwnership == .none, "ownership == none after stop")
        check(await manager.isHealthy() == false, "isHealthy false after stop")
        check(kill(childPid, 0) != 0, "child pid \(childPid) no longer exists (kill -0 fails)")
        check(WhisperServerManager.portIsOccupied(8177) == false, "port 8177 free after stop")
        manager.emergencyStop()   // nothing owned now: must be a harmless no-op
        print("emergencyStop() after stop: no-op OK")

        print("--- recent log ---")
        for line in manager.recentLog(60) { print("  ", line) }
        print("--- pgrep -fl whisper-server after stop ---")
        let pg = shell(["/usr/bin/pgrep", "-fl", "whisper-server"])
        print("exit=\(pg.status) output=[\(pg.out.trimmingCharacters(in: .whitespacesAndNewlines))]")
        check(pg.status != 0 && pg.out.isEmpty, "no whisper-server process survives")
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
