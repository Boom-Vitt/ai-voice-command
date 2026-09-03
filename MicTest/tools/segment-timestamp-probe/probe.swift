//  probe.swift — throwaway diagnostic: under what conditions does SFSpeechRecognizer
//  report NON-ZERO segment timestamps for th-TH?
//
//  Not part of MicTest. Reads audio files, writes a log, touches nothing else.

import AVFoundation
import Foundation
import Speech

// ─────────────────────────────────────────────────────────────────────────────
// Logging — the app is launched via `open`, so stdout must go to a file.
// ─────────────────────────────────────────────────────────────────────────────
/// Config comes from a plain file, not the environment: `open --env` produced an
/// environment that AppKit's own startup path trapped on, and this probe needs no env at all.
/// Format: one KEY=VALUE per line.
func cfg(_ key: String, _ fallback: String) -> String {
    guard let raw = try? String(contentsOfFile: "/tmp/segprobe.cfg", encoding: .utf8) else { return fallback }
    for line in raw.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == key {
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
    }
    return fallback
}
let logPath = cfg("PROBE_LOG", "/tmp/segprobe.log")
freopen(logPath, "w", stdout)
freopen(logPath, "a", stderr)
setvbuf(stdout, nil, _IOLBF, 0)

func authName(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .authorized: return "authorized"
    @unknown default: return "unknown(\(s.rawValue))"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Audio: decode a file into the app's tap format (48 kHz float32 mono), trim it,
// chunk it at 1024 frames (SyntheticAudioSource.framesPerChunk), and ALSO write the
// trimmed audio back out so the URL request hears exactly the same samples.
// ─────────────────────────────────────────────────────────────────────────────
final class Clip: @unchecked Sendable {
    let label: String
    let chunks: [AVAudioPCMBuffer]
    let format: AVAudioFormat
    let seconds: Double
    let fileURL: URL
    let samples: [Float]

    /// Build a clip out of an arbitrary sample array (used to splice in silence / noise).
    init(label: String, samples: [Float], format: AVAudioFormat, outPath: String) throws {
        self.label = label
        self.format = format
        self.samples = samples
        self.seconds = Double(samples.count) / format.sampleRate
        var built: [AVAudioPCMBuffer] = []
        var off = 0
        while off < samples.count {
            let n = min(1024, samples.count - off)
            guard let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            c.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                memcpy(c.floatChannelData![0], src.baseAddress!.advanced(by: off), n * MemoryLayout<Float>.size)
            }
            built.append(c)
            off += n
        }
        self.chunks = built
        let url = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: url)
        let f = try AVAudioFile(forWriting: url, settings: format.settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "probe", code: 5)
        }
        whole.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            memcpy(whole.floatChannelData![0], src.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }
        try f.write(from: whole)
        self.fileURL = url
    }

    init(sourcePath: String, label: String, maxSeconds: Double, outPath: String) throws {
        self.label = label
        let src = try AVAudioFile(forReading: URL(fileURLWithPath: sourcePath))
        // The exact format `installTap` hands MicTest: 48 kHz, 1 ch, float32, deinterleaved.
        guard let tap = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 48_000, channels: 1, interleaved: false)
        else { throw NSError(domain: "probe", code: 1) }
        self.format = tap
        guard let conv = AVAudioConverter(from: src.processingFormat, to: tap) else {
            throw NSError(domain: "probe", code: 2)
        }
        let wantFrames = AVAudioFrameCount(maxSeconds * 48_000)
        guard let out = AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: wantFrames + 48_000) else {
            throw NSError(domain: "probe", code: 3)
        }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            let inBuf = AVAudioPCMBuffer(pcmFormat: src.processingFormat,
                                         frameCapacity: AVAudioFrameCount(src.length))
            guard let inBuf else { status.pointee = .endOfStream; return nil }
            do { try src.read(into: inBuf) } catch { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        if let err { throw err }
        let total = min(out.frameLength, wantFrames)
        self.seconds = Double(total) / 48_000

        // Chunk at 1024 frames — the cadence MicTest's tap delivers.
        var built: [AVAudioPCMBuffer] = []
        var off: AVAudioFrameCount = 0
        while off < total {
            let n = min(1024, total - off)
            guard let c = AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: n) else { break }
            c.frameLength = n
            memcpy(c.floatChannelData![0],
                   out.floatChannelData![0].advanced(by: Int(off)),
                   Int(n) * MemoryLayout<Float>.size)
            built.append(c)
            off += n
        }
        self.chunks = built
        var flat = [Float](repeating: 0, count: Int(total))
        flat.withUnsafeMutableBufferPointer { dst in
            memcpy(dst.baseAddress!, out.floatChannelData![0], Int(total) * MemoryLayout<Float>.size)
        }
        self.samples = flat

        // Same samples on disk for the URL request.
        let url = URL(fileURLWithPath: outPath)
        try? FileManager.default.removeItem(at: url)
        let f = try AVAudioFile(forWriting: url, settings: tap.settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let whole = AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: total) else {
            throw NSError(domain: "probe", code: 4)
        }
        whole.frameLength = total
        memcpy(whole.floatChannelData![0], out.floatChannelData![0],
               Int(total) * MemoryLayout<Float>.size)
        try f.write(from: whole)
        self.fileURL = url
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// One condition.
// ─────────────────────────────────────────────────────────────────────────────
enum Feed { case buffer(paced: Bool); case url }

struct Condition {
    let id: String
    let note: String
    let feed: Feed
    let locale: String
    let onDevice: Bool
    let partials: Bool
    let punctuation: Bool
    let hint: SFSpeechRecognitionTaskHint
    let contextual: [String]
    let clip: Clip
}

/// Thread-safe accumulator: Speech calls back on its own queue.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    var callbacks = 0
    var partialCallbacks = 0
    var finalCallbacks = 0
    var maxSegsPartial = 0
    var maxSegsFinal = 0
    var maxCoveredPartial = 0.0
    var maxCoveredFinal = 0.0
    var nonZeroPartialCallbacks = 0
    var nonZeroFinalCallbacks = 0
    var lastLoggedAt = Date.distantPast
    var lastText = ""
    var errorText: String?
    var firstSegLinePartial: String?
    var firstSegLineFinal: String?

    func with<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

func describeSegments(_ segs: [SFTranscriptionSegment], limit: Int = 5) -> String {
    if segs.isEmpty { return "(none)" }
    return segs.prefix(limit).enumerated().map { i, s in
        let sub = s.substring.count > 14 ? String(s.substring.prefix(14)) + "…" : s.substring
        return "[\(i)] t=\(String(format: "%.3f", s.timestamp)) d=\(String(format: "%.3f", s.duration)) \"\(sub)\""
    }.joined(separator: "  ")
}

func run(_ c: Condition) {
    print("")
    print("════════════════════════════════════════════════════════════════════")
    print("CONDITION \(c.id) — \(c.note)")
    let feedDesc: String
    switch c.feed {
    case .buffer(let paced): feedDesc = "SFSpeechAudioBufferRecognitionRequest (\(paced ? "paced real-time, 1024-frame chunks" : "unpaced dump"))"
    case .url: feedDesc = "SFSpeechURLRecognitionRequest"
    }
    print("  request           : \(feedDesc)")
    print("  locale            : \(c.locale)")
    print("  requiresOnDevice  : \(c.onDevice)")
    print("  shouldReportPartial: \(c.partials)")
    print("  addsPunctuation   : \(c.punctuation)")
    print("  taskHint          : \(c.hint == .dictation ? "dictation" : (c.hint == .unspecified ? "unspecified" : "other(\(c.hint.rawValue))"))")
    print("  contextualStrings : \(c.contextual.count)")
    print("  audio             : \(c.clip.label) — \(String(format: "%.1f", c.clip.seconds))s @48kHz mono f32")
    print("────────────────────────────────────────────────────────────────────")

    guard let rec = SFSpeechRecognizer(locale: Locale(identifier: c.locale)) else {
        print("  RESULT: no SFSpeechRecognizer for \(c.locale)")
        return
    }
    print("  recognizer: available=\(rec.isAvailable) supportsOnDevice=\(rec.supportsOnDeviceRecognition)")

    let req: SFSpeechRecognitionRequest
    var bufReq: SFSpeechAudioBufferRecognitionRequest?
    switch c.feed {
    case .buffer:
        let r = SFSpeechAudioBufferRecognitionRequest()
        bufReq = r
        req = r
    case .url:
        req = SFSpeechURLRecognitionRequest(url: c.clip.fileURL)
    }
    req.shouldReportPartialResults = c.partials
    req.requiresOnDeviceRecognition = c.onDevice
    req.addsPunctuation = c.punctuation
    req.taskHint = c.hint
    if !c.contextual.isEmpty { req.contextualStrings = c.contextual }

    let tally = Tally()
    let done = DispatchSemaphore(value: 0)
    let started = Date()

    let task = rec.recognitionTask(with: req) { result, error in
        if let result {
            let segs = result.bestTranscription.segments
            let covered = segs.last.map { $0.timestamp + $0.duration } ?? 0
            let isFinal = result.isFinal
            var shouldLog = false
            tally.with {
                tally.callbacks += 1
                if isFinal { tally.finalCallbacks += 1 } else { tally.partialCallbacks += 1 }
                if isFinal {
                    tally.maxSegsFinal = max(tally.maxSegsFinal, segs.count)
                    tally.maxCoveredFinal = max(tally.maxCoveredFinal, covered)
                    if covered != 0 { tally.nonZeroFinalCallbacks += 1 }
                    if tally.firstSegLineFinal == nil { tally.firstSegLineFinal = describeSegments(segs) }
                } else {
                    tally.maxSegsPartial = max(tally.maxSegsPartial, segs.count)
                    tally.maxCoveredPartial = max(tally.maxCoveredPartial, covered)
                    if covered != 0 { tally.nonZeroPartialCallbacks += 1 }
                    if tally.firstSegLinePartial == nil && !segs.isEmpty {
                        tally.firstSegLinePartial = describeSegments(segs)
                    }
                }
                tally.lastText = result.bestTranscription.formattedString
                // Log the first callback, every final, every non-zero-covered callback,
                // and otherwise at most one line per second — the same throttle the app uses.
                if isFinal || covered != 0 || tally.callbacks == 1
                    || Date().timeIntervalSince(tally.lastLoggedAt) >= 1.0 {
                    shouldLog = true
                    tally.lastLoggedAt = Date()
                }
            }
            if shouldLog {
                let wall = Date().timeIntervalSince(started)
                print("  \(isFinal ? "FINAL  " : "partial") "
                    + "cb#\(tally.with { tally.callbacks }) "
                    + "segs=\(segs.count) "
                    + "covered=\(String(format: "%.3f", covered))s "
                    + "wall=\(String(format: "%.1f", wall))s "
                    + "meta=\(result.speechRecognitionMetadata != nil) "
                    + "chars=\(result.bestTranscription.formattedString.count)")
                print("      segs: \(describeSegments(segs))")
            }
            if isFinal { done.signal() }
        }
        if let error {
            let ns = error as NSError
            tally.with { tally.errorText = "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)" }
            print("  ERROR: \(ns.domain) code=\(ns.code) — \(ns.localizedDescription)")
            done.signal()
        }
    }

    if let bufReq {
        // Feed on a background thread; the app appends from the audio thread while its
        // task is already alive, which is what this mirrors.
        let paced: Bool
        if case .buffer(let p) = c.feed { paced = p } else { paced = false }
        let clip = c.clip
        DispatchQueue.global(qos: .userInitiated).async {
            let perChunk = 1024.0 / 48_000.0
            let t0 = Date()
            for (i, buf) in clip.chunks.enumerated() {
                bufReq.append(buf)
                if paced {
                    let target = Double(i + 1) * perChunk
                    let slack = target - Date().timeIntervalSince(t0)
                    if slack > 0 { Thread.sleep(forTimeInterval: slack) }
                }
            }
            bufReq.endAudio()
        }
    }

    let budget = c.clip.seconds + 75
    if done.wait(timeout: .now() + budget) == .timedOut {
        print("  TIMED OUT after \(String(format: "%.0f", budget))s with no final")
        task.cancel()
    }
    Thread.sleep(forTimeInterval: 0.5)

    tally.with {
        print("  ── SUMMARY \(c.id) ─────────────────────────────────────────────")
        print("  callbacks: \(tally.callbacks) total  (\(tally.partialCallbacks) partial, \(tally.finalCallbacks) final)")
        print("  PARTIALS: maxSegs=\(tally.maxSegsPartial)  maxCovered=\(String(format: "%.3f", tally.maxCoveredPartial))s  callbacksWithNonZeroCovered=\(tally.nonZeroPartialCallbacks)")
        print("  FINALS  : maxSegs=\(tally.maxSegsFinal)  maxCovered=\(String(format: "%.3f", tally.maxCoveredFinal))s  callbacksWithNonZeroCovered=\(tally.nonZeroFinalCallbacks)")
        print("  first partial segs: \(tally.firstSegLinePartial ?? "(never had segments)")")
        print("  first final   segs: \(tally.firstSegLineFinal ?? "(no final)")")
        if let e = tally.errorText { print("  error: \(e)") }
        let t = tally.lastText
        print("  text(\(t.count) chars): \(t.count > 160 ? String(t.prefix(160)) + "…" : t)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
func matrix() {
    let thaiSrc = cfg("PROBE_THAI", "/tmp/thai.aiff")
    let engSrc = cfg("PROBE_ENG", "/tmp/eng.aiff")
    let secs = Double(cfg("PROBE_SECONDS", "20")) ?? 20

    let thai: Clip
    let eng: Clip
    do {
        thai = try Clip(sourcePath: thaiSrc, label: "thai.aiff first \(Int(secs))s (say -v Kanya)",
                        maxSeconds: secs, outPath: "/tmp/probe_thai_clip.caf")
        eng = try Clip(sourcePath: engSrc, label: "eng.aiff first \(Int(secs))s (say -v Samantha)",
                       maxSeconds: secs, outPath: "/tmp/probe_eng_clip.caf")
    } catch {
        print("FATAL: could not prepare audio — \(error)")
        exit(2)
    }
    print("audio ready: thai \(thai.chunks.count) chunks / \(String(format: "%.1f", thai.seconds))s, "
        + "eng \(eng.chunks.count) chunks / \(String(format: "%.1f", eng.seconds))s")

    let terms = ["deploy", "commit", "branch", "main", "refactor",
                 "push", "merge", "rebase", "pull request", "API",
                 "database", "function", "variable", "debug", "build",
                 "test", "server", "client", "endpoint", "repository"]

    // ── Composed clips: speech with a pause, which is what a human in a silent room
    // actually produces. The `covered=12.0s wall=14.4s` line came from a live-microphone
    // round; the closest thing this harness can build is a real pause in the audio.
    func take(_ c: Clip, _ from: Double, _ to: Double) -> [Float] {
        let a = max(0, Int(from * 48_000)), b = min(c.samples.count, Int(to * 48_000))
        return a < b ? Array(c.samples[a..<b]) : []
    }
    func silence(_ secs: Double) -> [Float] { [Float](repeating: 0, count: Int(secs * 48_000)) }
    func noise(_ secs: Double, _ amp: Float) -> [Float] {
        (0..<Int(secs * 48_000)).map { _ in Float.random(in: -amp...amp) }
    }

    var pauseTail: Clip? = nil    // 12s speech + 10s digital silence
    var pauseNoise: Clip? = nil   // 12s speech + 10s low room noise (never digital zero)
    var pauseMid: Clip? = nil     // 8s speech + 6s silence + 8s speech
    do {
        pauseTail = try Clip(label: "12s Thai speech + 10s DIGITAL SILENCE",
                             samples: take(thai, 0, 12) + silence(10),
                             format: thai.format, outPath: "/tmp/probe_pause_tail.caf")
        pauseNoise = try Clip(label: "12s Thai speech + 10s low noise (-60 dBFS)",
                              samples: take(thai, 0, 12) + noise(10, 0.001),
                              format: thai.format, outPath: "/tmp/probe_pause_noise.caf")
        pauseMid = try Clip(label: "8s speech + 6s silence + 8s speech",
                            samples: take(thai, 0, 8) + silence(6) + take(thai, 12, 20),
                            format: thai.format, outPath: "/tmp/probe_pause_mid.caf")
    } catch { print("WARN: could not compose pause clips — \(error)") }

    var cs: [Condition] = []
    // 3 first: cheapest decisive split — batch vs streaming on identical audio.
    cs.append(Condition(id: "C3", note: "URL request, th-TH, on-device (app flags otherwise)",
                        feed: .url, locale: "th-TH", onDevice: true, partials: true,
                        punctuation: true, hint: .dictation, contextual: terms, clip: thai))
    // 1: the app's exact configuration.
    cs.append(Condition(id: "C1", note: "APP EXACT: buffer request, th-TH, on-device, paced",
                        feed: .buffer(paced: true), locale: "th-TH", onDevice: true, partials: true,
                        punctuation: true, hint: .dictation, contextual: terms, clip: thai))
    cs.append(Condition(id: "C1u", note: "as C1 but unpaced (instant backlog)",
                        feed: .buffer(paced: false), locale: "th-TH", onDevice: true, partials: true,
                        punctuation: true, hint: .dictation, contextual: terms, clip: thai))
    // 2: server-based.
    cs.append(Condition(id: "C2", note: "buffer request, th-TH, SERVER (requiresOnDevice=false)",
                        feed: .buffer(paced: false), locale: "th-TH", onDevice: false, partials: true,
                        punctuation: true, hint: .dictation, contextual: terms, clip: thai))
    cs.append(Condition(id: "C2u", note: "URL request, th-TH, SERVER",
                        feed: .url, locale: "th-TH", onDevice: false, partials: true,
                        punctuation: true, hint: .dictation, contextual: terms, clip: thai))
    // Flag isolation on the on-device buffer path.
    cs.append(Condition(id: "C4", note: "buffer, th-TH, on-device, addsPunctuation=FALSE",
                        feed: .buffer(paced: false), locale: "th-TH", onDevice: true, partials: true,
                        punctuation: false, hint: .dictation, contextual: terms, clip: thai))
    cs.append(Condition(id: "C5", note: "buffer, th-TH, on-device, BARE (no punctuation, no hint, no terms)",
                        feed: .buffer(paced: false), locale: "th-TH", onDevice: true, partials: true,
                        punctuation: false, hint: .unspecified, contextual: [], clip: thai))
    cs.append(Condition(id: "C6", note: "buffer, th-TH, on-device, shouldReportPartialResults=FALSE",
                        feed: .buffer(paced: false), locale: "th-TH", onDevice: true, partials: false,
                        punctuation: true, hint: .dictation, contextual: terms, clip: thai))
    // Locale control: does ANY locale report timestamps through these same paths?
    cs.append(Condition(id: "C7", note: "CONTROL: buffer, en-US, on-device, English audio, app flags",
                        feed: .buffer(paced: false), locale: "en-US", onDevice: true, partials: true,
                        punctuation: true, hint: .dictation, contextual: terms, clip: eng))
    cs.append(Condition(id: "C8", note: "CONTROL: URL, en-US, on-device, English audio",
                        feed: .url, locale: "en-US", onDevice: true, partials: true,
                        punctuation: true, hint: .dictation, contextual: terms, clip: eng))
    cs.append(Condition(id: "C9", note: "CONTROL: buffer, en-US, on-device, THAI audio (locale vs audio)",
                        feed: .buffer(paced: false), locale: "en-US", onDevice: true, partials: true,
                        punctuation: true, hint: .dictation, contextual: terms, clip: thai))

    if let pt = pauseTail {
        cs.append(Condition(id: "C10", note: "PAUSE: app-exact buffer, th-TH, on-device, PACED, speech then digital silence",
                            feed: .buffer(paced: true), locale: "th-TH", onDevice: true, partials: true,
                            punctuation: true, hint: .dictation, contextual: terms, clip: pt))
    }
    if let pn = pauseNoise {
        cs.append(Condition(id: "C11", note: "PAUSE: app-exact buffer, th-TH, on-device, PACED, speech then LOW NOISE",
                            feed: .buffer(paced: true), locale: "th-TH", onDevice: true, partials: true,
                            punctuation: true, hint: .dictation, contextual: terms, clip: pn))
    }
    if let pm = pauseMid {
        cs.append(Condition(id: "C12", note: "PAUSE: app-exact buffer, th-TH, on-device, PACED, speech/silence/speech",
                            feed: .buffer(paced: true), locale: "th-TH", onDevice: true, partials: true,
                            punctuation: true, hint: .dictation, contextual: terms, clip: pm))
    }

    // Length sweep: if the mechanism is an endpoint timeout, `lag` should stay ~2.2-2.3s
    // while `covered` tracks the speech length. 12s was picked to match the mystery line;
    // these were not.
    for L in [4.0, 7.0, 17.0] {
        if let c = try? Clip(label: "\(Int(L))s Thai speech + 8s digital silence",
                             samples: take(thai, 0, L) + silence(8),
                             format: thai.format, outPath: "/tmp/probe_sweep_\(Int(L)).caf") {
            cs.append(Condition(id: "L\(Int(L))", note: "LENGTH SWEEP: app-exact buffer, th-TH, on-device, PACED, \(Int(L))s speech then silence",
                                feed: .buffer(paced: true), locale: "th-TH", onDevice: true, partials: true,
                                punctuation: true, hint: .dictation, contextual: terms, clip: c))
        }
    }

    let onlyRaw = cfg("PROBE_ONLY", "")
    let only: String? = onlyRaw.isEmpty ? nil : onlyRaw
    for c in cs {
        if let only, !only.split(separator: ",").map(String.init).contains(c.id) { continue }
        run(c)
        Thread.sleep(forTimeInterval: 1.0)
    }
    print("")
    print("=== matrix complete ===")
}

// ─────────────────────────────────────────────────────────────────────────────
print("=== segprobe start \(Date()) ===")
print("bundleID: \(Bundle.main.bundleIdentifier ?? "nil")")
print("auth before: \(authName(SFSpeechRecognizer.authorizationStatus()))")

let status = SFSpeechRecognizer.authorizationStatus()
if status != .authorized {
    let sem = DispatchSemaphore(value: 0)
    SFSpeechRecognizer.requestAuthorization { st in
        print("auth callback: \(authName(st))")
        sem.signal()
    }
    if sem.wait(timeout: .now() + 120) == .timedOut {
        print("BLOCKED: no answer to the authorization prompt after 120s")
        exit(4)
    }
}
guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
    print("BLOCKED: authorization is \(authName(SFSpeechRecognizer.authorizationStatus()))")
    exit(3)
}
// The matrix runs OFF the main thread and the main run loop is left pumping.
// Speech delivers `recognitionTask(with:resultHandler:)` callbacks on the main queue, so a
// `semaphore.wait()` on the main thread deadlocks before the first partial ever arrives —
// measured: the log stopped dead after "recognizer: available=true" and the process hung.
Thread.detachNewThread {
    matrix()
    exit(0)
}
RunLoop.main.run()
