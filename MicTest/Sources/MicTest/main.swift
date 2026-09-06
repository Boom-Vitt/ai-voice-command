//
//  MicTest — a background Thai dictation app
//
//  Tap Right-Option to start dictating, tap again to stop; spoken Thai is typed into whatever application
//  currently has keyboard focus. There is no main window: the only UI is a small
//  floating HUD plus a menubar item.
//
//  ── What changed from the windowed probe ────────────────────────────────────────
//
//  The window is gone. Everything it used to show — permission status, capture state,
//  level/frame counters, cloud counters, bundle identity — now lives in two places
//  that are reachable without a window: the menubar menu (live, refreshed every time
//  it opens) and /tmp/mictest_trace.txt.
//
//  ── Why there are TWO ways in, not one ─────────────────────────────────────────
//
//  An LSUIElement app whose only affordance is a menubar icon is one notch away from
//  being unusable: on a MacBook with a display notch, a status item that lands under
//  the notch is invisible and unclickable, and then there is no way to reach the app
//  at all. That cost an hour on the predecessor app. So this build ships BOTH a
//  menubar NSStatusItem AND a floating HUD that never fully hides — when nothing is
//  happening it sits in a compact idle form showing the hotkey hint. One of the two
//  is always clickable.
//
//  ── Two transcription passes ───────────────────────────────────────────────────
//
//    * LiveRecognizer (on-device SFSpeechRecognizer, th-TH) drives the live text.
//      It emits a *growing* partial: the whole utterance so far, every time. We track
//      what we have already typed and inject only the new suffix. It keeps that job
//      because nothing else was fast enough when this was written: Gemini's earlier
//      streaming model was measured needing 25 s before its first output, against
//      on-device word-by-word. See the engine selector below for what changed.
//    * A CORRECTION PASS re-transcribes each finalized utterance (a chunk of at most
//      10 s, cut 0.6 s after silence) and repairs the typed span. Which engine runs it
//      is the `CorrectionProviderKind` setting: `local` — a whisper.cpp server this app
//      owns on loopback, audio never leaves the Mac, the default when a model exists —
//      or `gemini` (`GeminiClient`, audio to Google, never a default), or `off`. Gemini
//      REPLACED fal Scribe v2 at the user's instruction and the fal client is gone; the
//      local provider was added 2026-09-03 because Apple's th-TH model cannot
//      code-switch (PLAN-2026-09-03-local-correction.md). Whether a result is APPLIED
//      to the typed text is a second toggle, default ON (the user's choice, recorded
//      at `autoCorrectEnabled`). See `noteFinalChunk` for the gate that stops it
//      laundering hallucinations.
//
//  ── TWO live engines, and Apple is the default ─────────────────────────────────
//
//  `GeminiLiveRecognizer` is a second engine for the LIVE pass, selectable from the
//  menubar and persisted at `UserDefaults["dictationEngine"]`. It streams audio to
//  `gemini-3.5-transcribe-live` over a WebSocket and answers one complete phrase per
//  silence-delimited turn (measured: 0.30 s after each pause, 97.6% character accuracy
//  on Thai) — which is the same utterance model this file already consumes, so nothing
//  downstream of `RecognizerEventBox` knows or cares which engine produced the text.
//
//  APPLE STAYS THE DEFAULT, and the reason is not latency. Selecting Gemini Live sends
//  the microphone to Google CONTINUOUSLY for as long as dictation is running — not the
//  ~10 s chunks the accuracy pass sends when it is switched on, but everything. Apple's
//  engine never leaves the Mac. That difference is the user's to make deliberately, so
//  it is opt-in, it is stated in the menu item's title and tooltip rather than buried,
//  and `nil` in UserDefaults means Apple.
//
//  ONE CONSEQUENCE WORTH STATING HERE. The watchdog ladder in `tickStatus` (bounce ->
//  capture restart -> `pkill localspeechrecognition`) is Apple-specific to its third
//  rung: it kills a macOS system service that a WebSocket to Google does not use. It
//  stands down entirely while Gemini Live is the active engine; a Gemini stall surfaces
//  through that engine's own `.unavailable` instead.
//
//  ── In-place repair, read this before touching the injection code ──────────────
//
//  Thai partials from SFSpeechRecognizer routinely REVISE earlier characters — tone
//  marks, vowels, and word merges get rewritten as context grows — so a non-prefix
//  partial is the NORM here, not an edge case. Both repair paths go through
//  `TextInjector.replaceLastInserted(count:with:)`, which either replaces exactly the
//  trailing range we typed or does nothing and returns a human-readable reason:
//
//    * a partial (or the utterance FINAL) that revises earlier words is repaired in
//      place: keep the longest common prefix, replace exactly the stale tail. Only
//      when `replaceLastInserted` refuses does injection stop for the utterance, and
//      the correct text stays on the HUD and one menu click from the clipboard;
//    * a cloud result that differs from what was typed is applied the same way, and
//      is announced as "corrected" ONLY when the replacement actually succeeded —
//      announcing a correction that did not happen is the same class of lie as
//      laundering a hallucination.
//
//  A failed replacement is NEVER followed by blind backspaces: synthesizing deletes
//  and hoping the caret has not moved eats the user's own text the moment focus
//  changed or an autocomplete fired.
//
//  ── Design constraints, all learned the hard way ───────────────────────────────
//    * Audio-thread isolation. The installTap closure is `@Sendable` and its body
//      calls exactly one `nonisolated static` function. No `nonisolated(unsafe)`, no
//      `MainActor.assumeIsolated`, no trace(), no UI. Getting this wrong crashed this
//      app with EXC_BREAKPOINT / _dispatch_assert_queue_fail.
//    * No NSAlert, ever. Every state is readable from the HUD and the menubar.
//    * File-based tracing. os_log .info is memory-only and invisible to `log show`.
//    * Never log an API key or transcript text. Counts only.
//
//  Built WITHOUT -parse-as-library, so this file is top-level code: the executable
//  statements at the very bottom are the process entry point.
//
//  This file consumes types authored elsewhere in the same module — do not redefine
//  them: AudioPipeline, LiveRecognizer, GeminiLiveRecognizer, TextInjector,
//  HotkeyMonitor, DictationHUD, GeminiClient, WhisperClient.
//

import AppKit
import AVFoundation
import Synchronization

// MARK: - Constants

/// Technical vocabulary, used for BOTH halves of the recognition stack:
///   * handed to whichever `CorrectionProvider` runs the correction pass (merged behind
///     the user's own file, see below) so it biases towards these spellings instead of
///     transliterating them into Thai phonetics, and
///   * handed to `LiveRecognizer.setContextualStrings`, where — MEASURED 2026-08-31 — it
///     has NO EFFECT WHATSOEVER. See the warning below before spending time on it.
///
/// ⚠️ THIS LIST DOES NOTHING ON THE DEFAULT (APPLE / on-device th-TH) PATH.
///
/// This comment used to claim the list was "the single knob that decides whether `commit`
/// comes back as `commit` or as `คอมมิต`". That is false, and it cost real debugging time.
/// The terms ARE applied — `LiveRecognizer.swift:759` sets `request.contextualStrings` on
/// every session and rotation — but the on-device th-TH model ignores them. Measured with
/// bias on vs off, output byte-identical in every cell:
///
///     English voice (say -v Samantha), URL request:  commit→เข็ด   deploy→ซอย   debug→ที่บาร์
///     English voice, BUFFER request (this app's exact five settings):  same, unchanged
///     Thai voice, "ช่วย commit โค้ดนี้": ช่วยเครือมีโค้ดนี้ให้หน่อยครับ, unchanged
///
/// Eight of the twenty terms below were tested, across two voices and both request types.
/// Nothing moved. Do not add terms here expecting the Apple path to honour them, and do
/// not conclude from a fixed transcript that a term you added is working.
///
/// WHERE IT DOES EARN ITS KEEP: the correction pass. `GeminiClient.transcribe(wav:
/// keyterms:)` splices these into its prompt ("Use these exact spellings if you hear
/// them: …") and there they work — `commit`, `deploy`, `production` come back correct.
/// Since 2026-09-03 the same list is LIVE ON THE LOCAL PROVIDER too:
/// `WhisperClient.promptString(from:)` renders it as one natural Thai sentence (a comma
/// list rescued the English and wrecked the Thai around it — measured, see that
/// function), capped at `WhisperClient.maxPromptBytes` (800; these 20 terms render to
/// 452 of them). The default provider is local whisper whenever a model and the binary
/// exist, so in the shipped configuration this list is no longer inert.
///
/// THE USER'S OWN TERMS DO NOT GO HERE. `UserKeyterms` reads
/// `~/.config/thaidictate/keyterms.txt` and merges it AHEAD of this list, so a word the
/// user needs (`time`, reported missing — TEST-2026-09-03-oog-english.txt: never
/// appeared until it was in the prompt, exact once it was) survives the byte cap before
/// any of these do. Keep this list to words that are genuinely ambiguous in a Thai
/// sentence, and short: whether 800 bytes of Thai-heavy prompt fits whisper's 224-token
/// window has not been counted (WhisperClient.swift, `maxPromptBytes`), so "how many
/// terms fit" is not a number this comment can promise — the `keyterms:` trace line at
/// every capture start says how many were kept and dropped.
///
/// The "short, ~100 entries" shape started as fal's hard API cap (50 characters per
/// keyterm, 100 entries). That cap left with fal: `GeminiClient` carries these into a
/// prompt, so the ceiling is now a token budget rather than a documented limit. Treat
/// the old numbers as house style, not as a constraint anyone has re-measured — a list
/// long enough to crowd the prompt is a list that costs accuracy on every request.
let cloudKeyterms: [String] = [
    "deploy", "commit", "branch", "main", "refactor",
    "push", "merge", "rebase", "pull request", "API",
    "database", "function", "variable", "debug", "build",
    "test", "server", "client", "endpoint", "repository"
]

/// Human name of the hold-to-talk gesture. `HotkeyMonitor` defaults to Right-Option and
/// reads `UserDefaults["hotkeyKeyCode"]` for an override; this string is what the HUD and
/// the menu say.
let defaultHotkeyName = "Right-Option"

/// What the HUD says when nothing is happening. The HUD deliberately does not fully hide
/// (see the header comment), so it needs an idle body.
let hudIdleBody = "Idle — tap \(defaultHotkeyName) to start dictating, tap again to stop."

/// Which engine the correction pass sends a finished utterance's WAV to.
///
/// `LiveRecognizer` (Apple, on-device) drives the LIVE text in every case: it types word
/// by word and its pure Thai is right. This setting names the SECOND engine, the one
/// that re-transcribes each finished utterance so `applyCloudResult` can repair the
/// typed span — the pass that exists because Apple's th-TH model cannot code-switch
/// (0/20 English terms usable, `contextualStrings` inert: TEST-2026-08-31-mixed-
/// language.md; that verdict is scoped to Apple by PLAN-2026-09-03-local-correction.md).
///
///   * `off`    — no second engine; nothing but Apple ever hears the microphone.
///   * `local`  — `LocalWhisperProvider`: a `whisper-server` this app spawns on
///                127.0.0.1 (`WhisperServerManager`). Audio stays on this Mac. Measured
///                2026-09-03 on ggml-large-v3-turbo with the sentence prompt: 4/5 clips
///                exact, English kept 7/8, Thai intact, ~650 ms warm for 5.7 s of audio
///                (TEST-2026-09-03-turbo-server-5clip.txt; synthetic voice).
///   * `gemini` — `GeminiClient`: the WAV is sent to Google. Never a default.
///
/// The default with nothing stored is `local` when both the pinned binary and a model
/// file exist, else `off` — the privacy-preserving reading survives every failure. There
/// is NO fallback between providers at runtime: a dormant second transcriber that can
/// silently take over is how you get two different answers for the same audio and no
/// way to tell which one you are reading. A provider's failure is traced as a failure.
/// Whisper never drives the live text — the round trip is chunked and hundreds of
/// milliseconds behind Apple's word-by-word partials, and whisper.cpp has no partials.
enum CorrectionProviderKind: String, CaseIterable, Sendable {
    case off, local, gemini
}

/// `CorrectionProvider` over the `whisper-server` that `WhisperServerManager` owns.
///
/// Why this is not simply a `WhisperClient`: the client is built with a port, and the
/// port is not known until the manager has started or adopted a server — `ensureReady`
/// scans 8177…8180 and launches on the first free one. So each request first asks the
/// manager (one loopback `/health` probe when the server is already up: the fast path
/// at the top of `ensureReady`), then takes the client for the port it returns. A
/// server that is not up yet is started here, on the request path, deliberately: the
/// first correction after a cold start waits for the model load (~2 s measured) rather
/// than being refused — a refused chunk's typed span is permanently uncorrectable (its
/// ledger snapshot is consumed in `noteFinalChunk`), a late one is merely late. The app
/// preloads the server at launch and at every capture start so that wait is normally
/// paid before the first utterance, not on it.
///
/// One client PER PORT, kept for the life of the process — not one per request.
/// `WhisperClient.init` builds a `URLSession` with a `RefuseRedirects` delegate, and a
/// session built with a delegate is retained by Foundation until it is invalidated,
/// which nothing does: measured 2026-09-03 with a 20-line `swiftc -O` program, 50
/// delegate sessions built and dropped left 50 delegates alive; the same 50 with
/// `finishTasksAndInvalidate()` left 0. Per request that was one session, delegate
/// and queue leaked per finalized utterance. The cache is bounded by the manager's
/// port scan (`portScanCount` candidates above `defaultPort`), and a class because a
/// struct cannot hold the `Mutex`.
final class LocalWhisperProvider: CorrectionProvider {
    let manager: WhisperServerManager
    private let clients = Mutex<[Int: WhisperClient]>([:])

    init(manager: WhisperServerManager) {
        self.manager = manager
    }

    /// `modelName` is the file the manager launches with, not something the server
    /// reports (WhisperClient.swift header); for an ADOPTED server it is unverified, and
    /// the ready trace says `ownership=adopted` for exactly that reason.
    var displayName: String { "local whisper (\(manager.modelName))" }
    var sendsAudioOffDevice: Bool { false }

    /// Live readiness. Async, so nothing on the main actor gates on it — see
    /// `AppDelegate.localCorrectionConfigured` for the synchronous question.
    func isAvailable() async -> Bool { await manager.isHealthy() }

    func transcribe(wav: Data, keyterms: [String]) async throws -> CorrectionResult {
        let url = try await manager.ensureReady()
        let port = url.port ?? WhisperServerManager.defaultPort
        let modelName = manager.modelName
        let client = clients.withLock { cache in
            if let existing = cache[port] { return existing }
            let fresh = WhisperClient(port: port, modelName: modelName)
            cache[port] = fresh
            return fresh
        }
        return try await client.transcribe(wav: wav, keyterms: keyterms)
    }
}

/// The user's own glossary: `~/.config/thaidictate/keyterms.txt`, one term per line.
///
/// This file is where a word like `time` goes. `cloudKeyterms` is the app's built-in
/// list and not the user's to edit; measured 2026-09-03
/// (TEST-2026-09-03-oog-english.txt, synthetic voice), `time` and `test` went from
/// never appearing to exact once they were in the prompt, so an editable list is the fix
/// for "I say time and it does not appear" — necessary, not sufficient: `commit`,
/// `check`, `Python` resisted even when added.
///
/// Read off the hotkey path (a detached task at launch and at every capture start —
/// `beginCapture` is the synchronous hotkey handler and a file read does not belong on
/// it), merged USER TERMS FIRST ahead of the built-ins, then clamped once through
/// `CloudKeyFile.clampTerms`, the same clamp both providers apply. User first because
/// `WhisperClient.promptString` keeps list order and drops what no longer fits its byte
/// cap: the 20 built-ins already render to 452 of 800 bytes, so a user term appended
/// LAST is the one that would fall off, unseen — the exact word the user reported
/// missing. The `keyterms:` trace line prints how many terms were kept and dropped.
enum UserKeyterms {
    static let pathComponents = [".config", "thaidictate", "keyterms.txt"]

    struct Loaded: Sendable {
        /// Terms in file order, trimmed, comments and blanks removed. Not yet clamped.
        let terms: [String]
        let path: String
        /// False when the file does not exist — an ordinary state, not an error.
        let present: Bool
    }

    static func defaultURL() -> URL {
        var url = FileManager.default.homeDirectoryForCurrentUser
        for component in pathComponents { url.appendPathComponent(component) }
        return url
    }

    /// A line whose first non-blank character is `#` is a comment; blank lines are
    /// ignored. Only WHOLE-line comments, so `C#` is a term. A missing or unreadable
    /// file is `present: false` with no terms — a no-op, never a failure.
    static func load(from url: URL = defaultURL()) -> Loaded {
        guard let data = try? Data(contentsOf: url) else {
            return Loaded(terms: [], path: url.path, present: false)
        }
        var terms: [String] = []
        let contents = String(decoding: data, as: UTF8.self)
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let term = rawLine.trimmingCharacters(in: .whitespaces)
            if term.isEmpty || term.hasPrefix("#") { continue }
            terms.append(term)
        }
        return Loaded(terms: terms, path: url.path, present: true)
    }

    /// User terms first, then the built-ins, de-duplicated and clamped once.
    static func merge(user: [String], builtin: [String]) -> [String] {
        CloudKeyFile.clampTerms(user + builtin)
    }
}

/// The SCRIPT-SANITY gate `applyCloudResult` runs before `replaceRecentText`.
///
/// Measured motivation (TEST-2026-09-03-oog-english.txt, experiment 2; PLAN-2026-09-03-
/// local-correction.md, "Out-of-glossary English", consequence 2): on the `check` clip
/// whisper at beam 5 hallucinated Vietnamese — `chui, chết, hay nòi` — at the SAME
/// length as the Thai it would have replaced, so the size-sanity gate alone would have
/// overwritten correct-ish Thai with Vietnamese. v1 launches at default beam, where that
/// clip did not do it; this gate is what stands between the user's text and the next
/// clip that does. Engine-independent: Gemini has the same failure class.
///
/// Two tests, either one refuses:
///   * a character outside the Thai block (U+0E00–U+0E7F), printable basic Latin
///     (U+0020–U+007E), ordinary whitespace, or a short list of typographic punctuation
///     Apple and Gemini both emit (dashes, curly quotes, ellipsis, no-break space).
///     Vietnamese diacritics, CJK, Cyrillic and Arabic are all outside it, and all are
///     hallucination signatures in a Thai+English dictation.
///   * the Thai-letter share collapsing: the typed span was at least half Thai letters
///     (U+0E01–U+0E3A, U+0E40–U+0E4E — consonants, vowels and marks; not Thai digits or
///     ฿) and the correction is under a fifth. Catches a Latin-only rewrite of a Thai
///     sentence, which the first test cannot.
///
/// The refusal names the offending scalars as `U+XXXX` code points, at most eight —
/// what the engine invented, not what the user said, so `trace()`'s no-transcript rule
/// holds. Shares are over non-whitespace scalars.
enum CorrectionScript {
    static let maxNamedOffenders = 8

    static func isPermitted(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0E00...0x0E7F, 0x20...0x7E, 0x09, 0x0A, 0x0D: return true
        case 0x00A0, 0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026: return true
        default: return false
        }
    }

    static func isThaiLetter(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0E01...0x0E3A, 0x0E40...0x0E4E: return true
        default: return false
        }
    }

    /// Thai letters over non-whitespace scalars; 0 for an empty or all-blank string.
    static func thaiLetterShare(of text: String) -> Double {
        var letters = 0
        var counted = 0
        for u in text.unicodeScalars where !u.properties.isWhitespace {
            counted += 1
            if isThaiLetter(u) { letters += 1 }
        }
        return counted == 0 ? 0 : Double(letters) / Double(counted)
    }

    /// Distinct scalars outside the permitted set, in first-seen order.
    static func offenders(in text: String) -> [Unicode.Scalar] {
        var seen = Set<Unicode.Scalar>()
        var out: [Unicode.Scalar] = []
        for u in text.unicodeScalars where !isPermitted(u) && seen.insert(u).inserted {
            out.append(u)
        }
        return out
    }

    /// Why `correction` may not replace `typed`, or `nil` when it may. The string is
    /// safe for the trace: code points and percentages, never text.
    static func refusal(typed: String, correction: String) -> String? {
        let bad = offenders(in: correction)
        if !bad.isEmpty {
            let named = bad.prefix(maxNamedOffenders)
                .map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            let more = bad.count > maxNamedOffenders
                ? " (+\(bad.count - maxNamedOffenders) more)" : ""
            return "\(bad.count) character\(bad.count == 1 ? "" : "s") outside"
                + " Thai/basic Latin/punctuation: \(named)\(more)"
        }
        let typedShare = thaiLetterShare(of: typed)
        let correctionShare = thaiLetterShare(of: correction)
        if typedShare >= 0.5, correctionShare < 0.2 {
            return String(format: "Thai-letter share collapsed (typed %.0f%% -> correction"
                + " %.0f%%)", typedShare * 100, correctionShare * 100)
        }
        return nil
    }
}

/// System Settings panes. Named exactly, because "grant Accessibility" without the pane
/// is a treasure hunt.
let accessibilityPaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
let microphonePaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
let speechPaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"

/// The two Google pages this app can usefully send someone to. TWO, where fal needed one:
/// fal put credit, keys and spend on a single billing page, and Google splits the same
/// job across a Cloud console (does this key exist, is the API switched on for it) and AI
/// Studio (what is my quota, what have I used). Sending a user to the wrong one of those
/// is a dead end, so each failure names the page that can actually resolve it.
///
/// Named once each because several things point at them — `describeCloudError`'s
/// key-rejected and quota messages, and the clickable usage line — and a URL repeated in
/// three strings is a URL that eventually disagrees with itself.
let googleCredentialsURL = "https://console.cloud.google.com/apis/credentials"
let googleQuotaURL = "https://aistudio.google.com/app/apikey"

/// `~/.config/thaidictate/env`, with the home directory folded back into a tilde.
///
/// Derived from `GeminiClient.defaultKeyFileURL()` rather than written out as a literal,
/// so there is exactly one definition of where that file lives;
/// `abbreviatingWithTildeInPath` then puts it back into the form the user would type. A
/// function, not a global `let`, because top-level bindings in this file initialise in
/// source order and `describeCloudError` is reachable from a stored-property initialiser.
func cloudEnvDisplayPath() -> String {
    (GeminiClient.defaultKeyFileURL().path as NSString).abbreviatingWithTildeInPath
}

/// How long the audio engine keeps running after the hotkey is released.
///
/// `AudioPipeline` finalises an utterance on trailing silence. If we tore the engine down
/// the instant the key came up, no further buffers would arrive, trailing silence would
/// stop growing, and the last utterance would be stranded in the ring — never finalised,
/// never sent to the cloud pass. Holding the engine open for slightly longer than the
/// pipeline's own 0.6 s silence window lets that final chunk fall out naturally.
let releaseDrainSeconds: TimeInterval = 0.9

/// How long one in-flight cloud request may hold the one-request gate shut before a NEW
/// final chunk is allowed to supersede it. A healthy fal round trip settled in ~1-3 s;
/// only a hung request (dropped network, waiting on the client's much longer timeout) ever
/// reached this age.
///
/// IT HAS NOW BEEN RE-MEASURED, AND THE INHERITED 5 s WAS TOO TIGHT. A 9.46 s / 302 KB
/// Thai WAV through `gemini-3.5-flash` settled in ~4.0 s of pure inference on a fast link
/// — leaving 1.0 s of headroom under the old threshold, against fal's 2-4 s. Upload is
/// what closes that gap: a 10 s chunk is ~320 KB of WAV, ~427 KB once base64'd into the
/// request body, so on a 1-2 Mbps uplink 2-3 s of transfer lands on top of the 4.0 s and
/// the round trip crosses 5 s while still perfectly healthy. The gate would then cancel a
/// request that was about to succeed, and — because the refused chunk's ledger snapshot
/// was already consumed — that span becomes permanently uncorrectable. 12 s is 3x the
/// measured median, still far below the client's 15 s request timeout, and still short
/// enough that a genuinely dropped connection is superseded rather than waited out.
///
/// Re-derive this if the model or the chunk length changes; the number is a latency
/// measurement, not a preference. `presumed hung` lines in the trace against requests
/// that later look ordinary are the signal that it is too tight again.
///
/// The stakes: while the gate is held shut, every refused chunk's
/// typed-span ledger snapshot has ALREADY been consumed by `noteFinalChunk`, so each
/// refused span becomes permanently uncorrectable. Past this age the gate cancels the
/// hung request (cancellation routes to `applyCloudFailure(cancelled: true)`, which does
/// not count an error) and lets the new chunk through.
let cloudSupersedeAfterSeconds: TimeInterval = 12.0

// NOTE: there is deliberately NO minimum-hold / tap-debounce logic in this file. A
// proposal to filter short presses here was rejected: premature or chattering releases
// are a HotkeyMonitor delivery problem and are fixed at their root there (its release
// grace window), not papered over per-consumer. Every press/release HotkeyMonitor
// delivers is treated as real.

// MARK: - Tracing

/// Append a timestamped line to /tmp/mictest_trace.txt.
///
/// This is the proven pattern — kept verbatim on purpose. Do not "improve" it into OSLog:
/// os_log at .info level is memory-only and does not survive into `log show`, which is how
/// we lost an hour once already. A plain file is greppable, tailable, and always there.
///
/// NEVER call this from the audio tap. It does synchronous file I/O; on a realtime render
/// thread that is a glitch generator. See `AppDelegate.processTap`.
///
/// NEVER pass transcript text or an API key to it. Character counts only — the trace is
/// world-readable in /tmp and the user's speech is not ours to leave lying around.
func trace(_ msg: String) {
    let line = "\(Date().formatted(date: .omitted, time: .standard))  \(msg)\n"
    guard let d = line.data(using: .utf8) else { return }
    // O_APPEND, deliberately -- NOT seekToEndOfFile() + write(). Those are two separate
    // operations, and this app has two independent writers holding two separate handles:
    // LiveRecognizer traces from Speech's callback thread while the watchdog below traces
    // from the main actor at 1 Hz. Both seek to offset N, both write at N, and one line
    // silently overwrites the other. They collide hardest during an error storm -- which
    // is exactly when the lines being destroyed are the ones this file exists to show us.
    // O_APPEND makes seek-to-end and write a single atomic step in the kernel for a
    // regular file. A lock would not have worked: the racing writer is in another file
    // with its own handle, so no lock either one holds could cover the other.
    // Do not "simplify" this back into FileHandle(forWritingTo:).
    let fd = open("/tmp/mictest_trace.txt", O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }          // same silent-failure contract as before
    FileHandle(fileDescriptor: fd, closeOnDealloc: true).write(d)
}

// MARK: - Small helpers

/// The literal Swift case name for an AVAuthorizationStatus. We show the *case name*
/// rather than a friendly phrase in the trace because that is a diagnostic; the menu
/// shows the human phrase.
func statusName(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted:    return "restricted"
    case .denied:        return "denied"
    case .authorized:    return "authorized"
    @unknown default:    return "unknown(rawValue: \(s.rawValue))"
    }
}

func statusPhrase(_ s: AVAuthorizationStatus) -> String {
    switch s {
    case .authorized:    return "granted"
    case .notDetermined: return "not asked yet"
    case .denied:        return "DENIED"
    case .restricted:    return "restricted"
    @unknown default:    return "unknown"
    }
}

@MainActor
func symbolImage(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .semibold) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
}

/// A `LiveRecognizer.RecognizerError` says something useful ("on-device recognition
/// unsupported: …"); bridging it through NSError does not — a Swift enum error stringifies
/// as "The operation couldn't be completed. (MicTest.LiveRecognizer.RecognizerError error
/// 2.)", which is exactly the kind of message that sends someone hunting through the source.
/// So unwrap the known case and fall back to NSError only for genuinely foreign errors.
func describeRecognizerError(_ error: Error) -> String {
    if let re = error as? LiveRecognizer.RecognizerError { return re.description }
    let ns = error as NSError
    return "\(ns.domain) code \(ns.code) — \(ns.localizedDescription)"
}

/// Same reasoning for `AudioPipeline.PipelineError`.
func describePipelineError(_ error: Error) -> String {
    if let pe = error as? AudioPipeline.PipelineError { return pe.description }
    let ns = error as NSError
    return "\(ns.domain) code \(ns.code) — \(ns.localizedDescription)"
}

/// Flatten a `GeminiClient` failure into something printable, and separately surface the
/// key path when the failure is "there is no key", because that path is the one thing the
/// user can act on. Nothing here ever renders the key itself.
///
/// ── Why the HTTP status comes back as a third member ──────────────────────────────────
/// `applyCloudFailure` has to recognise a 429 (quota) to auto-disable the cloud pass, and
/// it never sees the `Error` — `cloudPass` catches on a detached task and hops a String
/// across. The two candidate designs were (a) a second `as? GeminiClient.ClientError`
/// cast at the failure site, and (b) this. (b) wins on one argument: classifying a
/// `ClientError` is already this function's entire job, and putting a second, partial copy
/// of that knowledge in a bookkeeping method is how the two drift — the day someone adds a
/// meaning for 409 here, the other site keeps quietly treating it as generic. The tuple
/// SHAPE is unchanged across the fal → Gemini swap for the same reason it was extended
/// rather than reshaped when it grew: both call sites read named members.
///
/// ── Why these messages are not the fal ones with a name swapped ───────────────────────
/// Google's statuses do not mean what fal's meant. THERE IS NO 402 HERE AT ALL — fal
/// signalled "out of credit" with one, Google signals the same condition with a 429, so a
/// ported 402 branch would have been unreachable code pretending to be a safety net.
/// Conversely 400 is worth its own line here in a way it never was there.
///
/// Everything outside these branches keeps the generic string verbatim — inventing prose
/// for a status we have never seen would be guessing at the user.
func describeCloudError(_ error: Error) -> (summary: String, missingKeyPath: String?, httpStatus: Int?) {
    if let ce = error as? GeminiClient.ClientError {
        switch ce {
        case .missingKey(let path):
            return ("no Google API key — expected \(GeminiClient.keyName) in \(path)", path, nil)
        case .http(let status, let body):
            switch status {
            case 400:
                // NOT THE USER'S PROBLEM, and saying so is the whole point of this branch.
                // A 400 means this app built a request Google would not parse — wrong audio
                // encoding, a malformed part, a bad model name. No amount of key-checking or
                // topping-up fixes it, so any message that hints at those wastes the user's
                // afternoon. Name the app as the culprit and point at the trace.
                return ("MicTest sent Gemini a malformed request (HTTP 400) — this is a bug "
                        + "in the app, not a problem with your key or quota; "
                        + "see /tmp/mictest_trace.txt", nil, status)
            case 401, 403:
                // ONE BRANCH FOR BOTH, deliberately — and this is a reversal of the fal-era
                // rule, which split them precisely because they had different next steps
                // (bad key vs. account not entitled to the model). With Google they do not:
                // 401 is a rejected/expired key and 403 is most often "the Generative
                // Language API is not enabled for this key's project", and BOTH are settled
                // on the credentials page. Splitting a distinction the user cannot act on
                // differently is how you make two half-answers out of one whole one.
                return ("Gemini rejected the key (HTTP \(status)) — check \(GeminiClient.keyName) "
                        + "in \(cloudEnvDisplayPath()), and that the API is enabled for it at "
                        + googleCredentialsURL, nil, status)
            case 429:
                // Quota OR rate limit — Google uses one status for both and this app cannot
                // tell them apart from the status alone, so the message must not claim to.
                // Also the status that drives the auto-disable; see `consecutive429s`.
                return ("Gemini quota or rate limit hit (HTTP 429) — retry shortly, or check "
                        + "your quota at \(googleQuotaURL)", nil, status)
            case 500...599:
                // Nothing on this machine is wrong and nothing on this machine can help.
                // Named so the user does not go hunting through their key for a server fault.
                return ("Gemini server error (HTTP \(status)) — transient on Google's side; "
                        + "the on-device text is unaffected", nil, status)
            default:
                return ("Gemini HTTP \(status) — \(body.prefix(200))", nil, status)
            }
        case .decoding(let snippet):
            return ("Gemini response could not be parsed — \(snippet.prefix(160))", nil, nil)
        case .transport(let reason):
            return ("could not reach Gemini — \(reason)", nil, nil)
        }
    }
    // ── Local whisper ────────────────────────────────────────────────────────────────
    // `WhisperClient.ClientError` and `WhisperServerError` each carry an actionable line
    // of their own ("brew install whisper-cpp", the model search path); without these
    // arms they fell to the `NSError` line below as `MicTest.WhisperClient.ClientError
    // code 1` and the text was lost exactly where the trace wanted it. The HTTP status
    // is returned so the trace can name it; the 429 auto-disable in `applyCloudFailure`
    // is Gemini-only, so a local status can never trip it. 503 is "loading model", which
    // only an ADOPTED server mid-`/load` answers — our own child binds after loading
    // (WhisperServerManager.swift header).
    if let we = error as? WhisperClient.ClientError {
        switch we {
        case .httpStatus(503):
            return ("local whisper-server is still loading its model (HTTP 503)", nil, 503)
        case .httpStatus(let status):
            return ("local whisper-server returned HTTP \(status)", nil, status)
        case .unreachable, .emptyResponse, .decoding:
            return ("local whisper — \(we.errorDescription ?? "\(we)")", nil, nil)
        }
    }
    if let se = error as? WhisperServerError {
        return ("local whisper-server could not start — \(se.description)", nil, nil)
    }
    let ns = error as NSError
    return ("\(ns.domain) code \(ns.code) — \(ns.localizedDescription)", nil, nil)
}

/// Handed back from `noteFinalChunk` across the MainActor hop so the chunk loop knows which
/// utterance the cloud pass should annotate, and whether to run it at all. Two separate
/// facts in two separate fields on purpose: an `Int?` doing double duty as "the id" and
/// "yes, run the cloud" reads like a bug the first time somebody else touches it.
struct FinalizedUtterance: Sendable {
    let id: Int
    let runCloud: Bool
    /// Snapshot of `typedSinceLastChunk` taken (on the MainActor, inside `noteFinalChunk`)
    /// at the moment this chunk was cut: exactly the characters `deliver()` injected for
    /// this audio span. Immutable, Sendable, and carried into the detached cloud task so
    /// the correction 1-2 s later knows what text to replace.
    let typedSpan: String
    /// `utteranceSeq` at snapshot time; see AppDelegate.utteranceSeq.
    let typedSpanSeq: UInt64
}

// MARK: - Cross-thread level box

/// The audio tap runs on a realtime render thread; the UI reads on the main thread. This is
/// one of only three things that cross that boundary (the others are AudioPipeline and
/// LiveRecognizer, which own their own synchronisation), and it crosses through a lock.
///
/// @unchecked Sendable is honest here: the lock provides the mutual exclusion the compiler
/// cannot see. Nothing else — no UI, no trace() — happens inside the tap.
final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rms: Float = 0
    private var frames: UInt64 = 0

    /// Largest |sample| seen since the last `drainPeak()`. A running MAXIMUM, not a
    /// snapshot, and that is the whole point of it. `rms` is overwritten by every buffer,
    /// so a reader sampling it at 0.2 Hz sees one ~10 ms window out of every five seconds
    /// and can only describe the room at that instant. Trace 14:26:19-14:41:25 is what that
    /// costs: a 906 s capture produced exactly ONE rms sample, and it could not answer the
    /// question the whole post-mortem turned on — did the Speech service wedge, or did mic
    /// input go attenuated? A peak held across the reporting window answers it. An
    /// attenuated, muted or misrouted input cannot produce a loud sample ANYWHERE in five
    /// seconds; a wedged recogniser is indifferent to how loud the room is.
    ///
    /// A NaN sample cannot poison it: `NaN > peak` is false, so it is simply not taken.
    /// `+inf` IS taken, and unlike the `noiseFloor` tracker — which rejects it, because the
    /// speech gate ACTS on that value — this one keeps it deliberately. Nothing anywhere
    /// branches on `peak`, so `peak=inf` in the trace is an honest report that the tap
    /// delivered a non-finite sample, and the next `drainPeak()` clears it.
    private var peak: Float = 0

    func store(rms newValue: Float, peak peakValue: Float, frameCount: Int) {
        lock.lock()
        rms = newValue
        if peakValue > peak { peak = peakValue }
        frames &+= UInt64(frameCount)
        lock.unlock()
    }

    /// Returns (rms, totalFramesSeen). Frame count proves samples are genuinely arriving
    /// even when the room is silent and the RMS is ~0 — which is the only honest proof that
    /// the tap really ran on the audio thread without trapping.
    func read() -> (Float, UInt64) {
        lock.lock()
        let v = (rms, frames)
        lock.unlock()
        return v
    }

    /// Returns the peak since the previous call and clears it, so the value always
    /// describes the window between two consecutive readings.
    ///
    /// It is deliberately NOT part of `read()`. `read()` has three callers; a
    /// consume-and-reset folded into it would mean each one silently shortens the window
    /// the others report, which is the kind of bug a trace line exists to rule out. One
    /// consumer only: the periodic LEVEL line in `tickStatus`.
    func drainPeak() -> Float {
        lock.lock()
        let v = peak
        peak = 0
        lock.unlock()
        return v
    }

    func reset() {
        lock.lock()
        rms = 0
        peak = 0
        frames = 0
        lock.unlock()
    }
}

// MARK: - Cross-thread recognizer event queue

/// One thing `LiveRecognizer` told us. All payloads are `Sendable`.
enum RecognizerEvent: Sendable {
    /// The whole utterance so far, as currently understood. Supersedes the previous partial.
    case partial(String)
    case final(String)
    case state(LiveRecognizer.State)
}

/// `LiveRecognizer`'s callbacks fire on "any thread" — Speech's own queue, not ours.
///
/// They are NOT allowed to touch the main actor directly, and they must not reach it via
/// `MainActor.assumeIsolated` (that traps when it guesses wrong; this app already crashed
/// that way). The obvious alternative, `Task { @MainActor in … }` per callback, is unsafe
/// for a different reason: a growing partial only makes sense in order, and independently
/// enqueued Tasks give no ordering guarantee — a reordered pair would make us compute a
/// suffix against the wrong baseline and type garbage.
///
/// So callbacks append to this lock-protected FIFO and the main-thread UI timer drains it
/// in order. Same shape as `LevelBox`, same honesty about `@unchecked Sendable`.
///
/// ── WHAT THE OVERFLOW POLICY GUARANTEES, AND WHY THE PREVIOUS ONE DID NOT ────────────
/// This used to justify itself with "partials supersede each other, so dropping the oldest
/// loses nothing that a later partial does not already contain" — and then drop the oldest
/// events of ANY kind. The premise is true only of `.partial`. A `.state(.listening)` is
/// the utterance boundary that resets `injectedForUtterance`; drop one and the ledger goes
/// on describing an utterance that is over, so the next partial shares no prefix with it
/// and the app deletes a whole utterance to type the replacement's first word — the exact
/// failure spelled out at the `.listening` reset in `handleRecognizerState`. A dropped
/// `.final` loses the reconciliation outright. Neither was visible: both were folded into
/// one `dropped` number that read like harmless partial churn.
///
/// The policy now, in order:
///   1. COALESCE AT POST. An incoming `.partial` whose predecessor is also a `.partial`
///      REPLACES it in place — O(1), and lossless because each partial carries the whole
///      utterance so far and `deliver` diffs it against the ledger rather than
///      accumulating deltas. This is what makes overflow nearly unreachable: a wedged main
///      thread now costs one queued partial, not one per recogniser callback.
///   2. DROP A PARTIAL, NEVER A STATE OR A FINAL. Past the soft cap the FIRST `.partial`
///      from the front is removed and counted as `droppedPartials` — the one kind of loss
///      the "a later partial already contains it" argument actually covers.
///   3. PATHOLOGICAL FLOOR. If there is no partial left to sacrifice (a queue that is all
///      `.state`/`.final`, i.e. the main thread has been wedged across many recogniser
///      restarts), the queue is allowed to GROW to `hardCapacity` rather than corrupt the
///      ledger in order to stay small. Only past that does the oldest event go regardless
///      of kind, counted separately as `droppedCritical` so the drain can say so out loud.
/// Memory is still bounded; ledger-relevant events are now lost only in a state the app
/// reports instead of hiding.
final class RecognizerEventBox: @unchecked Sendable {
    /// Soft ceiling. Past this, partials are sacrificed to keep the queue bounded — which
    /// is nearly unreachable now that `post` coalesces them.
    private static let capacity = 512
    /// Hard ceiling, reached only when `capacity` consecutive events are `.state`/`.final`.
    /// Four times the soft cap is a few hundred kilobytes at worst, and it buys the ledger
    /// a large margin before anything load-bearing is thrown away.
    private static let hardCapacity = 2048

    private let lock = NSLock()
    private var events: [RecognizerEvent] = []
    private var droppedPartials = 0
    private var droppedCritical = 0
    private var coalescedAtPost = 0

    func post(_ event: RecognizerEvent) {
        lock.lock()
        defer { lock.unlock() }

        // (1) Coalesce. Only a partial may replace a partial: a `.state` or `.final` at the
        // tail is a boundary the incoming partial has to be interpreted AFTER, so it stays
        // where it is and the partial is appended behind it.
        if case .partial = event, let last = events.last, case .partial = last {
            events[events.count - 1] = event
            coalescedAtPost += 1
            return          // count unchanged, so there is nothing to overflow
        }

        events.append(event)
        guard events.count > Self.capacity else { return }

        // (2) Exactly one event was added, so removing one restores the invariant.
        if let victim = events.firstIndex(where: { e -> Bool in
            if case .partial = e { return true }
            return false
        }) {
            events.remove(at: victim)
            droppedPartials += 1
            return
        }

        // (3) Nothing droppable is left. Grow first; only past the hard cap does a
        // ledger-relevant event go, and then it is counted where the drain will shout.
        if events.count > Self.hardCapacity {
            events.removeFirst()
            droppedCritical += 1
        }
    }

    /// Returns the queued events in order, plus what became of the ones that are not in it.
    /// Three separate counts on purpose: `coalescedAtPost` and `droppedPartials` are
    /// routine bookkeeping, `droppedCritical` is an integrity warning, and a single total
    /// would make the warning unreadable — which is how the old `dropped` hid it.
    func drain() -> (events: [RecognizerEvent], droppedPartials: Int,
                     droppedCritical: Int, coalescedAtPost: Int) {
        lock.lock()
        let queued = events
        let dp = droppedPartials
        let dc = droppedCritical
        let ca = coalescedAtPost
        events.removeAll(keepingCapacity: true)
        droppedPartials = 0
        droppedCritical = 0
        coalescedAtPost = 0
        lock.unlock()
        return (queued, dp, dc, ca)
    }

    /// Discard anything left over from a previous session so a late partial cannot be
    /// mistaken for the first partial of the next utterance.
    func clear() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        droppedPartials = 0
        droppedCritical = 0
        coalescedAtPost = 0
        lock.unlock()
    }
}

// MARK: - Dictation engines

/// Which engine turns microphone audio into live text. Raw values ARE the
/// `UserDefaults["dictationEngine"]` strings — one spelling, so a typo cannot make the
/// stored preference and the code disagree about what "geminiLive" means.
enum DictationEngineKind: String, Sendable {
    /// `LiveRecognizer` — Apple's on-device `SFSpeechRecognizer`. THE DEFAULT, and the
    /// only one that keeps every sample of the user's voice on this Mac.
    case apple
    /// `GeminiLiveRecognizer` — streams microphone audio to Google over a WebSocket for
    /// as long as dictation is running. Opt-in, never a default: see `toggleEngine`.
    case geminiLive

    /// What the menu calls it. The parenthetical is not decoration — it is the whole
    /// privacy difference, and it belongs in the item's TITLE rather than only in the
    /// tooltip, because a title is the part a user reads without hovering.
    var menuName: String {
        switch self {
        case .apple: return "Apple (on-device)"
        case .geminiLive: return "Gemini Live (cloud)"
        }
    }

    /// The noun used in messages that name the recogniser to the user. "On-device
    /// recogniser" is a lie the instant the active engine is streaming to Google, and a
    /// lie about where someone's voice is going is the one class of wrong string in this
    /// app that is not merely cosmetic.
    var recognizerNoun: String {
        switch self {
        case .apple: return "On-device recogniser"
        case .geminiLive: return "Gemini Live recogniser"
        }
    }
}

/// The consumer-facing shape shared by `LiveRecognizer` and `GeminiLiveRecognizer`.
///
/// ── WHY A PROTOCOL, AND WHY IT LOOKS LIKE THIS ────────────────────────────────────────
/// The two types already expose the same eight members (`onPartial`/`onFinal`/`onState`/
/// `isSupported`/`start`/`stop`/`append`/`setContextualStrings`), so an
/// `enum Engine { case apple(...), gemini(...) }` with switch-based forwarding would mean
/// eight switches whose only content is "call the same method on whichever payload" — the
/// churn a protocol exists to remove. Conformance is declared here in extensions rather
/// than on the types themselves precisely so neither engine file has to change.
///
/// ONE MEMBER IS NOT A PASS-THROUGH, and it is the reason this protocol has a `bindEvents`
/// instead of an `onState` property. The two engines carry DISTINCT `State` enums with
/// identical cases, so no single property signature can satisfy both — and an extension
/// cannot add a member named `onState` to a type that already has one. Rather than invent
/// a third state type and rewrite every consumer, the callback wiring is the protocol
/// requirement and `LiveRecognizer.State` stays the currency: `GeminiLiveRecognizer`'s
/// cases are mapped to it at the one point they cross into the app. That keeps
/// `RecognizerEvent`, `RecognizerEventBox`, `handlePartial`, `handleFinal`,
/// `handleRecognizerState`, `deliver` and the entire injection path bit-for-bit unchanged,
/// which is the whole point: this file's hard-won utterance bookkeeping is not being asked
/// to learn a second vocabulary.
///
/// `Sendable` is a REQUIREMENT, not a courtesy: `beginCapture` captures the resolved engine
/// in the `@Sendable` tap closure and `processTap` calls `append` from the realtime audio
/// thread. Both concrete types are already `@unchecked Sendable` with no actor isolation,
/// so the existential inherits exactly the guarantee `processTap` documents.
protocol DictationEngine: AnyObject, Sendable {
    var isSupported: Bool { get }
    func start() throws
    func stop()
    func append(_ buffer: AVAudioPCMBuffer)
    func setContextualStrings(_ terms: [String])
    /// Point this engine's three callbacks at the app's event queue. Called on the main
    /// actor for the ACTIVE engine only (see `wireRecognizer`).
    func bindEvents(to box: RecognizerEventBox)
    /// Drop the callbacks, so a stopped engine that keeps talking — a reconnect loop, a
    /// late retry report — cannot post into a session it is not running.
    func unbindEvents()
}

extension LiveRecognizer: DictationEngine {
    func bindEvents(to box: RecognizerEventBox) {
        // Verbatim what `wireRecognizer` used to inline, moved rather than rewritten: the
        // closures are `@Sendable`, run on Speech's own queue, capture only the box, and
        // touch neither `self` nor the main actor nor `trace()`.
        onPartial = { text in box.post(.partial(text)) }
        onFinal = { text in box.post(.final(text)) }
        onState = { state in box.post(.state(state)) }
    }

    func unbindEvents() {
        onPartial = nil
        onFinal = nil
        onState = nil
    }
}

extension GeminiLiveRecognizer: DictationEngine {
    func bindEvents(to box: RecognizerEventBox) {
        onPartial = { text in box.post(.partial(text)) }
        onFinal = { text in box.post(.final(text)) }
        // THE ONE TRANSLATION IN THIS FILE. Two enums, three identical cases, and the
        // exhaustive switch is deliberate: if `GeminiLiveRecognizer.State` ever grows a
        // fourth case, this stops compiling and someone has to decide what the consumer
        // should do with it — which is strictly better than a `default:` quietly mapping
        // a new failure mode onto `.idle`.
        onState = { state in
            let mapped: LiveRecognizer.State
            switch state {
            case .idle: mapped = .idle
            case .listening: mapped = .listening
            case .unavailable(let reason): mapped = .unavailable(reason)
            }
            box.post(.state(mapped))
        }
    }

    func unbindEvents() {
        onPartial = nil
        onFinal = nil
        onState = nil
    }
}

// MARK: - Cross-thread flush request flag

/// Set on the main actor when the release drain completes; consumed by the background
/// chunk loop as it exits. It tells the loop to force-finalize (`AudioPipeline.flush()`)
/// whatever speech the trailing-silence gate never released — in a room whose ambient
/// noise sits above the silence threshold, that gate never opens at all, and without this
/// flag every utterance would end the session as `finalChunks=0 cloudSent=0`.
///
/// One box per CLOUD-ENABLED session, created in `beginCapture` and captured by that
/// session's chunk loop, so a stale request can never leak into the next session's loop.
/// A session started with the cloud pass disabled has no chunk loop and no box —
/// `flushRequest` stays nil and `drainElapsed`'s optional-chained request is a no-op.
/// Same lock-box shape as `LevelBox`, same honesty about `@unchecked Sendable`.
final class FlushRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    /// Returns true at most once per `request()`.
    func consume() -> Bool {
        lock.lock()
        let r = requested
        requested = false
        lock.unlock()
        return r
    }
}

// MARK: - Trace counters

/// The instrumentation counter set, kept TWICE: once for the whole process, once for the
/// capture currently running.
///
/// MEASURED 17:54: two consecutive captures printed the *identical* "capture stopped" line
/// — `partials=146 coalesced=14 injectedChars=315` — even though the second capture lasted
/// 1.4 s and typed nothing at all. Every counter was a process-lifetime accumulator that
/// nothing anywhere ever reset, so a line that reads as this capture's statistics was
/// really "everything since launch", and two captures in a row could not possibly differ.
/// Only `frames` was ever genuinely per-capture. These numbers had been used as the
/// verification evidence for earlier bug fixes, which means the instrument was certifying
/// passes it had not measured — the worst failure mode a debugging tool has.
///
/// So: `lifetime` accumulates for the life of the process (the AUTOSTART summaries want
/// whole-run totals and say so), and `thisCapture` is zeroed in `beginCapture` right next
/// to `levelBox.reset()` so that these counters and the `frames` printed beside them cover
/// exactly the same span of wall time.
///
/// EVERY increment must touch BOTH instances. The cheap audit: grep `lifetime.` and
/// `thisCapture.` over this file and compare the hit counts — a mismatch is a half-updated
/// increment site, which is how the lie gets back in.
///
/// CAVEAT, the cloud fields: `finishCapture` deliberately does NOT cancel `cloudTask` —
/// the cloud pass answering after the key is released is the entire point of it. A round
/// trip that lands after the "capture stopped" line has already printed is therefore
/// missing from that line.
///
/// THIS CAVEAT USED TO BE WRONG IN BOTH DIRECTIONS (review finding), and the correction is
/// in the file rather than in a commit message because "read `lifetime` as the exact count"
/// is the same species of lie as the 17:54 line above: an instrument certifying a number it
/// does not measure. What it claimed was that a late result lands in the NEXT capture's
/// bucket, and that `lifetime` was exact. What the code does:
///
///   - The misattribution it warned about CANNOT happen. `beginCapture` bumps
///     `captureGeneration` before any late MainActor hop can run, so by the time a next
///     capture exists to be mis-credited, the `generation == captureGeneration` guards in
///     `applyCloudResult` and `applyCloudFailure` have already failed.
///
///   - `lifetime` under-counts for exactly that reason. Those guards `return` ahead of BOTH
///     increments — `if !cancelled { lifetime.cloudErrors += 1; thisCapture.cloudErrors += 1 }`
///     never runs — so a round trip the user out-ran by releasing and pressing again is
///     counted nowhere at all. `AUTOSTART CLOUD SUMMARY` can honestly print
///     `sent=3 applied=0 unapplied=0 errors=0` while three results came back and were
///     discarded by design.
///
/// So: read EVERY cloud field, per-capture and lifetime alike, as a LOWER BOUND on results
/// that came back. `cloudSent` is the exception and the one number to anchor on:
/// `registerCloudTask` increments it on the dispatch hop, on the main actor, while the
/// capture is still live. `cloudSkipped` is outside the arithmetic entirely — both of its
/// increment sites are in `noteFinalChunk`'s gate, counting utterances that were never sent.
///
/// What `sent` minus (`applied` + `unapplied` + `errors`) counts is round trips that
/// answered into nothing, and that is TWO populations, not one: the ones the
/// generation/utterance guards discarded, AND the ones `applyCloudFailure` saw with
/// `cancelled == true`, which pass the guards and then deliberately increment nothing (a
/// request we cancelled ourselves is not a cloud error — `noteFinalChunk`'s supersede
/// branch says the same thing from the other end). So the difference is a floor on "answers
/// thrown away", not a measurement of staleness; do not quote it as one.
/// The discards are not invisible, but they are not
/// symmetrical either: `applyCloudResult` traces "superseded … discarded" on its way out
/// while `applyCloudFailure` returns silently, so a discarded FAILURE leaves no mark
/// anywhere in the trace. `secureInputRefusals` shares the caveat and is easy to miss doing
/// it: one of its two increment sites is the live injection path, but the other is
/// `applyCloudResult` refusing to auto-apply into a secure field, which runs on the same
/// late hop as the cloud fields. Everything else here is incremented on the main actor
/// while the capture is still live and is exact.
private struct TraceCounters {
    var partialsSeen = 0
    /// Partials skipped by tickUI because a newer partial arrived on the same tick.
    var partialsCoalesced = 0
    var finalsSeen = 0
    var injectedChars = 0
    var injectFailures = 0
    /// Non-extension partials (revision, word merge, retraction) where the stale tail was
    /// successfully deleted and retyped in the document.
    ///
    /// This replaces a single `divergences` field, which was renamed rather than kept
    /// because its old readings were worthless and a reader must not carry them forward:
    /// `repairDivergence` had no call sites, so `divergences=0` across all 4029 field trace
    /// lines meant "the code cannot run", not "no divergence occurred". Two names that did
    /// not exist before make that discontinuity impossible to miss in a grep.
    var divergencesRepaired = 0
    /// Non-extension partials where `replaceLastInserted` REFUSED and the document was
    /// deliberately left untouched. This is the number that matters when judging whether
    /// the focused app can host live revision at all.
    var divergencesRefused = 0
    /// Repairs `repairDivergence` REFUSED TO ATTEMPT because the effective change — the
    /// already-typed clusters the write would delete and NOT put back identically — was
    /// over `reanchorMaxStaleChars`. Counted BEFORE `replaceLastInserted` is called, so the
    /// document was never touched; each one is then routed through
    /// `resolveUnrepairedRevision` as `.capRefused` and shows up again there as a
    /// `divergencesRefused` re-anchor — partial or final — in an app that accepts repair.
    /// It used to fresh-start on a partial instead, and run 7 measured what that did in
    /// TextEdit (`TEST-2026-09-03-run7-trace.txt` lines 40-68): six of the seven, all on
    /// the first sentence, each retyped the whole transcript, so that sentence stood six
    /// times and the correction pass refused its own fix against the inflated span. Read
    /// it as "whole-sentence overwrites that did not happen": the shape it stops is
    /// `TEST-2026-08-31-run5-trace.txt` line 115, `replaced 175 stale chars with 178
    /// chars`.
    var repairsRefusedTooLarge = 0
    /// Pure retractions (`replacement.isEmpty`) refused because more than
    /// `retractionMaxStaleChars` already-typed clusters would have been deleted with
    /// nothing typed back. Disjoint from `repairsRefusedTooLarge` — a refused retraction
    /// is counted here only — so the two sum to every repair the caps stopped.
    var retractionsRefused = 0
    /// Revisions whose stale tail was too long to strand (see `reanchorMaxStaleChars`) and
    /// which were answered instead by typing the whole transcript again after a separator.
    /// Each one leaves visibly duplicated text in the user's document, so this is the price
    /// of the strand cap: it is the number to read if the cap ever needs re-tuning, and a
    /// large value against a small `divergencesRefused` means the refusals are arriving at
    /// `lcp == 0` rather than mid-word.
    ///
    /// Since run 7 this is reachable ONLY from the app-refused route on a partial — an
    /// app that has latched `finalOnlyInjection`, or one that just refused a repair for
    /// real. A cap refusal in an app that accepts repair re-anchors instead, so on
    /// TextEdit this should read 0. The 13 in run 7 were 7 cap refusals (now re-anchors)
    /// plus 6 from the structural route after focus drifted to ChatGPT at trace line
    /// 181; those 6 stay, and a focus drift will produce them again.
    var freshStarts = 0
    var secureInputRefusals = 0
    var finalChunks = 0
    var cloudSent = 0
    var cloudApplied = 0
    var cloudUnapplied = 0
    var cloudErrors = 0
    /// Chunks the cloud answered with an empty transcript — silence, not failure. Split out
    /// of `cloudErrors` because Google returns empty by design for a quiet span and billed
    /// it normally: folding the two together made every capture ending on silence read as a
    /// failing account. A single total cannot tell "the request broke" from "there was
    /// nothing to hear", and those call for opposite reactions.
    var cloudEmpty = 0
    var cloudSkipped = 0
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // ---- The only UI ---------------------------------------------------------------
    private let hud = DictationHUD()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    private let dictationItem = NSMenuItem()
    private let engineItem = NSMenuItem()
    private let localDictationItem = NSMenuItem()
    /// "Correction: …" — the parent of `correctionMenu`, its title carrying the state.
    private let cloudItem = NSMenuItem()
    /// One entry per `CorrectionProviderKind`, each naming its privacy consequence.
    private let correctionMenu = NSMenu()
    private let correctionOffItem = NSMenuItem()
    private let correctionLocalItem = NSMenuItem()
    private let correctionGeminiItem = NSMenuItem()
    private let autoCorrectItem = NSMenuItem()
    private let daemonRestartItem = NSMenuItem()
    private let micStatusItem = NSMenuItem()
    private let speechStatusItem = NSMenuItem()
    private let axStatusItem = NSMenuItem()
    private let tapStatusItem = NSMenuItem()
    private let activityItem = NSMenuItem()
    private let copyTranscriptItem = NSMenuItem()
    private let copyCloudItem = NSMenuItem()
    /// The BUTTON to Google's quota/usage page, labelled with the one usage number this
    /// app can actually vouch for.
    ///
    /// Under fal this line showed a live credit balance fetched from an API. Google has no
    /// equivalent an API key may read — Cloud Billing wants OAuth — so there is nothing to
    /// fetch and the probe machinery that fetched it is gone (see the cloud section note).
    /// What survives is the affordance, because "how much have I used" still has an answer;
    /// it just lives one click away instead of in the menu. The number on the line is this
    /// Mac's own tally, which is why it deliberately says "this Mac" and not "your account".
    private let creditItem = NSMenuItem()
    /// What this Mac has sent to Gemini, lifetime. Pure read-out, hidden until there is
    /// something to report.
    private let spendItem = NSMenuItem()

    // ---- Machinery -----------------------------------------------------------------
    private let hotkey = HotkeyMonitor()
    private let injector = TextInjector()
    private let recognizer = LiveRecognizer()
    /// The opt-in second engine. Constructed unconditionally at init, exactly as
    /// `cloudSetup` is, because construction is inert: nothing connects to Google until
    /// `start()`, and a lazily-built engine would only move the same allocation to the
    /// first capture that selects it — in the middle of the hotkey's latency budget.
    private let geminiRecognizer = GeminiLiveRecognizer()
    private let events = RecognizerEventBox()
    private let levelBox = LevelBox()

    private var uiTimer: Timer?
    private var statusTimer: Timer?
    private var drainTimer: Timer?

    /// Audio-flow watchdog (see `tickStatus`). The tap delivers buffers continuously while
    /// the engine is alive -- frames grow even in a silent room -- so a frame counter that
    /// stops moving means the engine/tap died (CoreAudio route change, device sleep, ...).
    /// Measured in production: after ~90 s of dictation the tap went silent mid-session and
    /// typing just stopped, with the recogniser eventually reporting "No speech detected".
    private var watchdogLastFrames: UInt64 = 0
    private var watchdogStalledTicks = 0

    /// State for the unconditional LEVEL line in `tickStatus`. That method runs at 1 Hz, so
    /// the counter is literally "ticks since the last line" and 5 means ~5 s;
    /// `levelLineLastFrames` is the previous line's frame count, so each line can print a
    /// DELTA (240000 per line at 48 kHz is exactly 5 s of audio — anything less is a
    /// stalling tap, and that is readable at a glance in a way a running total is not).
    ///
    /// WHY AN UNCONDITIONAL LINE EXISTS AT ALL. `levelTrace` was wired only to watchdog
    /// strikes and to `finishCapture` — both of them paths that never ran during the
    /// 14:26:19-14:41:25 failure — so a 906 s capture produced exactly ONE rms sample, taken
    /// twelve minutes after the recogniser had stopped producing text. Was the room loud?
    /// Was the floor climbing? Were loud ticks accumulating? Was audio still arriving? Every
    /// question the post-mortem needed to ask was unanswerable from the trace. A measurement
    /// that only prints once something is already wrong cannot describe how it got there.
    private var levelLineTicks = 0
    private var levelLineLastFrames: UInt64 = 0

    /// Running maximum of the per-tick peaks since the last LEVEL line. The peak is drained
    /// from `LevelBox` every tick because the speech gate needs THIS second's value, so the
    /// five-second window the LEVEL line reports has to be reassembled here rather than left
    /// to accumulate in the box. Zeroed with the other two in `beginCapture`.
    private var levelLinePeak: Float = 0

    /// Recogniser-liveness watchdog (see `tickStatus`). The audio watchdog above only
    /// catches a dead ENGINE (frames stop). The complementary failure -- recogniser dead
    /// or wedged in a retry loop while the engine keeps delivering -- leaves frames
    /// flowing and typing silently stopped. Signal: the room is audibly loud (speech-level
    /// RMS) yet the recogniser has produced no partial/final/state for many seconds.
    private var lastRecognizerEventAt = Date.distantPast
    private var recognizerStalledTicks = 0

    /// Speech-level ticks accumulated SINCE the last recogniser event. The wedge
    /// discriminator that survives human behaviour: when the recogniser dies mid-speech,
    /// these accumulate while the user is still talking (before they notice and stop), so
    /// the count persists through their silence; during a deliberate quiet pause with the
    /// toggle on, nothing accumulates and the watchdog stays asleep. Instantaneous RMS at
    /// check time failed both ways (user already quiet -> no trigger on real wedges), and
    /// no gate at all bounced idle sessions every 6 s (measured 14:17).
    ///
    /// "Speech-level" is no longer a fixed RMS literal — it is `speechThreshold`, a ratio
    /// over the MEASURED `noiseFloor` of the room. See `noiseFloor` for why the literal had
    /// to go and what the measurements behind it still say.
    private var loudTicksSinceRecognizerEvent = 0

    /// Escalation damper for the recogniser watchdog. Measured 14:23: this room's AMBIENT
    /// RMS sits at/above the old fixed 0.0025 loud-tick threshold (and genuine quiet speech
    /// on this mic measures below 0.01, so that literal could not simply be raised without
    /// going deaf to real speech). Ungated, ambient ticks alone climbed the whole ladder on
    /// silence -- bounce, full restart, again -- with fal confirming the churned windows
    /// held no speech at all (0-char transcripts). Both measurements still stand; what has
    /// changed is that the gate is now a ratio over the measured `noiseFloor` instead of
    /// that literal, so ambient no longer ticks at all. The damper STAYS: a ratio gate is
    /// evidence of a sound, never evidence of recognition, and 16:09-16:15 on 2026-08-26
    /// showed what an over-armed ladder does when it reaches the top. A FULL restart
    /// therefore still needs evidence the recogniser was
    /// genuinely working this session and then died: `sessionSawPartial` (a partial was
    /// drained this capture session) always arms escalation; a session that never
    /// produced a single partial gets at most one speculative restart
    /// (`escalationsThisSession`), after which strikes only bounce -- cheap -- until a
    /// real partial re-arms the ladder. The count deliberately survives the watchdog's
    /// own self-heal restart (which lands back in `beginCapture` with the room just as
    /// silent) and resets only when a DELIBERATE stop ends the session (`finishCapture`
    /// with `wantsDictation` false).
    private var sessionSawPartial = false
    private var escalationsThisSession = 0

    /// TIER 3 state — see the daemon-restart tier in `tickStatus`. Counts "escalation
    /// suppressed" bounces since the last restart of any kind: by the time one fires the
    /// ladder has already spent a bounce and its one speculative full restart, so two MORE
    /// of them in a row mean nothing in-process can revive recognition. Reset wherever a
    /// real partial arrives (the recogniser is demonstrably alive) and by tier 3 itself.
    private var suppressedBouncesSinceRestart = 0

    /// Wall time of the last REAL partial (any session, this launch). Tier 3's kill
    /// switch may only fire when recognition provably worked recently: every measured
    /// wedge struck MID-dictation, seconds after healthy partials. Ambient room noise
    /// USED to satisfy the loud-ticks gate in this room outright (documented above;
    /// fal-verified 0-char windows), so without this stamp an idle toggled-on session
    /// would eventually `kill -9` a SYSTEM service off pure noise — possibly clobbering
    /// another app's transcription. `noiseFloor` closed that particular hole, and this
    /// stamp is deliberately NOT retired with it: a self-calibrating gate is still only
    /// evidence that a SOUND happened, and 16:09-16:15 on 2026-08-26 is what one gate too
    /// few costs (two `pkill`s of a system service, the first provably restoring nothing).
    /// distantPast at launch = tier 3 stays locked until dictation has actually produced
    /// text once.
    private var lastRealPartialAt = Date.distantPast

    /// Wall time of the last REAL recogniser output — partial OR final — this launch.
    /// Diagnostics only: the periodic LEVEL line in `tickStatus` prints the age of this
    /// stamp, and nothing anywhere branches on it.
    ///
    /// DELIBERATELY SEPARATE FROM `lastRealPartialAt` directly above, which it otherwise
    /// looks like a duplicate of. Folding the two together would be a silent behaviour
    /// change, not a tidy-up: that stamp is tier 3's arming condition — the gate on
    /// `kill -9` of a system service — and widening it to finals would arm that kill from an
    /// event class it was never measured against. A trace stamp is free to be the broader of
    /// the two precisely because nothing acts on it.
    private var lastRealOutputAt = Date.distantPast

    /// Rate limiter for tier 3: never kill the system speech daemon more than once per
    /// two minutes, no matter how the counters land. `distantPast` so the first wedge
    /// after launch is never blocked.
    private var lastDaemonKillAt = Date.distantPast

    /// Rate limiter for tier 3's DETECTOR line, deliberately a separate stamp from
    /// `lastDaemonKillAt` and deliberately the same 120 s. Stamping the kill's own limiter
    /// from the detector would both claim a kill that never happened and change
    /// `tier3Armed`'s second condition, which is exactly what the "acts on nothing" promise
    /// in that branch forbids. Same interval, though, because with the toggle ON the kill
    /// can fire at most once per two minutes: one line per 120 s is one line per
    /// counterfactual kill, which is the quantity a human re-litigating the default wants
    /// to count. Only ever written on the toggle-OFF path, so the ON path is untouched.
    private var lastTier3WouldFireLoggedAt = Date.distantPast

    /// Rate limiter for the full capture restart that `LiveRecognizer`'s
    /// `persistent recognition failure` report triggers — see the `.unavailable` branch of
    /// `handleRecognizerState`. That file re-emits the report on every retry cycle for as
    /// long as the failure lasts, at a backoff capped at 8 s, so an unlimited restart per
    /// report is a restart loop. 15 s sits comfortably above that cap: at most one restart
    /// per window no matter how often the report arrives, and the window is short enough
    /// that a genuinely recoverable wedge is retried promptly rather than waited out.
    /// `distantPast` so the first report after launch is never blocked.
    private var lastPersistentFailureRestartAt = Date.distantPast
    private nonisolated static let persistentFailureRestartInterval: TimeInterval = 15

    /// The room's measured noise floor, in the same RMS units the tap stores, tracked
    /// asymmetrically over the 1 Hz `tickStatus` samples. It is what decides which samples
    /// count as speech — see `speechThreshold`.
    ///
    /// WHY THIS REPLACED A CONSTANT. The loud-tick gate used to be the literal
    /// `rms >= 0.0025`, and the comments around it recorded — correctly — that THIS room's
    /// ambient RMS sits at/above 0.0025 while genuine quiet speech on this mic measures
    /// below 0.01, so the literal could not be raised without going deaf. Those numbers are
    /// still true; the SHAPE was the bug. At 1 Hz an ambient above the literal made
    /// `loudTicksSinceRecognizerEvent >= 3` true after three seconds of an EMPTY ROOM,
    /// every single time, so every tier of the ladder was armed by noise and every damper
    /// and backoff added since existed to compensate for one broken primitive. Measured
    /// 16:09-16:15 on 2026-08-26: the ladder climbed all the way and fired `pkill` on a
    /// macOS system service TWICE. The first kill was followed immediately by
    /// `kAFAssistantErrorDomain error 1107` and 3.5 more minutes of failure — it restored
    /// nothing and bought self-inflicted throttling. The second is ambiguous.
    ///
    /// A ratio over a MEASURED floor is self-calibrating and needs no per-room tuning:
    /// steady noise — fan, aircon, hum — is tracked BY the floor, so its own ratio
    /// converges towards 1.0 and it can never tick, here or anywhere else. Speech sits
    /// 10-30 dB above the floor and always ticks.
    ///
    /// THE ASYMMETRY, and why these two coefficients. `noiseFloorFall` = 0.1 per tick
    /// (~10 s time constant) so the floor drops into a newly quiet room within seconds;
    /// `noiseFloorRise` = 0.005 per tick (~200 s) so speech, which is brief relative to that
    /// window, barely lifts it. The recursion converges as `1 - (1 - rate)^n`, so both worst
    /// cases are arithmetic, not guesswork — simulated at ambient 0.003 before these
    /// coefficients were committed:
    ///   - 60 ticks of UNBROKEN speech 30 dB up lifts the floor to 8.95x its start, putting
    ///     the threshold at 0.0805 while the speech is at 0.0948 — still ticking. The gate
    ///     does go deaf at tick 75 of speech with NO gap at all, which is out of reach for
    ///     two independent reasons: three ticks arm the ladder and it acts at six, and real
    ///     speech has inter-word gaps where the 0.1 fall rate claws back 19% of the
    ///     excursion every two seconds.
    ///
    ///     THE FIRST OF THOSE TWO REASONS IS CONDITIONAL, and this paragraph used to assert
    ///     it flatly. "Arms at three, acts at six" is only true while the tick count
    ///     ACCUMULATES monotonically across a wedge — and it did not, because the `.state`
    ///     branch of the event pump used to zero the counter. The 20 s request rotation
    ///     emits a `.state` every cycle, so under continuous speech the ladder re-armed
    ///     from zero inside each 20 s window while this rise coefficient lifted the floor
    ///     underneath it, and it never reached three. That is not a hypothetical: capture
    ///     14:26:19-14:41:25 held a hot microphone for twelve minutes after the recogniser
    ///     stopped producing text, with ZERO strikes in ~725 ticks. The reset is gone (see
    ///     the `.state` branch, which spells out the proof), the counter now clears only on
    ///     real output, on a strike, or at a session boundary, and only with that true does
    ///     the arithmetic above describe the shipped gate. Do not re-add a clear anywhere
    ///     that is not one of those three; it silently invalidates this whole paragraph.
    ///   - a genuine 5x STEP in ambient (aircon switching on) ticks spuriously for exactly
    ///     37 ticks until the floor catches up. That window can reach a tier-1 bounce and,
    ///     at most once, a tier-2 restart; it cannot reach tier 3, which additionally needs
    ///     a real partial inside 300 s.
    ///
    /// KNOWN BLIND SPOT, written down so it is diagnosable instead of surprising: at ratio
    /// 3.0 an ambient of 0.004 puts the threshold at 0.012, above the sub-0.01 quiet speech
    /// this mic measures — a quiet speaker in a moderately noisy room stops arming the
    /// watchdog. Dictation itself is unaffected; only the watchdog goes to sleep. The
    /// periodic LEVEL line in `tickStatus` is what makes this recognisable: it prints
    /// `rms`/`floor`/`thr` (and the loud-tick count) every ~5 s of every capture, whereas
    /// the watchdog's own lines print only when the watchdog FIRES — which is precisely
    /// what a sleeping watchdog never does, so they cannot evidence their own absence. Do
    /// not add a compensating gate on a hunch — get the numbers out of the trace first.
    private var noiseFloor: Float = 0

    /// False until the first tick of a capture that carried real audio.
    ///
    /// Cleared by `beginCapture`'s FULL-start path so a floor measured in another session
    /// (possibly another room, hours ago) can never gate this one. The drain-cancel resume
    /// deliberately does not clear it: that continues the same engine session in the same
    /// room, exactly as it continues the same `frames` count.
    ///
    /// Seeded from the first sample AT OR ABOVE `absoluteQuietFloor`, and the lower bound
    /// is load-bearing: `beginCapture` calls `levelBox.reset()`, so a tick landing before
    /// the tap has stored anything reads exactly 0. Seeding 0 would put `speechThreshold`
    /// back on `absoluteQuietFloor` — the old broken constant — and the 0.005 rise then
    /// needs 81 ticks at this room's 0.003 ambient before the threshold climbs back up to
    /// the ambient itself: it would reproduce the exact bug this tracker replaces for the
    /// first ~1.4 minutes of EVERY capture, which is longer than most of them.
    ///
    /// The bound used to be `> 0`, which admits ANY positive value and therefore admits the
    /// same failure by a different route (review finding). A fade-in or route-switch
    /// artifact — Bluetooth, AirPods, an aggregate device coming up — delivers samples
    /// around 3e-4, three orders of magnitude under speech and an order under this room's
    /// ambient. Seeding there pins `speechThreshold` to `absoluteQuietFloor` exactly as
    /// seeding 0 does, and the same arithmetic (both counts recomputed from the 0.005 rise
    /// against a 0.003 ambient, same criterion) says it takes 60 ticks — a full minute of
    /// the old bug — to climb out. `absoluteQuietFloor` is the natural bound because it is
    /// already the value below which the gate refuses to trust a measured floor at all.
    ///
    /// A room whose ambient never reaches 0.0025 therefore never seeds, `noiseFloor` stays
    /// 0, and `speechThreshold` rides `absoluteQuietFloor` for the whole capture. That is
    /// the DESIGNED resting state, not a missed seed — it is precisely what that constant
    /// is documented to be for — so do not "fix" it by lowering this bound. The sustained
    /// `rms == 0` case is the same state and is safe for the same reason.
    ///
    /// Seeding from a live sample can only OVER-estimate (if the user is already talking on
    /// tick one), which is the safe direction — it makes the watchdog harder to arm — and
    /// the 0.1 fall rate settles it within seconds anyway.
    private var noiseFloorSeeded = false

    /// One `NOISE FLOOR: non-finite RMS sample` line per capture, not one per tick. See the
    /// rejection branch in `tickStatus`: the condition can persist for a whole capture, and
    /// a 1 Hz flood in the trace file would bury the ladder lines it is meant to be read
    /// beside. Cleared with the floor itself in `beginCapture`'s full-start path.
    private var nonFiniteRMSTracedThisCapture = false

    /// Floor under the floor. This is the ORIGINAL fixed loud-tick threshold and it survives
    /// on purpose — it is not leftover dead code. In a near-silent room the measured
    /// `noiseFloor` approaches zero and `noiseFloor * speechOverFloorRatio` would become a
    /// hair-trigger that any tiny transient clears; clamping the threshold up to this value
    /// keeps the old, known-workable sensitivity as the minimum.
    private nonisolated static let absoluteQuietFloor: Float = 0.0025

    /// How far above the measured floor a sample must sit to count as speech: 3.0, about
    /// +9.5 dB. Steady noise converges to a ratio of 1.0 by construction (the floor tracks
    /// it) while speech measures 10-30 dB up, so there is a wide gap either side of 3.0.
    /// See `noiseFloor` for the one case where there is not.
    private nonisolated static let speechOverFloorRatio: Float = 3.0

    /// The peak counterpart to the ratio above, for the second arming path in `tickStatus`.
    /// Higher than 3.0 because it is compared against a per-second MAXIMUM rather than a
    /// single-buffer average, and broadband room noise already has a crest factor of roughly
    /// 4-8 — a peak gate at the rms ratio would arm on ambient alone.
    ///
    /// 8.0 is read off the measurements quoted at the gate: with `floor` at 0.00425 this
    /// puts the peak threshold at 0.034, against dictation peaks of 0.10-0.17. That is a
    /// 3-5x margin on the speech side, and it sits above the crest range of an ambient whose
    /// rms is the floor itself. It is deliberately the LESS sensitive of the two ratios: the
    /// rms path is unchanged and still arms on its own, so this one only has to catch the
    /// case rms provably misses — peaky speech sampled in the gaps between words.
    private nonisolated static let peakOverFloorRatio: Float = 8.0

    /// Per-tick tracking coefficients — fast down, slow up. Derived on `noiseFloor`, along
    /// with the two worst cases they were chosen against.
    private nonisolated static let noiseFloorFall: Float = 0.1
    private nonisolated static let noiseFloorRise: Float = 0.005

    /// The live speech gate: a sample strictly above this is a loud tick. ONE definition,
    /// read by `tickStatus` (the ladder and every trace it prints) and by `finishCapture`
    /// (the "capture stopped" line). Two arithmetic sites would be free to drift, and a
    /// trace line printing a threshold the gate did not actually use is the same class of
    /// lie `TraceCounters` exists to document.
    private var speechThreshold: Float {
        max(Self.absoluteQuietFloor, noiseFloor * Self.speechOverFloorRatio)
    }

    /// The gate for the peak arming path — same shape as `speechThreshold` and for the same
    /// reason (one definition, so the trace can never print a threshold the gate did not
    /// use). The floor under it is scaled by the same 4x that separates the two ratios, so a
    /// near-silent room where `noiseFloor` never seeds does not leave this path riding a
    /// value calibrated for single-buffer averages.
    private var peakSpeechThreshold: Float {
        max(Self.absoluteQuietFloor * 4, noiseFloor * Self.peakOverFloorRatio)
    }

    /// The `rms=… floor=… thr=…` group, so every watchdog trace, the "capture stopped" line
    /// and the periodic LEVEL line carry the same three numbers in the same shape. Five
    /// decimals because four leaves barely two significant digits at these magnitudes. The
    /// previous debugging round climbed all three tiers and killed a system service twice
    /// without one line anywhere recording what the gate had measured; this is the fix for
    /// that, and it is a requirement of the design, not a convenience.
    ///
    /// The third caller is the reason the first two are no longer sufficient. Both of them
    /// fire only on an EVENT — a strike, a teardown — so between events they say nothing,
    /// and a 906 s capture in which no event ever fired (14:26:19-14:41:25) produced exactly
    /// one sample of these numbers, twelve minutes after the fact. `tickStatus` now emits
    /// this group unconditionally while capturing; see `levelLineTicks`.
    ///
    /// `floor` prints `(never measured)` rather than `0.00000` when the tracker has not
    /// seeded (review finding): those are different facts and only one of them is a
    /// measurement. A capture shorter than one `tickStatus` tick used to render the second
    /// as the first — `floor=0.00000 thr=0.00250` reads as "the room measured silent" when
    /// nothing was ever sampled. `thr` stays numeric in that state on purpose: whatever the
    /// floor's provenance, `absoluteQuietFloor` is genuinely the threshold the gate used.
    ///
    /// `loudTicks` is the strike's EVIDENCE and is passed only by the watchdog ladder — see
    /// the capture at the top of the strike branch in `tickStatus` for why it has to be read
    /// before the counter is zeroed, and why the label spells out that it is history rather
    /// than a reading from this tick.
    private func levelTrace(_ rms: Float, loudTicks: Int? = nil) -> String {
        let floorPart = noiseFloorSeeded
            ? String(format: "floor=%.5f", Double(noiseFloor))
            : "floor=(never measured)"
        let ticksPart = loudTicks.map {
            " loudTicksSinceEvent=\($0) (accumulated since the last recogniser event; the "
                + "rms above is this tick alone and is routinely below thr on a firing tick)"
        } ?? ""
        return String(format: "rms=%.5f ", Double(rms))
            + floorPart
            + String(format: " thr=%.5f", Double(speechThreshold))
            + ticksPart
    }

    /// The last error the Speech service delivered to this process, formatted for the trace.
    /// Read through `LiveRecognizer.lastServiceError()` only — the backing fields are
    /// `private` and lock-guarded there, and reading them any other way is a data race.
    ///
    /// LOGGED, NEVER BRANCHED ON. A stale error from a superseded generation still proves
    /// the system-wide daemon answered this process, which is exactly the fact tier 3 wants
    /// — but we do not yet know what these values look like in a REAL wedge as opposed to a
    /// false positive, and inventing a gate from an unmeasured signal is precisely how the
    /// fixed 0.0025 threshold got here in the first place. Collect the evidence first. Do
    /// not "finish the job" by adding a condition on this.
    private func lastServiceErrorDescription() -> String {
        guard let e = recognizer.lastServiceError() else { return "(none since launch)" }
        return String(format: "%.0f s ago ", Date().timeIntervalSince(e.0)) + e.1
    }

    // ---- Audio ---------------------------------------------------------------------
    private var engine: AVAudioEngine?
    private var pipeline: AudioPipeline?
    private var isCapturing = false

    private typealias FinalQueue = LocalTranscriptionQueue<Data, String>
    private var finalQueue = FinalQueue()
    private struct FinalCapture {
        let target: TextInjector.BufferedTargetToken
        let keyterms: [String]
        var transcript = ""
        var failure: String?
    }
    private var finalCaptures: [FinalQueue.CaptureID: FinalCapture] = [:]
    private var localCaptureID: FinalQueue.CaptureID?
    private var localWorker: Task<Void, Never>?
    private var localDeliveryTask: Task<Void, Never>?
    private var localTranscriptionSuspended = false
    private var localTerminationRequested = false
    private var activeLocalDictation = false
    private var localDictationEnabled: Bool {
        selectedEngineKind == .apple && WhisperServerManager.shared.localFinalConfigured
            && (UserDefaults.standard.object(forKey: "localBilingualDictation") as? Bool ?? true)
    }


    /// Non-nil only when MICTEST_AUDIO_FILE named a decodable file at capture start. While it
    /// is non-nil the microphone's own buffers are discarded in the tap closure and this
    /// object feeds the file in their place — see SyntheticAudioSource.swift for why that is
    /// the only way the 20 s seam can be measured without a person in the room.
    private var syntheticSource: SyntheticAudioSource?

    /// Authoritative "the user wants to be dictating right now".
    ///
    /// `onPressStart` is delivered from HotkeyMonitor's deferred main-queue release, not
    /// from inside the CGEventTap callback (it moved there when chord rejection forced the
    /// verdict to the key-up edge). It still does exactly one thing — set this flag — and
    /// defers everything heavy, because the ~110 ms release grace is already spent before
    /// the user hears anything happen. `onPressEnd` is never fired at all.
    ///
    /// Because both handlers write this flag and then ask `syncDictation()` to reconcile,
    /// the result is order-independent: even if the deferred begin were to land after the
    /// end, `syncDictation` reads the flag and does the right thing. A stuck recording is
    /// the worst failure this app has, and this is what makes it structurally impossible.
    private var wantsDictation = false

    /// The current session's flush flag. `drainElapsed` sets it just before teardown so
    /// the chunk loop's exit path force-finalizes buffered speech; `finishCapture` drops
    /// the reference (the loop keeps its own). nil for the whole session when the cloud
    /// pass was disabled at capture start — there is no loop to flush, and both consumers
    /// reach it through optional chaining.
    private var flushRequest: FlushRequestBox?

    /// Master on/off from the menu. Independent of `wantsDictation`: this is "the app is
    /// allowed to listen at all", that is "the key is down right now".
    private var dictationEnabled = true

    /// Bumped at the start of every dictation session. Everything that comes back from a
    /// background Task carries the generation it was born under and is dropped if it no
    /// longer matches. The check must happen *after* the MainActor hop, never before it.
    ///
    /// Deliberately NOT bumped when a session ends: the cloud pass is expected to answer
    /// *after* the hotkey is released — that is the whole point of it — and bumping on stop
    /// would throw away every cloud result the app ever produced. A new session bumping the
    /// generation is what invalidates a stale in-flight request.
    private var captureGeneration = 0

    // ---- Utterance / injection state ------------------------------------------------

    /// Exactly the characters we have injected into the focused app for the current
    /// utterance. The suffix we type next is computed against this and nothing else.
    private var injectedForUtterance = ""

    /// The recognizer's current understanding of the whole utterance — what the HUD shows
    /// and what the cloud gate consults. Not necessarily what was typed (see below).
    private var currentOnDeviceText = ""

    /// Set when a divergence repair FAILED — a partial revised earlier words AND
    /// `replaceLastInserted(count:with:)` refused to rewrite them. From that moment
    /// partial injection stops for this utterance; the utterance FINAL still gets one
    /// reconciliation attempt (and the cloud pass another), because focus or AX state may
    /// have recovered by then. A repair that succeeds does not set this.
    private var utteranceDiverged = false

    /// True once this session learned the focused app STRUCTURALLY cannot do AX in-place
    /// replacement (Chromium/Electron and friends). From then on partials are NOT typed
    /// live -- only each utterance FINAL is injected, so divergence repair is never needed
    /// and the user gets complete sentences instead of a stale 3-char stump. Reset per
    /// session: focus usually changes between sessions, so the next app gets live typing
    /// again.
    ///
    /// ONLY a structural refusal sets this -- see `refusalIsStructural`. It used to latch
    /// on ANY refusal from `replaceLastInserted`, and the trace caught the cost: a single
    /// "a selection is active; not replacing" -- the user's own cursor, for one frame --
    /// downgraded the whole capture to lumps-at-utterance-boundaries, which is exactly the
    /// hitching the user reported. That is the same mistake already recorded on
    /// `injectionBlockedReason` below, one screen down: latching a transient failure for a
    /// whole session turns it into "typing stops and never resumes".
    private var finalOnlyInjection = false

    /// Consecutive TRANSIENT repair refusals that were answered by doing NOTHING —
    /// no re-anchor, no write — in the expectation that the next partial will simply
    /// succeed. Reset wherever the app learns the document and the ledger agree again:
    /// a repair that lands, an append that lands, a fresh start that lands, and every
    /// utterance boundary.
    ///
    /// WHY DEFERRING IS SAFE, and it is the same mechanical argument `deliver` already
    /// makes for retrying a failed `inject()`: a refused `replaceLastInserted` returns
    /// BEFORE anything is written and before the ledger is touched, so
    /// `injectedForUtterance` still describes the document exactly. The next partial
    /// recomputes its common prefix against the truth and tries again. Nothing is
    /// stranded, nothing is pretended.
    ///
    /// WHY IT IS BOUNDED. A transient that keeps recurring is not transient — it is a
    /// structural refusal this app's classifier has not learned to name (and
    /// `refusalIsStructural` deliberately fails SAFE into this class). After
    /// `maxTransientRepairSkips` in a row the app stops waiting for it to clear and
    /// treats it like the structural case, which is what keeps "retry on the next
    /// partial" from becoming "never type again", the exact failure the mute-removal
    /// work exists to prevent.
    private var transientRepairSkips = 0

    /// How many consecutive transient refusals may be deferred before the revision is
    /// resolved anyway. Three: at the ~2-4 partials per second th-TH produces this is
    /// under a second of waiting, short enough that a real hiccup (focus moving mid-
    /// partial, a one-frame selection, a secure-input leak) clears inside it, and short
    /// enough that a misclassified structural refusal costs almost nothing before the
    /// K-bounded path takes over.
    private nonisolated static let maxTransientRepairSkips = 3

    /// The largest stale tail, in grapheme clusters, that may be STRANDED in the user's
    /// document by `reanchorAfterUnrepairedRevision` when the APP refused the repair —
    /// and, since the run-5 wipe below, the largest EFFECTIVE change `repairDivergence`
    /// may write in place at all. On the app-refused path anything longer takes the
    /// fresh-start path instead; on the successful path anything longer is refused before
    /// `replaceLastInserted` is called and — since run 7, see the end of this comment —
    /// is stranded after all in an app that accepts repair, for the correction pass to
    /// replace.
    ///
    /// TEN, and the reasoning is the measured shapes rather than a round number. The
    /// re-anchor design was justified on "typically the 3-7 characters the trace shows" —
    /// a word-merge or tone-mark revision — and a Thai pre-posed vowel (เ แ โ ใ ไ) revising
    /// its own cluster is smaller still, 1-3. Ten sits comfortably above both, so every
    /// revision the mechanism was actually designed for still re-anchors exactly as
    /// before. What it excludes is the shape that has nothing to do with revision: `lcp ==
    /// 0`, where `staleCount` is the WHOLE utterance — up to twenty seconds of speech —
    /// and a momentary AX refusal ("no focused element" in the trace) would otherwise
    /// strand all of it permanently. There is no continuum between the two: a real
    /// revision is a few clusters, a whole-utterance rewrite is dozens to hundreds.
    ///
    /// ── THE SAME TEN NOW BOUNDS THE SUCCESSFUL PATH, ON EFFECTIVE CHANGE ─────────────
    /// The paragraph above bounded only what a REFUSED repair could strand. A repair the
    /// app ACCEPTED had no bound at all, and `TEST-2026-08-31-run5-trace.txt` line 115 is
    /// what that looks like: `kept 10 common chars, replaced 175 stale chars with 178
    /// chars` — one AX write selected and overwrote the user's whole sentence, because the
    /// recogniser rewrote an early word and the common prefix collapsed to 10. Thai has no
    /// spaces, so an English word makes th-TH re-segment the Thai before it (`ผมใช้
    /// Python` → `พรชัยพีเทิร์น`, TEST-2026-08-31-mixed-language.md line 54); `lcp` then
    /// lands near 0 and `staleCount` is the whole 20 s window. The user reports it as
    /// "the system resets and deletes all the words".
    ///
    /// The bound is on EFFECTIVE change, not raw `staleCount`, because the raw number
    /// over-refuses: `replaced 93 stale chars with 83 chars` (same trace, line 86) is a
    /// legitimate final reconciliation if most of the 93 are re-emitted identically at
    /// the end of the 83. `repairDivergence` therefore subtracts the common SUFFIX of the
    /// stale tail and its replacement — clusters the write would delete and put straight
    /// back — and compares only what is actually destroyed. That 93/83 shape with an
    /// 80-cluster suffix lands at 13 and is still refused: it is the borderline the cap
    /// sits at, and thirteen clusters retracted mid-sentence is a sentence being
    /// re-segmented, not a tone mark. What a refusal buys is a stale strand INSTEAD of a
    /// wipe. Run 6 — every repair structurally refused, so every revision took that route
    /// — is what it looks like at scale (`divergencesRefused=21`, three fresh starts).
    /// That is the intended trade for a user whose words were being deleted, and it is
    /// not to be "fixed" by widening this.
    ///
    /// ── WHAT A CAP REFUSAL ON A PARTIAL DOES NOW, AND WHY IT IS NOT A FRESH START ────
    /// S1 first routed a cap refusal exactly like an app refusal, so on a partial — where
    /// `staleCount` is over ten by construction — it fresh-started. Run 7, mixed Thai and
    /// English in TextEdit (`TEST-2026-09-03-run7-trace.txt`), measured the cost: th-TH
    /// rewrites the Thai before every English word, so the first sentence was refused six
    /// times running (lines 40-68, effective 18/23/27/18/21/36), each refusal retyped the
    /// whole transcript, and the document ended with that sentence SIX times. Worse, the
    /// duplicates all sat inside the span the correction pass snapshots, so the clean
    /// 38-char fix was refused as `cloud text size mismatch (span 225 vs cloud 38)` (line
    /// 76). The cap had turned "delete my sentence" into "repeat it six times and block
    /// the fix". Lines 195 and 218 are the same mismatch from the OTHER route — spans of
    /// 192 and 122 built by the structural fresh starts at 183-200 after focus drifted to
    /// ChatGPT (line 181) — and this rule leaves those alone.
    ///
    /// So `resolveUnrepairedRevision` now RE-ANCHORS a cap refusal in an app that accepts
    /// repair, whatever the stale count: ledger := recogniser text, document untouched,
    /// typing continues. The strand this leaves is larger than ten and that is accepted,
    /// because it is confined to the app's own output, it is one rewrite deep, and the
    /// ~1 s correction pass can replace it — the typed span stays the size of one
    /// utterance, which is exactly what the fresh start destroyed. The app-refused route
    /// keeps its fresh start: an app that cannot be repaired at all has no pass to clean
    /// a strand up, and run 6 already showed the fresh start is the better failure there.
    /// Unproven until the harness is re-run with focus held in TextEdit: that line 76's
    /// mismatch becomes an applied correction, and that the stranded tail really sits
    /// inside the span that pass replaces rather than one chunk cut behind it.
    private nonisolated static let reanchorMaxStaleChars = 10

    /// The largest PURE RETRACTION, in grapheme clusters, that `repairDivergence` may apply
    /// in place: a repair whose replacement is empty, so the write deletes already-typed
    /// text and puts nothing back.
    ///
    /// FOUR, tighter than `reanchorMaxStaleChars`, because this is the worst shape a
    /// repair can take. Every other repair leaves the recogniser's current wording in the
    /// document; a retraction leaves a hole, and retracted text is text the recogniser
    /// has not finished with — run 5 lines 123-124 are a 3-cluster pure delete at `kept
    /// 19` and, in the same second, `kept 1 … replaced 18 stale chars with 22` over the
    /// same region. A large retraction the next partial reverses has deleted the user's
    /// words for nothing. Four admits every pure delete run 5 measured — 3, 3 and 4
    /// clusters (lines 34, 123, 164) — and that is the whole of its justification. It
    /// is NOT "one syllable": Swift keeps a base consonant with its marks in one
    /// `Character`, but a leading vowel (เ แ โ ใ ไ), a trailing one (า ะ ำ) and a final
    /// consonant are each their own cluster, so a syllable of that shape is five
    /// (เครื่อง = เ·ค·รื่·อ·ง). A legitimate one-syllable retraction of that shape is
    /// refused and the text kept until the next partial rewrites it — accepted for v1;
    /// revisit if S5 shows `retractionsRefused>0` on Thai-only speech.
    private nonisolated static let retractionMaxStaleChars = 4

    /// True once a cloud correction has been applied for the current utterance. The
    /// on-device FINAL can arrive AFTER the (faster, more accurate) cloud result --
    /// measured in production: cloud applied 21 chars, then the on-device final tried to
    /// "reconcile" them back to its own worse text. Once the cloud owns the utterance,
    /// the on-device final is informational only.
    private var cloudOwnsUtterance = false

    /// Monotonic id of the utterance currently on screen. Bumped on every recogniser
    /// request boundary (`.listening`). A cloud snapshot records the seq it was taken
    /// under; if the seq has moved on by the time the result returns, the span belongs
    /// to an EARLIER utterance and the bookkeeping cases below must not touch
    /// `injectedForUtterance`/`cloudOwnsUtterance` -- a coincidental string match
    /// across utterances (repetitive Thai speech) would otherwise gag the new
    /// utterance's FINAL. The document replace itself is independently guarded by
    /// TextInjector's ambiguity refusal.
    private var utteranceSeq: UInt64 = 0

    /// Non-nil once `inject()` FAILED for the CURRENT utterance. Holds the human-readable
    /// reason from `TextInjector`, which is shown verbatim: it already names the pane to
    /// open.
    ///
    /// Scope is per-utterance by design, never per-session: it is cleared at every
    /// `.listening` boundary (and in `startUtterance()`), so each new utterance re-probes
    /// injection instead of staying muted. Latching it for the whole session turned one
    /// transient failure — Cursor's several-times-a-day secure-input leak (see
    /// TextInjector's header), an AX timeout — into "typing stops and never resumes"
    /// while the recogniser kept producing. The secure-input pre-check in `deliver()`
    /// does not set this at all; it re-probes on every delivery.
    private var injectionBlockedReason: String?

    /// Last completed on-device transcript, kept so "Copy last transcript" always has
    /// something to give the user when injection could not deliver it.
    private var lastTranscript = ""
    /// Last cloud result that could NOT be applied to the typed text.
    private var unappliedCloudText = ""

    /// Typed-span ledger, aligned with AUDIO chunks (not utterances): every suffix
    /// `deliver()` successfully injects is appended here, and `noteFinalChunk` snapshots
    /// and resets it when a FINAL chunk is cut. Audio-chunk boundaries (trailing silence)
    /// and typing pauses are both pause-driven, so the snapshot approximates "what was
    /// typed for this audio span" — which is what the cloud correction must find and
    /// replace. Unlike `injectedForUtterance` this deliberately survives the `.listening`
    /// utterance reset: the recogniser restarts a request on every pause, but the audio
    /// chunk keeps accumulating across that restart.
    private var typedSinceLastChunk = ""

    private var nextUtteranceID = 1
    private var lastCloudUtteranceID = 0

    // ---- Permissions ----------------------------------------------------------------
    private var micStatus: AVAuthorizationStatus = .notDetermined
    /// nil until `LiveRecognizer.requestAuthorization()` answers.
    private var speechAuthorized: Bool?

    // ---- Counters (trace only; never used to build injected text) --------------------
    // See `TraceCounters` for why there are two of these, which trace line reads which,
    // and the measurement that proved one set was never enough.
    private var lifetime = TraceCounters()
    private var thisCapture = TraceCounters()

    /// Deliberately NOT a `TraceCounters` field. "Sessions started during this capture" is
    /// always 1, so a per-capture copy would be noise on the "capture stopped" line; the
    /// count only means anything across the life of the process.
    private var sessions = 0

    private var lastCloudLatencyMS: Double?
    private var lastOutcome: String?

    // ---- Cloud ----------------------------------------------------------------------
    //
    // The cloud pass is Gemini 3.5 Flash (`GeminiClient`). It replaced fal Scribe v2 on the
    // user's instruction, and BOTH fal files — `FalClient.swift` and `FalBillingClient.swift`
    // — have now been DELETED, also on the user's instruction. They were retained for a
    // while so the swap stayed reversible without a trip through git history; that is what
    // git history is for, and keeping a vendor's client compiled in after the app stopped
    // talking to it made "which provider does this app use" a question with two answers.
    //
    // What survived the deletion, because `GeminiClient` and `GeminiLiveRecognizer` were
    // reusing it rather than growing second copies, is the trio `FalClient` happened to
    // host: the key-file path, the dotenv parser and the keyterm clamp. Those are now
    // `CloudKeyFile`, which is named after the file it reads instead of after a vendor.
    //
    // `WhisperClient` is a DIFFERENT case and was deliberately not touched: it is dormant
    // and unreferenced, but it was never superseded by anything — no instruction covers it.
    //
    // No request from this app reaches fal.ai any more, and no code for one remains.

    /// Constructed once, at init. `GeminiClient.init()` throws when there is no key on
    /// disk, and that is a perfectly ordinary state — it must disable the toggle and name
    /// the file to create, not crash and not silently do nothing.
    private let cloudSetup: (client: GeminiClient?, error: String?, keyPath: String?) = {
        do {
            return (try GeminiClient(), nil, nil)
        } catch {
            let d = describeCloudError(error)
            return (nil, d.summary, d.missingKeyPath)
        }
    }()
    /// Is there a `GOOGLE_API_KEY` on disk? Answers for BOTH Gemini consumers — the Gemini
    /// Live engine and the `.gemini` correction provider — and for nothing else. This used
    /// to be `cloudAvailable`; the rename is deliberate, because "available" now also has
    /// a per-provider meaning (`correctionAvailable`), and conflating the two would let a
    /// user who keeps a key but picks `.local` lose the Gemini Live engine from the menu.
    private var geminiKeyAvailable: Bool { cloudSetup.client?.isConfigured == true }

    // ---- Which engine drives the live text -------------------------------------------
    //
    // Same nil-means-default UserDefaults idiom as the three toggles below, with the
    // default spelled `.apple`: an unset key, a key holding a string nobody recognises,
    // and a key holding "apple" all mean the on-device engine. The privacy-preserving
    // choice is the one that survives every reading failure, which is the only direction
    // a default of this kind may fail in.

    private nonisolated static let engineDefaultsKey = "dictationEngine"

    /// The user's EFFECTIVE choice — what the next capture will start. Clamped to `.apple`
    /// at launch when there is no Google key on disk, exactly as `correctionKind` is clamped
    /// by `correctionAvailable`; the stored preference is deliberately NOT rewritten by
    /// that clamp, so restoring the key restores the choice.
    private var selectedEngineKind: DictationEngineKind = {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: AppDelegate.engineDefaultsKey),
              let kind = DictationEngineKind(rawValue: raw) else { return .apple }
        return kind
    }()

    /// The engine the CURRENT capture session is actually running, resolved once per
    /// capture in `beginCapture`'s full start and never re-read from `selectedEngineKind`
    /// until the next one.
    ///
    /// THIS SPLIT IS WHAT MAKES "takes effect at the next capture" STRUCTURAL rather than
    /// a convention. Every mid-session caller — the drain-cancel resume, `endCapture`,
    /// `finishCapture`, the watchdog's stand-down gate, the trace lines — reads
    /// `activeEngine`, so there is no code path that can hand a live session's audio to
    /// one engine and its `stop()` to another. Mirrors `selectCorrection`'s precedent,
    /// where the chunk loop's existence is likewise decided once at session start.
    private var activeEngineKind: DictationEngineKind = .apple

    /// The engine object for `activeEngineKind`. A two-case switch on a stored enum, on
    /// the main actor — NEVER on the audio thread: `beginCapture` resolves it once into a
    /// local that the tap closure captures (see `processTap`).
    private var activeEngine: any DictationEngine {
        switch activeEngineKind {
        case .apple: return recognizer
        case .geminiLive: return geminiRecognizer
        }
    }

    /// Can Gemini Live be chosen at all? Both halves are load-bearing: `geminiKeyAvailable`
    /// answers "is there a `GOOGLE_API_KEY` on disk" — the same key, in the same file, as
    /// the `.gemini` correction provider reads, which is also what lets the menu name the
    /// path to create — and `isSupported` is the engine's own veto for anything else that
    /// would stop it running here. Independent of `correctionKind` on purpose: choosing
    /// local correction must not take the Gemini Live engine away from a keyed user.
    private var geminiLiveAvailable: Bool {
        geminiKeyAvailable && geminiRecognizer.isSupported
    }

    /// Rate limiter for the watchdog's stand-down line, in the shape of
    /// `lastTier3WouldFireLoggedAt` and for the same reason: the ladder's strike branch can
    /// be reached every ~13 s, and a line that says "still standing down" at that cadence
    /// would bury the events it is meant to be read beside.
    private var lastEngineStandDownTracedAt = Date.distantPast

    // ---- The correction provider setting ---------------------------------------------
    //
    // `correctionKind` is what the menu's "Correction" submenu selects and what
    // `beginCapture` reads once per session — the chunk loop's existence is decided at
    // session start, like the engine. Persisted under `correctionProviderDefaultsKey`.
    //
    // HISTORY, because the stored keys carry it. Until 2026-09-03 the only second engine
    // was Gemini and the setting was one Bool, `cloudPassEnabled` — "Cloud accuracy pass",
    // REALTIME-FIRST, default OFF at the user's directive ("I don't need auto-correction.
    // I need realtime and fast dictation."), opt-in from the menubar because it was the
    // only network egress in this app. That key is still read (once, below) and still
    // written by `selectCorrection` — as `kind == .gemini`, never as "the pass is on":
    // written as on-ness, a local-only user's `true` would read to an older build as
    // "send audio to Google".
    //
    // MIGRATION (`resolveCorrectionKind`), run once, on the first launch where the new key
    // is absent. The new key is authoritative thereafter and the old one is never consulted
    // again while it exists — otherwise a user who moved from Gemini to local would be
    // moved back on every launch, and audio would leave the Mac against their choice:
    //   * old key stored `true`  → `.gemini`, and the new key is written. Nothing changes
    //     for that user: they opted in to Google and still are. If the key file no longer
    //     configures Gemini the effective pass is off with the "NOT configured" trace, and
    //     the stored choice is left alone so restoring the key restores it — the
    //     `selectedEngineKind` idiom.
    //   * old key stored `false` → `.off`, and the new key is written. An explicit
    //     opt-out stays an opt-out; the menu offers local one click away.
    //   * nothing stored → `.local` if the pinned binary AND a model file exist, else
    //     `.off`. NOT written: a computed default stays computed, so a model appearing
    //     or vanishing later moves between local and off and can never produce gemini.
    // On this Mac at the time of writing none of the three keys was stored (`defaults
    // read com.boombignose.mictest` held only the HUD origin), so this user lands on the
    // computed default.
    private nonisolated static let cloudPassDefaultsKey = "cloudPassEnabled"
    private nonisolated static let correctionProviderDefaultsKey = "correctionProvider"
    private var correctionKind: CorrectionProviderKind = .off

    /// The kind the CURRENT session's chunk loop was built for (`.off` when no loop was
    /// started), for the capture-stopped summary — the `activeEngineKind` split again.
    private var activeCorrectionKind: CorrectionProviderKind = .off

    /// The pinned `whisper-server`, resolved once at init: two `stat`s, and an answer this
    /// app would not act on mid-run anyway (the `cloudSetup` idiom).
    private let localBinaryPath: String? = WhisperServerManager.discoverBinary()

    /// Can `.local` serve at all? CONFIGURED, not READY: the binary and a model file
    /// exist. Readiness is asynchronous — a loopback probe, a ~2 s model load — and every
    /// consumer of this property is a synchronous main-actor gate (`refreshMenu`,
    /// `beginCapture`, `noteFinalChunk`), so readiness is not part of it; nothing on the
    /// main actor ever awaits `CorrectionProvider.isAvailable()`.
    /// `LocalWhisperProvider.transcribe` awaits the server itself, and a server that is
    /// not up surfaces as a traced failure of that one utterance, never as a disabled
    /// pass — and never as a chunk loop that was not created.
    private var localCorrectionConfigured: Bool {
        localBinaryPath != nil && WhisperServerManager.shared.modelURL != nil
    }

    private let localProvider = LocalWhisperProvider(manager: WhisperServerManager.shared)

    /// Is the selected provider configured? See `localCorrectionConfigured` for why this
    /// is a synchronous, static answer.
    private var correctionAvailable: Bool {
        switch correctionKind {
        case .off: return false
        case .local: return localCorrectionConfigured
        case .gemini: return geminiKeyAvailable
        }
    }

    /// The pass will run for the next session: a provider is selected, it is configured,
    /// and this process has not switched it off itself (`cloudAutoDisabledReason`).
    private var correctionEnabled: Bool {
        correctionKind != .off && correctionAvailable && cloudAutoDisabledReason == nil
    }

    /// Why `correctionEnabled` is false, for the gate traces.
    private var correctionGateState: String {
        if correctionKind == .off { return "off" }
        if !correctionAvailable { return "unavailable (\(correctionKind.rawValue))" }
        return "auto-disabled"
    }

    /// The provider object for `correctionKind`, or nil when the pass cannot run.
    private var correctionProvider: (any CorrectionProvider)? {
        guard correctionAvailable else { return nil }
        switch correctionKind {
        case .off: return nil
        case .local: return localProvider
        case .gemini: return cloudSetup.client
        }
    }

    /// For the summary lines: the model behind a kind.
    private func correctionModelName(for kind: CorrectionProviderKind) -> String {
        switch kind {
        case .off: return "(none)"
        case .local: return WhisperServerManager.shared.modelName
        case .gemini: return GeminiClient.model
        }
    }

    /// The merged glossary the next dispatch sends: user terms first, then
    /// `cloudKeyterms`, clamped (`UserKeyterms`). Published from a detached read
    /// (`reloadKeyterms`) and read inside `dispatchFinalChunk`'s MainActor hop, where it
    /// is captured by value into the detached `cloudPass` — `[String]` is Sendable, and
    /// that hop is the one place per chunk that is already on the main actor, so
    /// `cloudPass` (nonisolated) never reads main-actor state.
    private var activeKeyterms: [String] = cloudKeyterms

    // ---- Local server lifecycle: ONE serial chain -----------------------------------
    //
    // Every start and stop of the local server goes through `enqueueServerLifecycle`,
    // which chains onto the previous operation. Independent `Task`s from `beginCapture`
    // (start) and the sleep/lock observers (stop) would have no arrival order at the
    // actor — the mechanism `RecognizerEventBox` documents — and the realistic ordering,
    // wake then hotkey, could land `ensureReady` while `stop()` is still waiting on the
    // child's exit, take its fast path against a port the child is about to release,
    // and hand back a URL that refuses the next request.
    private var serverLifecycle: Task<Void, Never>?
    /// True while the chain's newest operation is a START — the only kind a later stop
    /// may cancel. Cancelling a stop would turn its bounded SIGTERM wait into an
    /// immediate SIGKILL (`waitForExit`'s sleep throws at once under cancellation).
    private var serverLifecycleIsStart = false
    /// True from the first start request until a stop: lets the stop paths skip the
    /// trace and the actor hop when there is nothing to stop.
    private var localServerRequested = false
    /// Stops an idle local server `localServerIdleStopSeconds` after the last capture
    /// ends; cancelled by the next capture start. NOT on the chain — a ten-minute sleep
    /// on the serial chain would hold every later start behind it.
    private var localIdleStopTask: Task<Void, Never>?
    /// The server holds ~1.6 GB of weights (ggml-large-v3-turbo, WhisperServerManager.swift
    /// header). Kept warm between captures so a dictating user pays the load once;
    /// released after ten idle minutes, on sleep, on lock, and on quit; `ensureReady`
    /// pays ~2 s again at the next capture start.
    private nonisolated static let localServerIdleStopSeconds: Double = 600
    /// One phrase for the menu: what the local server last reported.
    private var localServerStatus = "not started"
    /// How many lines of the manager's log ring have been forwarded into the trace.
    private var forwardedManagerLogLines = 0
    /// SIGTERM handler, held for the life of the process — see `installSignalHandlers`.
    private var sigtermSource: DispatchSourceSignal?

    /// "Auto-correct from cloud" menu toggle — nil-means-ON. When ON, a cloud result that
    /// differs from the span typed for its audio chunk is applied IN PLACE via
    /// `TextInjector.replaceRecentText(find:with:)`; when OFF (or when the replace
    /// refuses) the result falls back to the display-only park under "Copy cloud
    /// correction". Persisted in UserDefaults, and an explicit stored choice still wins, so
    /// either decision survives relaunches (same pattern as the hotkey override).
    ///
    /// Automatic rewriting is opt-in. With it off, partials remain in the live HUD
    /// until a complete transcript is inserted once. The same switch gates Apple
    /// tail repairs and second-pass replacement; a provider is not required to change
    /// it. Keep the existing defaults key so a stored preference survives upgrades.
    private nonisolated static let autoCorrectDefaultsKey = "cloudAutoCorrect"
    private var autoCorrectEnabled: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: AppDelegate.autoCorrectDefaultsKey) == nil
            ? false
            : d.bool(forKey: AppDelegate.autoCorrectDefaultsKey)
    }()

    // With rewriting off, keep the entire evolving transcript in the HUD. Commit
    // once at a recognizer boundary or normal stop; slicing by an old character
    // count corrupts Thai tone-mark revisions and mixed-language word merges.
    private var stableTranscript = StableTranscriptBuffer()

    /// "Restart macOS speech service when wedged" menu toggle — the TRIGGER for the
    /// watchdog's tier 3, default OFF, same nil-means-OFF UserDefaults semantics as the two
    /// toggles above (an explicit stored choice wins and survives relaunches).
    ///
    /// The detector is not what is in doubt; the ACTION is. Tier 3's entire field record is
    /// one clear failure, one ambiguous case, and one measured cost: 16:09-16:15 on
    /// 2026-08-26 the ladder fired `pkill` on a macOS system service twice, and the first
    /// kill was followed immediately by `kAFAssistantErrorDomain error 1107` and 3.5 more
    /// minutes of failure — it restored nothing and throttled us. That is not enough
    /// evidence for software to `kill -9` a system service unattended, and possibly clobber
    /// another app's transcription while doing it. So the detector keeps running and keeps
    /// logging (`RECOGNIZER WATCHDOG TIER 3 WOULD FIRE (disabled)`, carrying everything a
    /// human needs to judge whether it should have) and the kill itself is opt-in.
    ///
    /// Unlike the cloud pass, this is read on the MainActor at the instant the tier fires,
    /// so flipping it takes effect immediately — no session restart needed.
    private nonisolated static let daemonRestartDefaultsKey = "restartSpeechServiceWhenWedged"
    /// DEFAULT FLIPPED TO ON AT THE USER'S EXPLICIT REQUEST (2026-08-28), and the paragraph
    /// above is left standing rather than rewritten, because it is still the honest reading
    /// of the evidence and it argues AGAINST this default. Recorded plainly so the next
    /// person does not mistake this for a finding:
    ///
    ///   * the one field record of tier 3 firing remains a failure — `pkill` restored
    ///     nothing and was followed by `kAFAssistantErrorDomain` 1107 throttling;
    ///   * the failure the user was actually hitting on the day they asked was NOT a
    ///     systemic wedge. Trace 14:36 shows captures ending on hotkey release, no give-up,
    ///     no tier-3 arming; the mute was `finalOnlyInjection` and the blind gate.
    ///
    /// So this default is a user preference, not an engineering conclusion. `nil` now means
    /// ON, an explicit stored choice still wins, and one click of the menubar item reverts
    /// it — which is the right escape hatch to leave, given the record above.
    ///
    /// ONE COMPOUNDING EFFECT, STATED BECAUSE NOTHING ELSE IN THE FILE DOES. The same
    /// change set drops `backoffCeiling` from 48 s to a toggle-independent 12 s (it had to:
    /// any ceiling at or above the 20 s rotation cadence is unsatisfiable). That makes
    /// watchdog strikes fire more often, and `suppressedBouncesSinceRestart` — tier 3's
    /// arming counter — only increments inside the strike branch. So the unattended
    /// `kill -9` of `localspeechrecognition` is more reachable now than in EITHER
    /// previously shipped configuration. Each change is individually correct and the
    /// default was explicitly requested; the combination is new and unmeasured, against a
    /// tier whose only field trial was a failure. If tier 3 starts firing in traces,
    /// this pairing is the first thing to look at.
    private var daemonRestartEnabled: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: AppDelegate.daemonRestartDefaultsKey) == nil
            ? true
            : d.bool(forKey: AppDelegate.daemonRestartDefaultsKey)
    }()

    /// One cloud request in flight at a time. A second concurrent request would race the
    /// first to update the same HUD line, and every call is billed.
    private var cloudTask: Task<Void, Never>?

    /// When the in-flight `cloudTask` was registered; nil exactly when `cloudTask` is nil
    /// (set in `registerCloudTask`, cleared wherever the task is cleared). Read only by
    /// `noteFinalChunk`'s supersede rule — see `cloudSupersedeAfterSeconds`.
    private var cloudTaskStartedAt: Date?

    // ---- Spend ledger ----------------------------------------------------------------
    //
    // NO BALANCE PROBE LIVES HERE ANY MORE. Under fal this section had a sibling: a
    // background task that asked fal's billing endpoint what was left on the account and
    // decorated one menu line with the answer. Google exposes no equivalent an API key may
    // read — Cloud Billing is an OAuth-only surface — so there is nothing to ask, and the
    // whole probe (`refreshBalance`, `applyBalanceOutcome`, the six pieces of state they
    // shared, their four trigger sites and their `BILLING:` traces) was deleted rather than
    // left pointing at a host this app no longer talks to. `FalBillingClient.swift` itself
    // has since been deleted as well — see the note at the top of the cloud section.
    //
    // What is left is a ledger of what THIS MAC sent, which was always the honest half: it
    // is measured here, not reported by a vendor, and it never claimed to be an invoice.

    /// Audio seconds and request count SENT from this Mac, lifetime, persisted.
    ///
    /// COUNTED AT DISPATCH, and that is the whole point of them. The provider serves — and,
    /// we must assume, bills for — requests whose results this app then throws away: the
    /// id-guards at the top of `applyCloudResult`/`applyCloudFailure` discard superseded
    /// results before any completion-side counter could run, and `noteFinalChunk`
    /// deliberately cancels a hung request the far end may already be halfway through.
    /// Counting on the way back would therefore under-report real usage, silently, in
    /// exactly the situations where usage is highest. A figure that reads LOW is worse than
    /// no figure. (Written for fal, and every word of it still holds for Gemini.)
    ///
    /// No nil-means-X ceremony (unlike the Bool toggles above): `double(forKey:)` and
    /// `integer(forKey:)` return 0 for an absent key, which is precisely the right starting
    /// value for a lifetime counter.
    private nonisolated static let cloudSecondsDefaultsKey = "cloudAudioSecondsSent"
    private nonisolated static let cloudRequestsDefaultsKey = "cloudRequestsSent"
    private var cloudAudioSecondsSent =
        UserDefaults.standard.double(forKey: AppDelegate.cloudSecondsDefaultsKey)
    private var cloudRequestsSent =
        UserDefaults.standard.integer(forKey: AppDelegate.cloudRequestsDefaultsKey)

    /// Audio tokens billed to this Mac, lifetime, persisted — Gemini's EXACT unit, read
    /// straight off `GeminiClient.Result.audioTokens` rather than derived from anything.
    ///
    /// COUNTED ON SUCCESS ONLY, which is the opposite rule to the two counters above, and
    /// the asymmetry is forced rather than chosen: a token count exists only inside a
    /// response, so a request that was cancelled, timed out, or never reached Google has no
    /// token figure to add — not a zero, an unknown. THE CONSEQUENCE, STATED SO NOBODY
    /// DEBUGS IT AS A BUG: tokens read LOW relative to requests whenever requests are
    /// cancelled (the supersede path does exactly that), so `req` and `audio tokens` on the
    /// spend line will not stay in proportion. That is unavoidable, and it is why the
    /// seconds/requests counters keep counting at dispatch instead of moving here.
    ///
    /// Counted for EVERY response that arrives, including ones the stale-guards then
    /// discard — see `applyCloudResult`, where the accumulation deliberately sits above
    /// those guards. A response that arrived was served, and a served response was billed
    /// whether or not this app had any further use for it.
    private nonisolated static let cloudTokensDefaultsKey = "cloudAudioTokensSent"
    private var cloudAudioTokensSent =
        UserDefaults.standard.integer(forKey: AppDelegate.cloudTokensDefaultsKey)

    /// Consecutive settled HTTP 429s. Any other settled failure resets it; see
    /// `applyCloudFailure` for why cancellations do neither.
    private var consecutive429s = 0

    /// How many consecutive 429s turn the cloud pass off. Two, not one: a single 429 could
    /// easily be a transient answer, and turning a user's feature off on one data point is
    /// the kind of "help" that reads as a bug.
    ///
    /// THIS RULE IS LESS PRECISE THAN THE 402 RULE IT REPLACES, and the difference is worth
    /// knowing before trusting it. fal's 402 meant one thing: out of credit, every further
    /// request a guaranteed failure. Google returns 429 for a per-minute RATE limit and for
    /// an exhausted QUOTA alike, and nothing in the status distinguishes them — so where two
    /// 402s in a row could not be coincidence, two 429s in a row genuinely can be: this app
    /// fires a request roughly every 10 s, which is quite fast enough to collect two
    /// rate-limit refusals during a burst that would have cleared on its own.
    ///
    /// Kept at two anyway, because the failure modes are lopsided. Auto-disabling early
    /// costs one menubar click, is announced in the menu (`cloudAutoDisabledReason`) and in
    /// the trace, and leaves the stored opt-in untouched; NOT disabling on a real quota wall
    /// means every subsequent utterance uploads audio to be refused, indefinitely. The
    /// escape hatch is the toggle, and it is one click.
    private nonisolated static let max429sBeforeAutoDisable = 2

    /// Non-nil while the cloud pass is off because THIS PROCESS turned it off, rather than
    /// because the user did. Shown in the menu, so an off toggle the user did not touch is
    /// never mysterious. Cleared by any deliberate flip of the toggle.
    private var cloudAutoDisabledReason: String?

    private var chunkTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bundle identity first so the trace file is self-identifying. A nil bundle
        // identifier is itself the diagnosis: a bare binary has no Info.plist, therefore no
        // NSMicrophoneUsageDescription / NSSpeechRecognitionUsageDescription, and TCC will
        // refuse to show a prompt at all.
        let bid = Bundle.main.bundleIdentifier ?? "(nil — no Info.plist / bare binary)"
        trace("=== MicTest launched (background dictation) ===")
        trace("bundleIdentifier: \(bid)")
        trace("bundlePath: \(Bundle.main.bundlePath)")
        trace("executablePath: \(Bundle.main.executablePath ?? "(nil)")")
        trace("hotkey: keyCode \(hotkey.keyCode) (Right-Option is \(ModifierKey.rightOption))")

        // Accessory, not regular: no Dock icon, no app switcher entry, no main menu bar.
        // The status item and the HUD are the entire surface.
        NSApp.setActivationPolicy(.accessory)

        // The correction provider: stored choice, migrated legacy choice, or the computed
        // default — the rule and its history are at `correctionKind`. The trace states
        // the EFFECTIVE state, the paths it depends on, and never any key material. The
        // live text is Apple's in every case; this line is about the second engine only.
        // The whole `correction: provider=` prefix is one literal so the built binary
        // carries it contiguously (`strings … | grep -c "correction: provider="`).
        let migration = resolveCorrectionKind()
        let modelFile = WhisperServerManager.shared.modelURL?.path ?? "missing"
        trace("correction: provider=\(correctionKind.rawValue) "
            + "model=\(correctionModelName(for: correctionKind)) "
            + "binary=\(localBinaryPath ?? "missing") modelFile=\(modelFile) "
            + "available=\(correctionAvailable) live=Apple"
            + (migration.map { " (\($0))" } ?? " (stored choice)"))
        if geminiKeyAvailable {
            trace("gemini: configured (\(GeminiClient.model)) — "
                + (correctionKind == .gemini
                    ? "selected as the correction provider; audio is sent to Google"
                    : "available to Gemini Live and the correction menu; not selected"))
        } else {
            trace("gemini: NOT configured — \(cloudSetup.error ?? "unknown reason")"
                + (correctionKind == .gemini
                    ? "; the stored gemini choice is unavailable until a key exists"
                    : ""))
        }
        // Both halves say whether the state is the default or a stored choice, in BOTH
        // directions — the shape `daemonRestartEnabled`'s line below already uses. A trace
        // that hardcodes "(default)" against one value silently lies the day the default
        // flips, which is exactly what this line did before auto-correct became nil-means-ON.
        let autoCorrectStored = UserDefaults.standard.object(forKey: Self.autoCorrectDefaultsKey) != nil
        trace("automatic corrections (live repairs and second pass): "
            + (autoCorrectEnabled
                ? "ON \(autoCorrectStored ? "(stored opt-in)" : "(default)")"
                : "OFF \(autoCorrectStored ? "(stored opt-out)" : "(default)")"))
        trace("restart macOS speech service when wedged: "
            + (daemonRestartEnabled
                ? "ON (default) — watchdog tier 3 may pkill localspeechrecognition"
                : "OFF (stored opt-out) — watchdog tier 3 detects and logs only"))

        // The engine, clamped and named. Clamping here rather than at capture time is the
        // `correctionKind` idiom above, and it is sound for the same reason: `cloudSetup` is
        // built once at init, so the key cannot appear or vanish mid-run and there is
        // nothing later to re-evaluate. The trace says which engine the run used, in both
        // directions and never a key — two runs whose numbers are compared without knowing
        // this are two runs of different apps.
        let storedEngineRaw = UserDefaults.standard.string(forKey: Self.engineDefaultsKey)
        if selectedEngineKind == .geminiLive && !geminiLiveAvailable {
            selectedEngineKind = .apple
            trace("dictation engine: Gemini Live was stored but is unavailable — "
                + "\(cloudSetup.error ?? "no GOOGLE_API_KEY"); falling back to Apple "
                + "(on-device). The stored preference is left alone, so restoring the key "
                + "restores the choice.")
        } else {
            trace("dictation engine: \(selectedEngineKind.menuName) "
                + (storedEngineRaw == nil
                    ? "(default — nil means Apple, and audio never leaves this Mac)"
                    : "(stored choice \"\(storedEngineRaw!)\")")
                + (selectedEngineKind == .geminiLive
                    ? " — microphone audio is streamed to Google for the whole of every capture"
                    : ""))
        }

        buildStatusItem()
        wireHUD()
        wireRecognizer()
        wireHotkey()
        wireSystemStateObservers()
        installSignalHandlers()

        // The HUD comes up idle rather than hidden, and stays that way: see the header. This
        // is the affordance that survives a status item hiding behind the notch.
        showIdleHUD()

        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        trace("initial authorizationStatus(.audio): \(statusName(micStatus))")

        // Contextual strings before the first start(), so the very first utterance already
        // biases towards the technical vocabulary rather than only later ones.
        //
        // BOTH engines, unconditionally, and not just the selected one: the keyterms are
        // the same list, seeding is cheap and idempotent, and doing it here means a
        // mid-run engine switch cannot produce one capture that has never been told the
        // vocabulary. The alternative — re-seeding inside `beginCapture` — would put a
        // list copy on the hotkey's latency path for no benefit.
        recognizer.setContextualStrings(cloudKeyterms)
        geminiRecognizer.setContextualStrings(cloudKeyterms)
        // Built in pieces, deliberately. As one five-way interpolated `+` chain this line
        // made the compiler give up outright ("unable to type-check this expression in
        // reasonable time") — each `+` on interpolated strings multiplies the overload
        // space it has to search. Assigning to typed `let`s first collapses that. If a
        // sixth field is ever added here, add it the same way rather than extending the
        // chain.
        let engineField = "engine=\(selectedEngineKind.rawValue)"
        let appleField: String = "appleSupported=\(recognizer.isSupported)"
        let geminiField: String = "geminiLiveSupported=\(geminiRecognizer.isSupported)"
        let availField: String = "geminiLiveAvailable=\(geminiLiveAvailable)"
        let termsField: String = "contextualStrings=\(cloudKeyterms.count)"
        trace("recognizer: \(engineField) \(appleField) \(geminiField) "
            + "\(availField) \(termsField)")

        // The user's glossary and the local server, both off the main thread. The preload
        // is what makes the first utterance's correction arrive at steady-state latency
        // instead of behind a ~2 s model load and a ~2.6 s warm-up (WhisperServerManager
        // header) — during which the one-in-flight gate would refuse every later chunk —
        // and it is what lets a launch with no capture at all prove that the server
        // starts with the app and stops with it.
        reloadKeyterms(reason: "launch")
        trace("local bilingual primary: \(localDictationEnabled ? "ON" : "OFF"); configured=\(WhisperServerManager.shared.localFinalConfigured)")
        startLocalServer(reason: "launch preload")

        requestPermissions()

        // The hotkey tap needs Accessibility. Without it `CGEvent.tapCreate` returns nil with
        // no error and no prompt, so ask once — the system prompt only appears when the user
        // has not decided yet. `start()`'s health timer reinstalls the tap the moment the
        // grant lands, so there is no need to relaunch after granting.
        if !hotkey.permissionGranted() {
            let prompted = hotkey.requestPermission()
            trace("Accessibility not granted; AXIsProcessTrustedWithOptions -> \(prompted)")
        }
        hotkey.start()
        trace("hotkey monitor started; isHealthy=\(hotkey.isHealthy)")

        // Two rates on purpose. Selector-based timers (not closures) keep us clear of any
        // @Sendable-closure capture questions under Swift 6 strict concurrency, and .common
        // mode keeps them ticking while a menu is being tracked — which matters, because the
        // menu is the only place the numbers are visible.
        let ui = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tickUI),
                       userInfo: nil, repeats: true)
        RunLoop.main.add(ui, forMode: .common)
        uiTimer = ui

        let st = Timer(timeInterval: 1.0, target: self, selector: #selector(tickStatus),
                       userInfo: nil, repeats: true)
        RunLoop.main.add(st, forMode: .common)
        statusTimer = st

        refreshMenu()

        maybeArmAutostart()
    }

    /// No windows exist, so the default "quit when the last one closes" would be a coin flip
    /// on the HUD panel's ordering. Say no explicitly: this app is only ever quit
    /// DELIBERATELY — the menubar's Quit item, the HUD's own quit button (wired in
    /// `wireHUD`), Cmd-Q, or the autostart harness — never as a side effect of a panel
    /// going away. Every one of those routes lands in `applicationWillTerminate`.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard finalQueue.pendingCaptureCount > 0 || localDeliveryTask != nil else { return .terminateNow }
        localTerminationRequested = true
        wantsDictation = false
        finishCapture(reason: "finishing local transcription before quit")
        hud.set(.transcribing("Finishing transcription before quitting…"))
        return .terminateLater
    }

    private func finishLocalTerminationIfReady() {
        guard localTerminationRequested, !isCapturing,
              finalQueue.pendingCaptureCount == 0,
              localDeliveryTask == nil, localWorker == nil else { return }
        localTerminationRequested = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        wantsDictation = false
        finishCapture(reason: "app terminating")
        // Synchronous SIGTERM to an owned whisper-server — there is no time to await
        // `stop()` here. An adopted server is left alone by the manager's rule.
        localIdleStopTask?.cancel()
        WhisperServerManager.shared.emergencyStop()
        if localServerRequested {
            trace("correction: emergencyStop() sent (owned or reclaimed child SIGTERMed; "
                + "an adopted server is left alone) — app quitting")
        }
        hotkey.stop()
        uiTimer?.invalidate()
        statusTimer?.invalidate()
        drainTimer?.invalidate()
        trace("=== MicTest terminating ===")
    }

    // MARK: - Permissions

    private func requestPermissions() {
        // The TCC prompt is a system dialog, not an NSAlert we put up: it is the only way to
        // ever reach `.authorized`, and it does not block our run loop.
        if micStatus == .notDetermined {
            trace("requesting microphone access")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                // Completion runs on an arbitrary queue and is @Sendable, so it may not touch
                // the main actor synchronously. Hop explicitly — never assumeIsolated.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    trace("requestAccess(.audio) -> \(granted); status now \(statusName(self.micStatus))")
                    self.refreshMenu()
                }
            }
        }

        Task { @MainActor [weak self] in
            let ok = await LiveRecognizer.requestAuthorization()
            guard let self else { return }
            self.speechAuthorized = ok
            trace("LiveRecognizer.requestAuthorization() -> \(ok)")
            if !ok {
                self.lastOutcome = "Speech recognition not authorized — "
                    + "System Settings > Privacy & Security > Speech Recognition"
            }
            self.refreshMenu()
        }
    }

    // MARK: - Menubar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = symbolImage("mic", size: 14, weight: .regular)
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("MicTest dictation")
        item.button?.toolTip = "MicTest — tap \(defaultHotkeyName) to start/stop dictation"

        menu.delegate = self

        dictationItem.title = "Dictation"
        dictationItem.target = self
        dictationItem.action = #selector(toggleDictation)
        menu.addItem(dictationItem)

        // Directly under "Dictation", above the correction pass: this item decides what
        // the dictation line itself does, where the correction items only decorate its
        // output.
        engineItem.title = "Dictation engine"
        engineItem.target = self
        engineItem.action = #selector(toggleEngine)
        menu.addItem(engineItem)
        localDictationItem.target = self
        localDictationItem.action = #selector(toggleLocalDictation)
        menu.addItem(localDictationItem)

        // "Correction": a submenu with one entry per provider, not a toggle. Three states
        // do not fit a checkmark, and a click that cycled off → local → gemini would put
        // "send my audio to Google" one accidental click past "keep it local". Each entry
        // names its privacy consequence in its own title; the parent shows the state.
        cloudItem.title = "Correction"
        cloudItem.submenu = correctionMenu
        for (kind, entry) in correctionEntries {
            entry.target = self
            entry.action = #selector(selectCorrection(_:))
            entry.representedObject = kind.rawValue
            correctionMenu.addItem(entry)
        }
        menu.addItem(cloudItem)

        autoCorrectItem.title = "Automatic corrections"
        autoCorrectItem.target = self
        autoCorrectItem.action = #selector(toggleAutoCorrect)
        menu.addItem(autoCorrectItem)

        daemonRestartItem.title = "Restart macOS speech service when wedged"
        daemonRestartItem.target = self
        daemonRestartItem.action = #selector(toggleDaemonRestart)
        menu.addItem(daemonRestartItem)

        menu.addItem(.separator())

        // Status lines. No target/action: they are read-outs, not controls.
        for line in [micStatusItem, speechStatusItem, axStatusItem, tapStatusItem, activityItem] {
            line.isEnabled = false
            menu.addItem(line)
        }

        // Usage belongs with the read-outs, but it cannot go through the loop above: that
        // loop disables what it adds, and this one is clickable in every state it is
        // visible in. Hidden until this Mac has sent something (`refreshCreditItems`).
        creditItem.target = self
        creditItem.action = #selector(openCloudQuota)
        creditItem.isHidden = true
        menu.addItem(creditItem)

        // Spend is a plain read-out — no action, so menu validation disables it on its own;
        // saying so explicitly matches the loop above. Hidden until this Mac has actually
        // sent something, because "0 req, 0.0 min, 0 audio tokens" is a line about nothing.
        spendItem.isEnabled = false
        spendItem.isHidden = true
        menu.addItem(spendItem)

        menu.addItem(.separator())

        let axSettings = NSMenuItem(title: "Open Accessibility settings…",
                                    action: #selector(openAccessibilitySettings), keyEquivalent: "")
        axSettings.target = self
        menu.addItem(axSettings)

        let micSettings = NSMenuItem(title: "Open Microphone settings…",
                                     action: #selector(openMicrophoneSettings), keyEquivalent: "")
        micSettings.target = self
        menu.addItem(micSettings)

        let speechSettings = NSMenuItem(title: "Open Speech Recognition settings…",
                                        action: #selector(openSpeechSettings), keyEquivalent: "")
        speechSettings.target = self
        menu.addItem(speechSettings)

        menu.addItem(.separator())

        copyTranscriptItem.title = "Copy last transcript"
        copyTranscriptItem.target = self
        copyTranscriptItem.action = #selector(copyLastTranscript)
        menu.addItem(copyTranscriptItem)

        copyCloudItem.title = "Copy correction"
        copyCloudItem.target = self
        copyCloudItem.action = #selector(copyCloudCorrection)
        menu.addItem(copyCloudItem)

        let showHUD = NSMenuItem(title: "Show dictation HUD",
                                 action: #selector(showHUDPressed), keyEquivalent: "")
        showHUD.target = self
        menu.addItem(showHUD)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MicTest",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        trace("status item installed (variableLength). If it is hidden behind the notch, the "
            + "floating HUD is the other way in — it never fully hides.")
    }

    /// Refreshed every time the menu is about to open, so the numbers are never stale.
    ///
    /// Nothing is fetched here any more. Under fal this opened with a rate-limited billing
    /// probe so the credit line could render fresh; every number the menu now shows is
    /// local state, already current, and a menu open is no longer a network event.
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    private func refreshMenu() {
        dictationItem.title = dictationEnabled
            ? "Dictation: on — tap \(defaultHotkeyName) to start/stop"
            : "Dictation: OFF"
        dictationItem.state = dictationEnabled ? .on : .off

        // ── The engine line ───────────────────────────────────────────────────────────
        // NOT a checkmark toggle. `.state` on this item would have to answer "on for
        // WHICH engine", and both answers are wrong: there is no off. The title carries
        // the whole state instead, which is also why it always names the mode the app is
        // in rather than the one a click would move to.
        //
        // The tooltip is where the consequence is spelled out, and it is set in BOTH
        // states on purpose. A warning that only exists once the risky mode is already
        // selected is a warning nobody reads before selecting it.
        if geminiLiveAvailable {
            engineItem.title = "Dictation engine: \(selectedEngineKind.menuName)"
            engineItem.isEnabled = true
            switch selectedEngineKind {
            case .geminiLive:
                engineItem.toolTip =
                    "Gemini Live streams your microphone audio to Google continuously "
                    + "for as long as you are dictating. Apple (on-device) never sends "
                    + "any audio off this Mac. Click to switch back to Apple; the change "
                    + "takes effect at the next capture."
            case .apple:
                engineItem.toolTip =
                    "Apple (on-device) does all recognition on this Mac — no audio leaves "
                    + "it. Click to switch to Gemini Live, which streams your microphone "
                    + "audio to Google continuously while you dictate; the change takes "
                    + "effect at the next capture."
            }
        } else {
            // Same shape as the Gemini entry of the correction submenu below, because it
            // is the same missing key in the same file: name the file to create and the
            // assignment to put in it.
            engineItem.title = "Dictation engine: Apple (on-device) — Gemini Live "
                + (cloudSetup.keyPath.map { "unavailable: create \($0) with \(GeminiClient.keyName)=…" }
                    ?? (geminiKeyAvailable
                        ? "unavailable: the engine reports it cannot run here"
                        : (cloudSetup.error ?? "unavailable: no \(GeminiClient.keyName)")))
            engineItem.isEnabled = false
            engineItem.toolTip = "Apple (on-device) does all recognition on this Mac — "
                + "no audio leaves it."
        }

        // ── The correction submenu ────────────────────────────────────────────────────
        // Every entry says where the audio goes, in BOTH the available and the
        // unavailable state; the unavailable text names what to install or create.
        localDictationItem.title = localDictationEnabled
            ? "Thai + English: local large-v3 — preview, then type"
            : "Thai + English: local large-v3 (off)"
        localDictationItem.state = localDictationEnabled ? .on : .off
        localDictationItem.isEnabled = !isCapturing && finalQueue.pendingCaptureCount == 0
            && selectedEngineKind == .apple && WhisperServerManager.shared.localFinalConfigured
        localDictationItem.toolTip = "Transcribes completed speech on this Mac and inserts it once. Apple provides the live preview."
        let localName = "local whisper (\(WhisperServerManager.shared.modelName))"
        correctionOffItem.title = "Off — no second-pass rewriting"
        correctionLocalItem.title = localCorrectionConfigured
            ? "\(localName) — audio stays on this Mac"
            : "Local whisper unavailable — "
                + (localBinaryPath == nil
                    ? "brew install whisper-cpp (no whisper-server at /opt/homebrew/bin"
                        + " or /usr/local/bin)"
                    : "no ggml-*.bin model in the search directories"
                        + " (WhisperServerManager.modelSearchDirectories)")
        correctionLocalItem.isEnabled = localCorrectionConfigured
        correctionGeminiItem.title = geminiKeyAvailable
            ? "Gemini (\(GeminiClient.model)) — audio is SENT TO GOOGLE"
            : "Gemini unavailable — "
                + (cloudSetup.keyPath.map { "create \($0) with \(GeminiClient.keyName)=…" }
                    ?? (cloudSetup.error ?? "no key"))
        correctionGeminiItem.isEnabled = geminiKeyAvailable
        for (kind, entry) in correctionEntries {
            entry.state = correctionKind == kind ? .on : .off
        }
        let stateText: String
        switch correctionKind {
        case .off:
            stateText = "off"
        case .local:
            stateText = correctionAvailable
                ? "\(localName) — audio stays on this Mac; server \(localServerStatus)"
                : "local whisper (unavailable — see submenu)"
        case .gemini:
            stateText = correctionAvailable
                ? "Gemini (\(GeminiClient.model)) — audio is sent to Google"
                : "Gemini (unavailable — see submenu)"
        }
        // A pass nobody switched off needs to say why, or the next thing the user does
        // is file a bug about corrections "randomly stopping".
        cloudItem.title = "Correction: \(stateText)"
            + (cloudAutoDisabledReason.map { " (auto-disabled — \($0))" } ?? "")
        cloudItem.toolTip = "The correction pass re-transcribes each finished utterance "
            + "and repairs the typed text; Apple (on-device) always drives the live text. "
            + "A change takes effect at the next capture."

        autoCorrectItem.title = autoCorrectEnabled
            ? "Automatic corrections: on — live text can be rewritten"
            : "Automatic corrections: off — preview, then insert completed text"
        autoCorrectItem.state = autoCorrectEnabled ? .on : .off
        // Meaningless without the correction pass itself.
        autoCorrectItem.isEnabled = !isCapturing && drainTimer == nil && !localDictationEnabled
        autoCorrectItem.toolTip = "Controls live text repairs and second-pass replacement. "
            + "When off, the HUD previews speech and completed text is inserted once. "
            + "Stop dictation before changing this setting."

        daemonRestartItem.title = daemonRestartEnabled
            ? "Restart macOS speech service when wedged: on"
            : "Restart macOS speech service when wedged: off — detected and logged only"
        daemonRestartItem.state = daemonRestartEnabled ? .on : .off

        micStatusItem.title = "Microphone: \(statusPhrase(micStatus))"
        speechStatusItem.title = "Speech recognition: "
            + (speechAuthorized.map { $0 ? "granted" : "DENIED" } ?? "asking…")

        let axOK = hotkey.permissionGranted()
        axStatusItem.title = axOK
            ? "Accessibility: granted (typing into other apps is possible)"
            : "Accessibility: NOT granted — typing is impossible. "
                + "System Settings > Privacy & Security > Accessibility"

        tapStatusItem.title = hotkey.isHealthy
            ? "Hotkey tap: healthy"
            : "Hotkey tap: DEAD — the hold-to-talk key will not respond"

        var activity = isCapturing ? "Listening" : "Idle"
        if let reason = injectionBlockedReason { activity = "Injection blocked — \(reason)" }
        else if utteranceDiverged { activity = "Typed text is stale — see HUD" }
        else if let outcome = lastOutcome { activity = outcome }
        activityItem.title = activity

        refreshCreditItems()

        copyTranscriptItem.isEnabled = !lastTranscript.isEmpty
        copyCloudItem.isEnabled = !unappliedCloudText.isEmpty
        copyCloudItem.isHidden = unappliedCloudText.isEmpty

        // Colour is never the only carrier: the menu text above says the same thing in words.
        let symbol: String
        if !dictationEnabled { symbol = "mic.slash" }
        else if isCapturing { symbol = "mic.fill" }
        else if !axOK || !hotkey.isHealthy { symbol = "exclamationmark.triangle" }
        else { symbol = "mic" }
        statusItem?.button?.image = symbolImage(symbol, size: 14, weight: .regular)
        statusItem?.button?.image?.isTemplate = true
    }

    // MARK: - HUD

    private func wireHUD() {
        hud.onStopRequested = { [weak self] in
            guard let self else { return }
            trace("HUD: stop requested")
            self.wantsDictation = false
            self.syncDictation()
        }

        // Straight to `NSApp.terminate`, deliberately NOT a hand-rolled shutdown.
        // `applicationWillTerminate` already clears `wantsDictation`, tears the capture
        // down, stops the hotkey tap, invalidates every timer and writes the terminating
        // trace line. Repeating any of that here would create a second teardown path that
        // only this button exercises — and the one nobody exercises is the one that rots.
        // The one thing worth doing first is saying WHY the process is about to vanish:
        // the trace would otherwise end at "=== MicTest terminating ===" with no
        // attribution, indistinguishable from a Cmd-Q, the menubar item, or an autostart
        // run reaching its deadline. `isCapturing` rides along because "quit while the
        // microphone was live" and "quit from idle" are different stories when the last
        // capture's stop line is missing from the trace.
        hud.onQuitRequested = { [weak self] in
            guard let self else { return }
            trace("HUD: quit requested (isCapturing=\(self.isCapturing)) — "
                + "terminating via NSApp.terminate; applicationWillTerminate does the teardown")
            NSApp.terminate(nil)
        }
    }

    /// The compact idle form. Uses the real `.idle` case: the panel stays on screen and
    /// clickable, shows a hollow grey `mic` with the word "Idle", and — the part that was
    /// actually wrong before — runs NO level meter.
    ///
    /// This used to pass `.transcribing(idleBody())`, chosen as "the least-wrong of the
    /// six" when `Mode` had no idle case. The body string told the truth while every other
    /// cue contradicted it: the status word read "Transcribing", the icon was an accent-
    /// coloured `waveform`, and `showsMeter(for:)` returns true for `.transcribing`, so a
    /// live meter animated at 30 Hz over a microphone that was off. `DictationHUD.Mode`
    /// now has `.idle`; see it for why the meter was the load-bearing half of the fix.
    private func showIdleHUD() {
        hud.set(.idle(idleBody()))
        hud.show()
    }

    private func idleBody() -> String {
        if let reason = injectionBlockedReason { return reason }
        if !hotkey.permissionGranted() {
            return "Accessibility not granted — MicTest cannot type into other apps. "
                 + "System Settings > Privacy & Security > Accessibility."
        }
        if !hotkey.isHealthy {
            return "Hotkey tap is not running — \(defaultHotkeyName) will not start dictation."
        }
        if speechAuthorized == false && !localDictationEnabled {
            return "Speech recognition not authorized — "
                 + "System Settings > Privacy & Security > Speech Recognition."
        }
        if micStatus == .denied || micStatus == .restricted {
            return "Microphone \(statusPhrase(micStatus)) — "
                 + "System Settings > Privacy & Security > Microphone."
        }
        if !lastTranscript.isEmpty { return lastTranscript }
        return hudIdleBody
    }

    // MARK: - Recognizer wiring

    /// Point exactly ONE engine at the event box, and disconnect the other.
    ///
    /// The three closures are `@Sendable` and run on the engine's own queue (Speech's, or
    /// the Gemini socket's). They capture the event box — a lock-protected
    /// `@unchecked Sendable` class — and nothing else: not `self`, not the main actor, and
    /// never `trace()` (a file write per partial would be both slow and a privacy leak).
    /// See `DictationEngine.bindEvents(to:)` for the bodies, which are unchanged from the
    /// three lines that used to be inline here.
    ///
    /// WHY THE OTHER ENGINE IS EXPLICITLY UNBOUND, rather than left connected on the
    /// argument that a stopped engine emits nothing. `LiveRecognizer` demonstrably does
    /// emit after being told to stop — it re-reports `persistent recognition failure` on
    /// every retry cycle at an 8 s backoff — and a WebSocket client with a reconnect loop
    /// has every reason to do the same. One late `.unavailable` from the engine the user
    /// just switched AWAY from would land in the box mid-session, reach
    /// `handleRecognizerState`, and paint the HUD red about a recogniser that is not
    /// running. Unbinding closes that structurally instead of trusting a promise made in
    /// another file.
    ///
    /// Called at launch and again from `beginCapture`'s full start, which is where the
    /// active engine is actually decided.
    private func wireRecognizer() {
        let box = events
        switch activeEngineKind {
        case .apple:
            geminiRecognizer.unbindEvents()
            recognizer.bindEvents(to: box)
        case .geminiLive:
            recognizer.unbindEvents()
            geminiRecognizer.bindEvents(to: box)
        }
    }

    // MARK: - Hotkey wiring

    private func wireHotkey() {
        // TOGGLE MODE, by the user's explicit choice: holding a modifier for a long
        // dictation is tiring and every hold-length problem (chatter, state-poll lies,
        // synthesized releases) simply vanishes when the key edge is a toggle. Tap
        // Right-Option once to start dictating, tap again to stop. The release edge is
        // ignored entirely.
        //
        // WHERE THIS RUNS — changed 2026-08-27, read before moving work in here.
        // This no longer runs inside the CGEventTap callback. Chord rejection made
        // down-edge delivery impossible: whether a press is a hotkey tap or the Option
        // half of Option+Left is not knowable until the key comes back UP, and a toggle
        // cannot be taken back once the engine is running and text has been typed. So
        // HotkeyMonitor snapshots the verdict at key-up and fires this from its deferred
        // release on the main queue — roughly 110 ms later than the old behaviour. The
        // tap's own latency budget therefore no longer binds this closure.
        //
        // Keep it small anyway. That 110 ms already sits between the user's tap and the
        // first frame of audio; anything slow added here lands on top of it and presents
        // as "the hotkey feels laggy".
        hotkey.onPressStart = { [weak self] in
            guard let self else { return }
            self.wantsDictation.toggle()
            // Trace the EDGE, not just its consequence. Without this line a physical tap is
            // invisible: the only evidence is `endCapture(reason: "hotkey released")`, which
            // is the same sentence `syncDictation()` prints for every other route to
            // `wantsDictation == false`. A capture that stops because the user tapped the key
            // then reads exactly like one that stopped because something failed — and in
            // toggle mode the stray-tap case is easy to hit, because the tap stays armed
            // during headless MICTEST_AUTOSTART runs and silently ends them early (measured
            // 2026-08-30: a 45 s hold cut to 36 s, which also skipped the second rotation and
            // made the seam machinery look broken when it was not).
            trace("HOTKEY: tap — wantsDictation -> \(self.wantsDictation) (toggle mode)")
            Task { @MainActor [weak self] in self?.syncDictation() }
        }

        // Toggle mode: the key-up edge means nothing, and since 2026-08-27 HotkeyMonitor
        // does not fire this at all — the up-edge is where the chord verdict is decided and
        // where `onPressStart` is now delivered from. Kept assigned rather than left nil so
        // that anyone re-wiring hold-to-talk has to read why it is dead first.
        hotkey.onPressEnd = { }

        // ── The off-switch died while the microphone was live ────────────────────────
        //
        // Toggle mode is what makes this reachable. All four of the monitor's stuck-on
        // defences (`synthesizeReleaseIfHolding`, `maxHoldDuration`, the state poll,
        // `onPressEnd`) are gated on `isHolding`, which in toggle mode is true only for
        // the ~100 ms a physical tap is down — so every one of them is inert here. Lock
        // the screen or click a password field and Secure Event Input kills every session
        // event tap: `wantsDictation` stays true, `endCapture` is never called, the
        // microphone keeps recording, and the ONLY remaining off-switch is the hotkey,
        // dead for exactly the same reason.
        //
        // `onHotkeyUnusable` fires once per transition into that state (not per poll), on
        // the main actor. Treat it as an emergency stop, not a graceful release.
        hotkey.onHotkeyUnusable = { [weak self] in
            guard let self else { return }
            self.stopBecauseOffSwitchIsUnreachable(
                why: "hotkey tap is unusable — Secure Event Input or a tap that could not be reinstalled",
                message: "Dictation stopped: MicTest can no longer see \(defaultHotkeyName). "
                    + "Secure input (a password field, the lock screen, or Terminal secure entry) "
                    + "shuts off every event tap, and the hotkey is the only way to stop "
                    + "recording — so the microphone was switched off rather than left live "
                    + "with no way to turn it off.")
        }
    }

    /// System-state observers that exist for exactly one reason: **the microphone must
    /// never outlive the user's ability to turn it off.**
    ///
    /// The event tap dies for reasons this app cannot see and is never told about — Secure
    /// Event Input taken by another process, the login window, a tap disabled by timeout
    /// that fails to reinstall. Sleep and screen-lock are the two transitions where that is
    /// most likely AND where a live microphone is least excusable, and they are observable
    /// directly rather than inferred, so observe them directly. There were no
    /// `willSleep`/`screenIsLocked` observers anywhere in this project before this build.
    ///
    /// Selector-based, not closure-based, for the same reason the timers in
    /// `applicationDidFinishLaunching` are: it keeps us clear of `@Sendable`-closure
    /// capture questions under `-swift-version 6`. Never unregistered — this delegate lives
    /// for the whole process, and `DistributedNotificationCenter` does not clean up after a
    /// deallocated observer the way `NotificationCenter` does, so an observer with a
    /// shorter life than the app would be a dangling-pointer bug, not a leak.
    private func wireSystemStateObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil)

        // Not an AppKit constant: screen lock/unlock is only published on the DISTRIBUTED
        // centre, by name, and only while a session is active.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenWasLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)

        trace("system-state observers: willSleep + com.apple.screenIsLocked armed "
            + "(microphone must not outlive the ability to stop it)")
    }

    @objc private func systemWillSleep(_ note: Notification) {
        // BEFORE the shared handler, whose `actingNow` guard returns early when nothing
        // is live: the local server is up between captures precisely when nothing is
        // live, and it must not keep 1.6 GB resident and a loopback listener open
        // through sleep — "must not outlive the ability to stop it" applies to it too.
        stopLocalServer(reason: "the Mac is going to sleep")
        stopBecauseOffSwitchIsUnreachable(
            why: "the Mac is going to sleep",
            message: "Dictation stopped because the Mac is going to sleep.")
    }

    @objc private func screenWasLocked(_ note: Notification) {
        stopLocalServer(reason: "the screen was locked")   // see `systemWillSleep`
        stopBecauseOffSwitchIsUnreachable(
            why: "the screen was locked",
            message: "Dictation stopped because the screen was locked. The lock screen takes "
                + "Secure Event Input, which kills the hotkey — leaving the microphone live "
                + "with no way to stop it.")
    }

    /// Emergency stop: something removed the user's ability to turn the microphone off.
    ///
    /// Deliberately NOT `endCapture` + release drain. The drain exists to catch the tail of
    /// speech after a deliberate key release; here nothing was released, the user may not
    /// even be at the machine, and the correct latency for "the microphone is live and
    /// unstoppable" is zero. `finishCapture` is the full synchronous teardown and it
    /// invalidates any drain already in flight.
    ///
    /// ORDERING IS LOAD-BEARING, and it is the same order `fail()` documents:
    ///   1. `wantsDictation = false` FIRST, or the self-heal `syncDictation()` at the end
    ///      of `finishCapture` reads it as still-true and starts a fresh session — the
    ///      exact stuck-microphone this function exists to prevent;
    ///   2. teardown;
    ///   3. the HUD error LAST, because `finishCapture` calls `showIdleHUD()` on its way
    ///      out and would otherwise overwrite the explanation seconds later. A microphone
    ///      that switched itself off without saying why is its own bug.
    private func stopBecauseOffSwitchIsUnreachable(why: String, message: String) {
        localTranscriptionSuspended = true
        for id in finalCaptures.keys {
            finalCaptures[id]?.failure = "Dictation stopped — \(why). Use Copy last transcript for completed text."
        }
        let wasLive = isCapturing || drainTimer != nil
        let actingNow = wasLive || wantsDictation
        // Trace unconditionally: "the hotkey died while idle" is a real diagnosis too, and
        // it is the line that explains why the next tap does nothing.
        //
        // The LABEL is conditional on purpose, and the reason is this file's own history.
        // Every ordinary sleep and screen-lock reaches here, so an all-caps alarm printed
        // when nothing was running would fire several times a night and teach whoever reads
        // this file to skim past it -- and then it is not there on the one occasion the
        // microphone really was live and unstoppable. Measured 2026-08-27, first night after
        // the observers landed: three OFF-SWITCH LOST lines, all three "nothing was live".
        // Spend the loud label only when something was actually taken away.
        trace((actingNow ? "OFF-SWITCH LOST: " : "off-switch watch: ")
            + "\(why) — wantsDictation=\(wantsDictation) "
            + "isCapturing=\(isCapturing) hotkeyHealthy=\(hotkey.isHealthy)"
            + (actingNow ? "; stopping capture" : "; nothing was live"))
        guard actingNow else { return }

        wantsDictation = false
        if wasLive { finishCapture(reason: "off-switch lost: \(why)") }
        lastOutcome = "Dictation stopped — \(why)"
        hud.set(.error(message))
        hud.show()
        refreshMenu()
    }

    /// Reconcile actual state with `wantsDictation`. Idempotent and order-independent — see
    /// the comment on `wantsDictation`.
    private func syncDictation() {
        if wantsDictation && dictationEnabled {
            beginCapture()
        } else if !wantsDictation {
            endCapture(reason: "hotkey released")
        }
    }

    // MARK: - Capture

    private func beginCapture() {
        // New recording gets its own audio and target while older results drain.
        if activeLocalDictation && drainTimer != nil {
            finishCapture(reason: "new capture during local finalization")
        }
        // A press that arrives during the drain window cancels the teardown: the user has
        // pressed again, and this is one continuous session as far as the engine is concerned.
        if drainTimer != nil {
            drainTimer?.invalidate()
            drainTimer = nil
            trace("beginCapture: cancelled a pending drain")
            if isCapturing {
                tickUI()
                insertStableTranscript()
                injector.captureBufferedTarget()
                // The engine is still live but the recogniser was stopped on release; restart
                // it so the new utterance gets its own session rather than silently producing
                // no partials at all.
                //
                // `activeEngine`, and deliberately NOT `selectedEngineKind`: this branch
                // CONTINUES the session that is still draining, so switching the engine
                // from the menu inside the release window and immediately re-pressing the
                // hotkey resumes the engine the session started with. That is the correct
                // reading of "takes effect at the next capture" — this is not one — and it
                // matters concretely, because the audio tap installed below in the full
                // start is still feeding whichever engine it captured.
                do {
                    try activeEngine.start()
                    // A fresh recognition request has, by definition, produced no events
                    // yet. Stamp the liveness clock so a timestamp left over from before
                    // the release cannot bounce this brand-new, healthy recogniser on the
                    // watchdog's very first tick.
                    lastRecognizerEventAt = Date()
                    loudTicksSinceRecognizerEvent = 0
                    // Same engine session, but a brand-new recognition request that has
                    // produced nothing yet. (`escalationsThisSession` is NOT reset here:
                    // a drain-cancel resume is the same session as far as the escalation
                    // damper is concerned.)
                    sessionSawPartial = false
                    // `startUtterance()` clears `currentOnDeviceText` because a NEW session
                    // starts from silence — but this resume continues the SAME engine and
                    // pipeline, and a chunk finalized around the restart still needs that
                    // text to pass `noteFinalChunk`'s anti-hallucination gate (a refused
                    // chunk's ledger snapshot is consumed and lost either way). Carry the
                    // text across the reset; the next partial overwrites it anyway.
                    let carriedOnDeviceText = currentOnDeviceText
                    startUtterance()
                    currentOnDeviceText = carriedOnDeviceText
                } catch {
                    // TEARDOWN FIRST, error display second — the order is load-bearing.
                    // On this path the engine, tap, pipeline, and chunk loop are all still
                    // LIVE (the drain was cancelled, not completed). `fail()` alone would
                    // leave the microphone hot and chunks still uploading to the cloud while the
                    // HUD claims failure, with `wantsDictation` forced false so the next
                    // tap is a no-op — the user would need three taps to actually stop.
                    // `finishCapture` tears all of that down; its deferred syncDictation
                    // then no-ops (wantsDictation is false), and `fail()`'s error HUD is
                    // the last write, so the user sees the recogniser error, not idle.
                    finishCapture(reason: "drain-cancel restart failed")
                    let desc = describeRecognizerError(error)
                    fail("\(activeEngineKind.recognizerNoun) could not restart: \(desc)",
                         context: "beginCapture(drain): \(activeEngineKind.rawValue) "
                            + "start() threw — \(desc)")
                }
                return
            }
        }

        guard !isCapturing, !localTerminationRequested else { return }
        localTranscriptionSuspended = false

        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        trace("beginCapture: micStatus=\(statusName(micStatus)) "
            + "speechAuthorized=\(speechAuthorized.map(String.init(describing:)) ?? "pending") "
            + "axTrusted=\(hotkey.permissionGranted())")

        let e = AVAudioEngine()
        // NOTE: merely touching inputNode can itself trigger the TCC prompt.
        let input = e.inputNode
        let format = input.inputFormat(forBus: 0)

        // When permission is missing the input node reports a 0 Hz / 0-channel format, and
        // installTap with that format raises an uncatchable ObjC exception. Bail out visibly
        // instead of dying; do/catch around engine.start() would NOT save us here.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            let msg = "No usable input device (format \(format.sampleRate) Hz / "
                + "\(format.channelCount) ch, microphone \(statusPhrase(micStatus))). "
                + "System Settings > Privacy & Security > Microphone."
            fail(msg, context: "beginCapture: bad input format")
            return
        }

        // Resolve the synthetic source here, BEFORE the tap and the engine, for the same
        // reason the pipeline is built here: a failure must return from a state with nothing
        // installed and nothing started. It is also the earliest point at which `format` —
        // the real tap format it has to match — is known to be valid.
        //
        // A NAMED-BUT-UNUSABLE FILE IS A HARD STOP, NOT A FALLBACK. Silently carrying on with
        // the live microphone would hand back a run full of `+0 chars` seams that look exactly
        // like the silent-room result this harness exists to escape — a false negative dressed
        // as a measurement. Better to refuse the capture and say why.
        var synth: SyntheticAudioSource?
        if let audioFile = ProcessInfo.processInfo.environment["MICTEST_AUDIO_FILE"],
           !audioFile.isEmpty {
            do {
                synth = try SyntheticAudioSource(path: audioFile, tapFormat: format)
            } catch {
                fail("MICTEST_AUDIO_FILE is set but unusable: \(error)",
                     context: "beginCapture: SyntheticAudioSource init failed — \(error)")
                return
            }
        }

        // Build the pipeline BEFORE installing the tap. If its init throws we want to return
        // from a state with no tap installed and no engine started — a tap left attached to
        // an abandoned node is precisely what makes the *next* start raise the double-install
        // exception.
        let pipe: AudioPipeline
        do {
            pipe = try AudioPipeline(inputFormat: format, mode: localDictationEnabled ? .localDictation : .correction)
        } catch {
            let desc = describePipelineError(error)
            fail("Audio pipeline could not start: \(desc)",
                 context: "beginCapture: AudioPipeline init threw — \(desc)")
            return
        }
        pipe.reset()

        events.clear()
        levelBox.reset()
        // The periodic LEVEL line's baseline, and it obeys the same adjacency rule as the
        // block below for a sharper reason: `levelBox.reset()` zeroes `frames`, so a
        // baseline left behind by the previous capture would make the first line of this
        // one subtract a larger number from a smaller one. Unsigned, so it would print
        // ~1.8e19 rather than something recognisably wrong. The tick counter is zeroed
        // alongside it so the first line lands ~5 s into the capture instead of at a random
        // offset inherited from the last one.
        levelLineLastFrames = 0
        levelLineTicks = 0
        levelLinePeak = 0
        // Adjacent to `levelBox.reset()` on purpose, and it must stay adjacent: the
        // per-capture counters and the `frames` count printed beside them on the same
        // "capture stopped" line are only comparable if they measure the same span of wall
        // time, and sharing one code path is the only way to guarantee that without a
        // comment nobody reads. Note which path this is — the FULL start. The drain-cancel
        // resume at the top of this method returns long before here, which is correct: that
        // resume continues the SAME engine session, so neither `frames` nor these counters
        // restart for it. The case this reset exists for is the opposite one: a watchdog
        // teardown (`endCapture` -> `finishCapture`) whose self-heal lands back here as a
        // genuinely new capture — exactly the sequence that produced the 17:54 pair of
        // identical stop lines described on `TraceCounters`.
        //
        // That self-heal cannot accidentally take the drain-cancel branch and skip this:
        // `beginCapture` has exactly one caller (`syncDictation`), the self-heal is deferred
        // from `finishCapture`, and `finishCapture` invalidates and nils `drainTimer` before
        // it defers. `tickStatus` never calls `syncDictation` at all — the watchdog only
        // calls `endCapture` and lets `drainElapsed` carry it the rest of the way. So the
        // ONLY route to the drain-cancel branch is a real hotkey re-press inside the drain
        // window, which is the one case that should keep counting.
        thisCapture = TraceCounters()
        // The same reasoning as the reset above, applied to the room instead of the
        // counters: a noise floor measured in a previous session — possibly a different
        // room, possibly hours ago — must not gate this one. Cleared on the FULL start
        // only. The drain-cancel resume at the top of this method returns long before here
        // and keeps the floor it has already measured, which is correct: it continues the
        // SAME engine session in the same room, exactly as it continues the same `frames`
        // count. Re-seeding happens on the first `tickStatus` sample that reaches
        // `absoluteQuietFloor`; see `noiseFloorSeeded` for why the bound is that and not
        // merely non-zero, and for why a room quieter than it never seeds at all.
        noiseFloor = 0
        noiseFloorSeeded = false
        nonFiniteRMSTracedThisCapture = false

        // ── THE ONE PLACE THE ENGINE IS CHOSEN ────────────────────────────────────────
        // Read the user's choice here, at the full start, and nowhere else. Everything
        // after this line — the tap's captured reference, every `stop()`, the watchdog
        // gate, both trace summaries — goes through `activeEngine`/`activeEngineKind`, so
        // a menu click mid-session cannot split one capture across two engines. Same
        // precedent as the correction pass's chunk loop, decided once at session start (see
        // the REALTIME-FIRST GATE below and `selectCorrection`).
        if activeEngineKind != selectedEngineKind {
            trace("engine: switching \(activeEngineKind.rawValue) -> \(selectedEngineKind.rawValue) "
                + "for this capture")
        }
        activeEngineKind = selectedEngineKind
        activeLocalDictation = localDictationEnabled
        // Rebind before start(), so the first event the new engine emits already has
        // somewhere to go — and so the engine we are NOT running is disconnected before it
        // could post a late reconnect/retry report into this session's queue.
        wireRecognizer()
        do {
            try activeEngine.start()
        } catch {
            let desc = describeRecognizerError(error)
            if activeLocalDictation {
                trace("LOCAL FINAL: Apple preview unavailable; local audio capture continues")
            } else {
                fail("\(activeEngineKind.recognizerNoun) could not start: \(desc)",
                     context: "beginCapture: \(activeEngineKind.rawValue) start() threw — \(desc)")
                return
            }
        }
        // A fresh recogniser has produced no events yet; a timestamp inherited from a
        // previous session is stale by definition. Stamp the liveness clock now so the
        // recogniser watchdog cannot bounce a brand-new, healthy request on its first tick.
        lastRecognizerEventAt = Date()
        // The accumulated loud-tick evidence goes with it, by the same argument the
        // drain-cancel resume at the top of this method already makes for itself. This line
        // is not decoration: it took over a job that the `.state` branch of the event pump
        // used to do by accident before that reset was removed (see it for why it had to
        // go). The counter is only ever incremented inside `tickStatus`'s `isCapturing`
        // branch and is otherwise cleared only by real output or by the watchdog's own
        // strike, so these two `beginCapture` paths are between them the complete set of
        // session boundaries. Without this, ticks measured while the LAST session's
        // recogniser was dying would arm the ladder against a brand-new, healthy one.
        loudTicksSinceRecognizerEvent = 0
        // No partial has been drained for this brand-new session yet.
        // `escalationsThisSession` deliberately does NOT reset here: the watchdog's own
        // escalation lands back in this very path via the self-heal, and resetting would
        // hand every churned-up session a fresh speculative restart -- the exact ambient
        // loop the damper exists to stop. The count resets when a DELIBERATE stop ends
        // the session instead (see `finishCapture`).
        sessionSawPartial = false

        // Capture only Sendable collaborators; never self, never UI.
        //
        // `rec` is the requirement that keeps the audio thread honest: the active engine is
        // resolved ONCE, here, into a single stored reference the tap closure captures. The
        // realtime callback therefore does no lookup, no switch, and above all no
        // UserDefaults read — it calls `append` on the object it was handed. `activeEngine`
        // is a two-case switch on a stored enum and this is the only place it is paid for
        // per capture.
        let box = levelBox
        let rec = activeEngine

        // Captured as a plain `Bool`, resolved once here, for exactly the reason the comment
        // above gives for `rec`: the realtime thread must never be where a question gets
        // answered. This is a predicted branch on an immutable capture, not a lookup.
        let syntheticActive = (synth != nil)

        // The `@Sendable` here is load-bearing, not decoration. See AppDelegate.processTap.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            // The microphone keeps running under a synthetic source and its buffers are
            // dropped right here. Discarding rather than never installing is deliberate: it
            // leaves the engine lifecycle, the tap format, and every line of teardown
            // identical between a harness run and a real one. See SyntheticAudioSource.swift,
            // "why the microphone stays open".
            if syntheticActive { return }
            // Realtime audio thread. Hand the buffer on and store the level, nothing else.
            AppDelegate.processTap(buffer, into: box, pipeline: pipe, engine: rec)
        }

        e.prepare()
        do {
            try e.start()
        } catch {
            let ns = error as NSError
            input.removeTap(onBus: 0)   // undo the tap we just installed
            activeEngine.stop()
            fail("Audio engine did not start: \(ns.localizedDescription)",
                 context: "beginCapture: engine.start() threw \(ns.domain) code \(ns.code)")
            return
        }

        engine = e
        pipeline = pipe
        isCapturing = true
        sessions += 1

        // Started only after the state above is consistent: the first buffer it delivers
        // reaches `LiveRecognizer.append` immediately, and everything that answers for that
        // audio downstream assumes a capture is fully begun.
        syntheticSource = synth
        synth?.start { [box, pipe, rec] buffer in
            // The same call the microphone's own buffers make, one line above in the tap
            // closure, with the same three collaborators resolved at the same moment. That
            // sameness is the harness's entire claim to validity.
            AppDelegate.processTap(buffer, into: box, pipeline: pipe, engine: rec)
        }

        captureGeneration &+= 1
        let gen = captureGeneration
        chunkTask?.cancel()
        chunkTask = nil
        flushRequest = nil

        // REALTIME-FIRST GATE: the chunk loop exists only to feed the correction pass. When
        // the pass is off at capture start there is nothing to feed — polling takeChunk()
        // (a ring-buffer copy + WAV encode per chunk) only for noteFinalChunk to refuse
        // every dispatch is pure waste on the consumer side of the audio path, so the loop
        // is not created at all. (The pipeline itself stays: the tap's append writes into
        // a preallocated 30 s ring whose count saturates at capacity, and chunks are cut
        // lazily inside takeChunk()/flush(), so an unpolled pipeline cannot grow memory.)
        // The effective state is read HERE, on the MainActor, at session start; selecting
        // a provider mid-session therefore takes effect at the NEXT session start — traced
        // in `selectCorrection` so it is not mistaken for a bug, and `noteFinalChunk`
        // refuses the running session's sends once the kinds differ. The stop paths already
        // tolerate the nils: `drainElapsed` flushes via `flushRequest?.request()` and
        // `finishCapture` cancels via `chunkTask?.cancel()`, both optional-chained no-ops.
        //
        // The gate is CONFIGURED, not READY (`localCorrectionConfigured`): a local server
        // still loading is not a reason to skip the loop — it is the provider's job to
        // wait for it, and the preload has usually finished long before now.
        if activeLocalDictation {
            let id: FinalQueue.CaptureID
            do { id = try finalQueue.beginCapture() }
            catch {
                wantsDictation = false
                finishCapture(reason: "local transcription queue full")
                fail("Transcription is still catching up — try again shortly", context: "local capture capacity reached")
                return
            }
            localCaptureID = id
            let loadedTerms = UserKeyterms.load()
            let terms = UserKeyterms.merge(user: loadedTerms.terms, builtin: cloudKeyterms)
            finalCaptures[id] = FinalCapture(target: injector.captureBufferedTarget(), keyterms: terms)
            activeCorrectionKind = .off
            startLocalServer(reason: "bilingual capture")
            chunkTask = Task.detached { [weak self] in
                await self?.localChunkLoop(pipeline: pipe, capture: id)
            }
            trace("LOCAL FINAL: capture \(id.sequence) started; Apple is preview only")
        } else if correctionEnabled, let cloud = correctionProvider {
            activeCorrectionKind = correctionKind
            // Off the hotkey path: both are detached work that publishes back later. The
            // server kick is the retry path for a preload that failed or an idle stop.
            startLocalServer(reason: "capture start")
            reloadKeyterms(reason: "capture start")
            // One flush flag per session, shared with exactly this session's loop.
            let flushBox = FlushRequestBox()
            flushRequest = flushBox
            // Task.detached, not Task {}: a plain Task created inside a @MainActor method inherits
            // MainActor isolation, which would drag takeChunk() — a call that copies a ring buffer
            // and encodes a WAV — onto the main thread. Detached runs on the generic executor, and
            // every UI touch inside hops explicitly via MainActor.run.
            chunkTask = Task.detached { [weak self] in
                guard let self else { return }
                await self.chunkLoop(pipeline: pipe, cloud: cloud, generation: gen,
                                     flushRequest: flushBox)
            }
        } else {
            activeCorrectionKind = .off
            trace("LOOP[\(gen)]: chunk loop not started "
                + "(correction pass \(correctionGateState))")
        }

        finalOnlyInjection = false   // new session, new focused app: try live typing again
        // New pipeline, new generation: a span typed for a previous session's audio must
        // never be offered to this session's cloud pass.
        typedSinceLastChunk = ""
        injector.captureBufferedTarget()
        startUtterance()
        lastOutcome = nil
        trace(String(format: "capture started OK — session %d, generation %d, %.0f Hz / %u ch",
                     sessions, gen, format.sampleRate, format.channelCount))
        refreshMenu()
    }

    @objc private func toggleLocalDictation() {
        guard !isCapturing, finalQueue.pendingCaptureCount == 0,
              WhisperServerManager.shared.localFinalConfigured else { return }
        let next = !localDictationEnabled
        UserDefaults.standard.set(next, forKey: "localBilingualDictation")
        if next { startLocalServer(reason: "bilingual dictation selected") }
        refreshMenu()
    }

    /// Audio cutting never waits for inference. This task alone consumes its pipe.
    nonisolated private func localChunkLoop(pipeline: AudioPipeline,
                                            capture: FinalQueue.CaptureID) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
            if Task.isCancelled { break }
            if let chunk = pipeline.takeChunk(), chunk.isFinal {
                await enqueueLocalChunk(chunk.wav, capture: capture)
            }
        }
        // finishCapture has already removed the tap and stopped the audio producer.
        while let chunk = pipeline.flush() {
            await enqueueLocalChunk(chunk.wav, capture: capture)
        }
        await sealLocalCapture(capture)
    }

    private func enqueueLocalChunk(_ wav: Data, capture: FinalQueue.CaptureID) {
        do {
            let id = try finalQueue.enqueue(wav, byteCount: wav.count, in: capture)
            trace("LOCAL FINAL: queued capture \(capture.sequence), chunk \(id.sequence), \(wav.count) bytes")
            pumpLocalTranscription()
        } catch {
            let recovery = preserveLocalAudio(wav, capture: capture)
            finalCaptures[capture]?.failure = "Transcription queue is full. \(recovery)"
            injectionBlockedReason = finalCaptures[capture]?.failure
            if localCaptureID == capture {
                wantsDictation = false
                finishCapture(reason: "local transcription backpressure")
            }
            hud.set(.error(injectionBlockedReason ?? "Transcription queue is full"))
            hud.show()
        }
    }

    private func sealLocalCapture(_ capture: FinalQueue.CaptureID) {
        _ = finalQueue.stopCapture(capture)
        deliverLocalResults()
        pumpLocalTranscription()
        if !isCapturing && finalQueue.pendingChunkCount > 0 {
            hud.set(.transcribing("Finishing Thai + English…"))
        }
    }

    private func pumpLocalTranscription() {
        guard localWorker == nil else { return }
        localIdleStopTask?.cancel()
        localWorker = Task { [weak self] in
            guard let self else { return }
            while let work = self.finalQueue.nextWork() {
                let terms = self.finalCaptures[work.id.capture]?.keyterms ?? []
                do {
                    let manager = WhisperServerManager.shared
                    guard manager.localFinalConfigured else {
                        throw LocalWhisperTranscriber.Failure.invalidReply
                    }
                    guard !self.localTranscriptionSuspended else { throw CancellationError() }
                    await self.serverLifecycle?.value
                    guard !self.localTranscriptionSuspended else { throw CancellationError() }
                    let endpoint = try await manager.ensureReady()
                    guard !self.localTranscriptionSuspended else { throw CancellationError() }
                    guard let port = endpoint.port else {
                        throw LocalWhisperTranscriber.Failure.invalidReply
                    }
                    let text = try await LocalWhisperTranscriber().transcribe(
                        wav: work.payload, keyterms: terms, port: port)
                    guard !self.localTranscriptionSuspended else { throw CancellationError() }
                    _ = self.finalQueue.complete(work.id, with: .success(text))
                } catch {
                    let recovery = self.preserveLocalAudio(work.payload, capture: work.id.capture)
                    _ = self.finalQueue.complete(work.id, with: .failure(
                        "Local transcription failed: \(error.localizedDescription). \(recovery)"))
                }
                self.deliverLocalResults()

            }
            self.localWorker = nil
            self.deliverLocalResults()
            self.armLocalIdleStop()
            self.finishLocalTerminationIfReady()
        }
    }

    private func deliverLocalResults() {
        guard localDeliveryTask == nil else { return }
        localDeliveryTask = Task { [weak self] in
            guard let self else { return }
            while let event = self.finalQueue.takeReadyEvents(limit: 1).first {
                self.deliverLocalEvent(event)
                // Pace each event, including a batch released by a capture boundary.
                // The audio consumer and inference worker continue independently.
                try? await Task.sleep(for: .milliseconds(750))
            }
            self.localDeliveryTask = nil
            self.armLocalIdleStop()
            self.finishLocalTerminationIfReady()
        }
    }

    private func deliverLocalEvent(_ event: FinalQueue.Event) {
            switch event {
            case .result(let id, let outcome):
                guard var capture = finalCaptures[id.capture] else { return }
                switch outcome {
                case .success(let raw):
                    let text = normalizeForInjection(raw, kind: "local final")
                    guard !text.isEmpty else { return }
                    let addition = (capture.transcript.isEmpty ? "" : " ") + text
                    capture.transcript += addition
                    lastTranscript = capture.transcript
                    if capture.failure == nil {
                        if let reason = injector.injectBuffered(addition, target: capture.target) {
                            capture.failure = reason
                            lifetime.injectFailures += 1
                        } else {
                            clearInjectionBlockAfterSuccessfulWrite()
                            lifetime.injectedChars += addition.count
                            if localCaptureID == id.capture { thisCapture.injectedChars += addition.count }
                            trace("LOCAL FINAL: inserted capture \(id.capture.sequence), chunk \(id.sequence), \(addition.count) chars once")
                        }
                    }
                case .failure(let reason):
                    capture.failure = reason
                    trace("LOCAL FINAL: capture \(id.capture.sequence), chunk \(id.sequence) failed; recovery available")
                }
                finalCaptures[id.capture] = capture
                if let reason = capture.failure {
                    injectionBlockedReason = reason
                    lastOutcome = "Transcript kept for Copy last transcript — \(reason)"
                    hud.set(.error(reason))
                    hud.show()
                }
            case .captureDrained(let id):
                let capture = finalCaptures.removeValue(forKey: id)
                if let capture, !capture.transcript.isEmpty { lastTranscript = capture.transcript }
                trace("LOCAL FINAL: capture \(id.sequence) fully drained")
                if !isCapturing && finalQueue.pendingCaptureCount == 0 && capture?.failure == nil {
                    hud.set(.idle(idleBody()))
                }
            }
        refreshMenu()
    }

    /// Failed audio stays on this Mac with user-only permissions for recovery.
    private func preserveLocalAudio(_ wav: Data, capture: FinalQueue.CaptureID) -> String {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MicTest/Recovery", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("capture-\(capture.sequence)-\(UUID().uuidString).wav")
            try wav.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            trace("LOCAL FINAL: audio recovery saved at \(file.path)")
            return "Audio saved in \(folder.path)"
        } catch {
            return "Audio recovery could not be saved: \(error.localizedDescription)"
        }
    }

    /// Reset the per-utterance injection bookkeeping and put the HUD into listening.
    private func startUtterance() {
        injectedForUtterance = ""
        stableTranscript.reset()
        // The ledger claims nothing again, so no deferred repair is outstanding.
        transientRepairSkips = 0
        cloudOwnsUtterance = false
        currentOnDeviceText = ""
        utteranceDiverged = false
        injectionBlockedReason = nil
        unappliedCloudText = ""
        hud.set(.listening)
        hud.show()
    }

    /// The hotkey came up (or the HUD's stop button was clicked). Stop the recogniser at
    /// once so the final result starts arriving, but leave the engine running for
    /// `releaseDrainSeconds` — see that constant for why.
    private func endCapture(reason: String) {
        guard isCapturing, drainTimer == nil else { return }
        activeEngine.stop()
        trace("endCapture(\(reason)): recogniser stopped; draining audio for "
            + String(format: "%.1f s", releaseDrainSeconds))

        if !currentOnDeviceText.isEmpty {
            hud.set(.transcribing(currentOnDeviceText))
        }

        let t = Timer(timeInterval: releaseDrainSeconds, target: self,
                      selector: #selector(drainElapsed), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        drainTimer = t
        refreshMenu()
    }

    @objc private func drainElapsed() {
        drainTimer = nil
        // Drain any final already queued before falling back to the latest partial.
        tickUI()
        insertStableTranscript()
        // The release drain is over — no more audio is coming. Ask the chunk loop to
        // force-finalize whatever the trailing-silence gate is still holding: with the
        // room's ambient RMS above the silence threshold, that gate never opens on its
        // own and the utterance would otherwise die in the ring (finalChunks=0).
        flushRequest?.request()
        finishCapture(reason: "release drain complete")
    }

    /// Tear the audio stack down. Deliberately does NOT bump `captureGeneration` and does
    /// NOT cancel `cloudTask`: the cloud pass answers after the key is released, which is
    /// the entire point of it.
    private func finishCapture(reason: String) {
        // Cancelling the chunk task is what pops its loop out of the 200 ms sleep; the
        // loop then consumes any pending flush request on its way out (see `chunkLoop`),
        // so the order here — request first (in the callers that want it), cancel second —
        // is what makes the release-drain flush actually run. In a realtime-only session
        // (cloud pass disabled at capture start) both are already nil and these lines
        // are deliberate no-ops.
        // Freeze audio before cancelling: the local consumer drains the old pipe.
        if activeLocalDictation {
            syntheticSource?.stop()
            if let e = engine, isCapturing {
                e.inputNode.removeTap(onBus: 0)
                e.stop()
            }
        }
        chunkTask?.cancel()
        chunkTask = nil
        flushRequest = nil
        localCaptureID = nil
        drainTimer?.invalidate()
        drainTimer = nil
        armLocalIdleStop()

        // Above the `isCapturing` guard on purpose. `finishCapture` returns early on any path
        // where the capture was already torn down, and a pacing thread left running past that
        // point would go on calling `append` on a stopped recogniser for the rest of the
        // process's life. `stop()` is idempotent, so the repeat calls this position invites
        // are free.
        syntheticSource?.stop()
        syntheticSource = nil

        guard isCapturing, let e = engine else { return }
        // Remove the tap before stopping — the reverse order can leave a tap attached to a
        // stopped node and trip an exception the next time around.
        if !activeLocalDictation { e.inputNode.removeTap(onBus: 0); e.stop() }
        engine = nil
        pipeline = nil
        isCapturing = false
        activeEngine.stop()
        if !activeLocalDictation && !autoCorrectEnabled, let pending = stableTranscript.finish() {
            lastTranscript = pending
            trace("STABLE TEXT: saved \(pending.count) pending chars for Copy last transcript on stop; not inserted")
        }
        stableTranscript.reset()
        injector.clearBufferedTarget()

        let (rms, frames) = levelBox.read()
        // THIS CAPTURE unprefixed, lifetime in the trailing bracket, and the bracket is
        // labelled because that ambiguity is precisely what made this line lie for as long
        // as it did (see `TraceCounters`). Anything added here must go in one group or the
        // other, never floating between them.
        //
        // `engine=` leads the per-capture group because it is the label on everything after
        // it: partial and final counts from Apple's on-device recogniser and from Gemini
        // Live are not the same measurement, and two captures compared without it are two
        // different experiments read as one. It is the SESSION's engine (`activeEngineKind`
        // is only ever assigned in `beginCapture`'s full start), never the menu's current
        // selection, so a mid-session switch cannot relabel numbers it did not produce.
        //
        // `rms`/`floor`/`thr` sit in the per-capture group beside `frames` because that is
        // what they are: the room as this capture last measured it. `beginCapture` clears
        // the floor on the next full start, so what prints here is never a previous
        // capture's room. They are here so that a session that ended badly can be read
        // against what the speech gate actually saw, without needing a watchdog line to
        // have fired at all.
        //
        // THEY ARE NOT COHERENT WITH EACH OTHER, and the previous version of this comment
        // asserted that they were — "from the same `levelBox.read()` on the same line"
        // (review finding). Only `rms` comes from the read above. `floor` and `thr` are
        // whatever the last `tickStatus` left behind, so they are up to one tick — 1 s —
        // older than the `rms` beside them, and for a capture shorter than one tick they
        // were never measured at all. Recomputing them here would be worse than the
        // staleness: the tracker's coefficients (0.1 fall / 0.005 rise, derived on
        // `noiseFloor`) are calibrated to the 1 Hz tick cadence, so folding an extra
        // out-of-band sample in at teardown would perturb the very time constants the
        // printed numbers exist to let a reader reason about. So: leave them stale by one
        // tick, say so here, and let `levelTrace` print `floor=(never measured)` instead of
        // rendering "never sampled" as `floor=0.00000`.
        trace("capture stopped (\(reason)); engine=\(activeEngineKind.rawValue) "
            + "frames=\(frames) \(levelTrace(rms)) "
            + "partials=\(thisCapture.partialsSeen) coalesced=\(thisCapture.partialsCoalesced) "
            + "finals=\(thisCapture.finalsSeen) injectedChars=\(thisCapture.injectedChars) "
            + "divergencesRepaired=\(thisCapture.divergencesRepaired) "
            + "divergencesRefused=\(thisCapture.divergencesRefused) "
            + "repairsRefusedTooLarge=\(thisCapture.repairsRefusedTooLarge) "
            + "retractionsRefused=\(thisCapture.retractionsRefused) "
            + "freshStarts=\(thisCapture.freshStarts) "
            + "injectFailures=\(thisCapture.injectFailures) "
            + "secureInputRefusals=\(thisCapture.secureInputRefusals) "
            + "finalChunks=\(thisCapture.finalChunks) cloudSent=\(thisCapture.cloudSent) "
            + "cloudApplied=\(thisCapture.cloudApplied) "
            + "cloudUnapplied=\(thisCapture.cloudUnapplied) "
            + "cloudErrors=\(thisCapture.cloudErrors) cloudEmpty=\(thisCapture.cloudEmpty) cloudSkipped=\(thisCapture.cloudSkipped)"
            + " correctionProvider=\(activeCorrectionKind.rawValue) "
            + "correctionModel=\(correctionModelName(for: activeCorrectionKind))"
            + "  [lifetime: sessions=\(sessions) partials=\(lifetime.partialsSeen) "
            + "coalesced=\(lifetime.partialsCoalesced) finals=\(lifetime.finalsSeen) "
            + "injectedChars=\(lifetime.injectedChars) "
            + "divergencesRepaired=\(lifetime.divergencesRepaired) "
            + "divergencesRefused=\(lifetime.divergencesRefused) "
            + "repairsRefusedTooLarge=\(lifetime.repairsRefusedTooLarge) "
            + "retractionsRefused=\(lifetime.retractionsRefused) "
            + "freshStarts=\(lifetime.freshStarts) "
            + "injectFailures=\(lifetime.injectFailures) "
            + "secureInputRefusals=\(lifetime.secureInputRefusals) "
            + "finalChunks=\(lifetime.finalChunks) cloudSent=\(lifetime.cloudSent) "
            + "cloudApplied=\(lifetime.cloudApplied) "
            + "cloudUnapplied=\(lifetime.cloudUnapplied) "
            + "cloudErrors=\(lifetime.cloudErrors) cloudEmpty=\(lifetime.cloudEmpty) "
            + "cloudSkipped=\(lifetime.cloudSkipped) "
            + "correctionProvider=\(correctionKind.rawValue)]")

        // Settle rather than vanish: the HUD keeps the last text (or the reason nothing was
        // typed) so the user can read it, click it, and copy it from the menu.
        if cloudTask == nil { showIdleHUD() }
        refreshMenu()

        // A deliberate stop ends the escalation damper's notion of "this session": the
        // next time the user turns dictation on, one fresh speculative restart is
        // available again. A watchdog-driven teardown leaves `wantsDictation` true and
        // takes the self-heal below instead, so the count survives exactly the restarts
        // it is meant to be counting.
        if !wantsDictation {
            escalationsThisSession = 0
            // BLOCKER-B (review finding): without this reset, a stale count from an
            // earlier wedge poisons the next session's backoff window (up to 48 s) —
            // and since rotation events stamp the liveness clock every ~20 s, a 48 s
            // window can never be satisfied, gating the watchdog and tier 3 off for
            // the entire process lifetime.
            suppressedBouncesSinceRestart = 0
        }

        // Self-healing: if the user still wants dictation (toggle is ON) and capture just
        // stopped for any non-user reason -- the audio watchdog, an engine failure -- the
        // idempotent reconciler starts a fresh session immediately. A deliberate stop
        // (toggle-off, HUD stop) sets wantsDictation=false first, so this is a no-op there.
        // Deferred one runloop turn so the new session never overlaps this teardown.
        Task { @MainActor [weak self] in self?.syncDictation() }
    }

    /// One place for "it did not start, and here is exactly why", so no failure path can be
    /// silent. The HUD gets the user-facing sentence, the trace gets the API detail.
    private func fail(_ userMessage: String, context: String) {
        trace("FAILED — \(context)")
        // Un-strand the toggle: every caller is a begin-path failure, so the user's ON
        // intent did not produce a session. Leaving `wantsDictation` true would make the
        // next tap toggle it OFF — a visible no-op — and require a second tap to retry.
        // With it false, the next tap retries the start immediately. (The one caller that
        // can fire with a live engine — the drain-cancel restart — is separately covered
        // by the recogniser watchdog, which bounces or tears down within ~10 s.)
        wantsDictation = false
        lastOutcome = userMessage
        hud.set(.error(userMessage))
        hud.show()
        refreshMenu()
    }

    // MARK: - The tap callback — runs on AVFAudio's realtime render thread

    /// The entire body of the `installTap` block, deliberately hoisted out of `beginCapture()`.
    ///
    /// AVFAudio calls the tap block from its realtime render thread. `AVAudioNodeTapBlock` is
    /// a plain, non-`@Sendable` function type, so a closure written inline inside a method of
    /// this `@MainActor` class *inherits MainActor isolation*: under Swift 6 the compiler then
    /// emits a dynamic `swift_task_isCurrentExecutor` check at closure entry, and that check
    /// calls `dispatch_assert_queue` — which traps (`EXC_BREAKPOINT`,
    /// `_dispatch_assert_queue_fail`) the first time a buffer arrives, because the audio
    /// thread is not the main queue. That is a guaranteed crash a second or two after
    /// "capture started OK", and it is an isolation bug, not an audio bug.
    ///
    /// Two things together make the check disappear rather than merely pass: the closure is
    /// written `@Sendable` (a `@Sendable` closure cannot inherit actor isolation), and
    /// everything it calls — this function — is explicitly `nonisolated`. `nonisolated` on a
    /// `static` member of a `@MainActor` type is exactly the escape hatch for "this genuinely
    /// runs anywhere", and the signature documents the constraint: a buffer in, `Sendable`
    /// non-isolated collaborators out, no `self`.
    ///
    /// `AudioPipeline` and both engines are `@unchecked Sendable` and carry no actor
    /// isolation of their own, so `append` is safe to call from here — and `LiveRecognizer`
    /// documents this as the intended caller. `DictationEngine` refines `Sendable` for
    /// exactly this reason, so the existential handed in here carries the same guarantee
    /// the concrete type used to. Do NOT reach for `nonisolated(unsafe)` or
    /// `MainActor.assumeIsolated` to get anything else in here; either one reintroduces the
    /// crash above.
    ///
    /// `engine` is ONE reference, resolved once per capture in `beginCapture` and captured
    /// by the tap closure. The realtime thread must never be the place where "which engine
    /// is selected" is answered — no dictionary, no switch, and above all no UserDefaults
    /// read, which takes a lock in another subsystem.
    ///
    /// Keep this boring. Realtime thread rules: no `trace()` (it does file I/O), no UI, no
    /// networking, no lock that could be held long. Hand off, compute, store, return.
    nonisolated static func processTap(_ buffer: AVAudioPCMBuffer,
                                       into box: LevelBox,
                                       pipeline: AudioPipeline,
                                       engine: any DictationEngine) {
        // Recogniser first: it is what the user is watching appear, word by word.
        engine.append(buffer)
        pipeline.append(buffer)

        guard let channels = buffer.floatChannelData, buffer.format.channelCount > 0 else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let samples = channels[0]
        var sumSquares: Float = 0
        var peak: Float = 0
        for i in 0..<frameCount {
            let v = samples[i]
            sumSquares += v * v
            // Peak is folded into the loop that was already touching every sample, so it
            // costs one compare per frame and no second pass, no allocation, no extra lock
            // take — which is what "keep this boring" above means in practice. `magnitude`
            // on Float is plain `abs`. It has to be computed here because here is the only
            // place the samples exist; everything downstream sees only what this stores.
            if v.magnitude > peak { peak = v.magnitude }
        }
        let rms = (sumSquares / Float(frameCount)).squareRoot()
        box.store(rms: rms, peak: peak, frameCount: frameCount)
    }

    // MARK: - Main-thread pump

    /// 30 Hz. Drains the recogniser event queue in order and feeds the HUD meter. This is the
    /// only place `LiveRecognizer`'s output reaches the main actor.
    @objc private func tickUI() {
        let drained = events.drain()
        let batch = drained.events
        if drained.droppedPartials > 0 {
            trace("EVENTS: dropped \(drained.droppedPartials) superseded partial(s) — main thread fell behind")
        }
        if drained.droppedCritical > 0 {
            // The precondition for whole-utterance deletion, named at the `.listening`
            // reset in `handleRecognizerState`: a lost boundary event leaves the ledger
            // describing an utterance that is already over. It used to happen silently,
            // counted in with ordinary partial churn. This line is the whole point of
            // splitting the counters — if it ever appears, the divergence numbers from
            // that capture cannot be trusted and the trace now says so.
            trace("EVENT BOX: dropped \(drained.droppedCritical) critical events (state/final) — "
                + "main thread wedged; ledger integrity not guaranteed this utterance")
        }
        if drained.coalescedAtPost > 0 {
            // Same event as the drain-side skip below — a partial superseded before it
            // could ever be typed — so it belongs in the same counter rather than a
            // second one nobody would think to read.
            lifetime.partialsCoalesced += drained.coalescedAtPost
            thisCapture.partialsCoalesced += drained.coalescedAtPost
        }
        // Coalesce revision churn: each partial carries the WHOLE utterance so far, so a
        // partial immediately followed by another partial in the same drained batch is
        // already superseded — typing it would only be undone by the very next event on
        // this same tick. Skipping it keeps one injector round-trip per ~33 ms tick.
        // Only consecutive partials collapse; a final (or state change) between partials
        // is never skipped and still sees events in their original order.
        //
        // BELT AND BRACES SINCE THE BOX LEARNED TO COALESCE AT POST TIME: `post` never
        // leaves two partials adjacent, so this loop now almost never finds a pair. It
        // stays because it is cheap (one enum test per event), because it is the statement
        // of the invariant at the point where the invariant matters — the typing loop —
        // and because it keeps working unchanged if the box's policy is ever revised.
        for (index, event) in batch.enumerated() {
            if case .partial = event, index + 1 < batch.count,
               case .partial = batch[index + 1] {
                lifetime.partialsCoalesced += 1; thisCapture.partialsCoalesced += 1
                continue
            }
            switch event {
            case .partial(let text):
                lastRecognizerEventAt = Date()
                recognizerStalledTicks = 0   // real output — the recogniser is alive
                loudTicksSinceRecognizerEvent = 0
                lastRealPartialAt = Date()
                lastRealOutputAt = Date()
                sessionSawPartial = true     // evidence of real recognition work: arms the escalation damper
                suppressedBouncesSinceRestart = 0   // recognition demonstrably works: stand tier 3 down
                handlePartial(text)
            case .final(let text):
                lastRecognizerEventAt = Date()
                recognizerStalledTicks = 0
                loudTicksSinceRecognizerEvent = 0
                lastRealOutputAt = Date()
                handleFinal(text)
            case .state(let state):
                // THE STAMP, AND NOTHING ELSE. `loudTicksSinceRecognizerEvent = 0` used to
                // be on the next line, and it is what cost the 14:26:19-14:41:25 capture its
                // last twelve minutes. That counter means "loud ticks since the recogniser
                // last produced REAL OUTPUT", and a `.state` is not output: the 20 s request
                // rotation emits one every cycle — 14:26:59, :19, :39, 14:28:00, :20, :40,
                // 14:29:00 and :20 in that trace, every one of them a reset — so under
                // continuous speech the ladder had to re-arm from zero inside each 20 s
                // window while `noiseFloorRise` lifted the floor underneath it. It never
                // reached its arming value of 3, the watchdog fired ZERO times, and the app
                // held a hot microphone and typed nothing for twelve minutes.
                //
                // PROOF this was the binding gate rather than one of several: after the
                // recogniser gave up at 14:29:20 no event of any kind arrived again, so the
                // `> 6 s` debounce was satisfied on all ~725 subsequent ticks and the ladder
                // STILL never fired. `loudTicks >= 3` was the only gate left standing.
                //
                // The stamp stays. It debounces a session that has only just started, which
                // is a claim about elapsed time and not about output, and it is what stops
                // the watchdog bouncing a brand-new healthy request on its first tick. The
                // counter is still cleared on every session boundary — `beginCapture` does
                // it on both the full start and the drain-cancel resume — so no stale
                // evidence crosses from one capture into the next.
                lastRecognizerEventAt = Date()
                handleRecognizerState(state)
            }
        }

        guard isCapturing else { return }
        let (rms, _) = levelBox.read()
        hud.setLevel(rms)
    }

    /// 1 Hz. Cheap health polling for the things that can change without telling us:
    /// Accessibility being granted while we run, the tap dying, the mic grant flipping.
    @objc private func tickStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != micStatus {
            trace("authorizationStatus(.audio) changed: \(statusName(micStatus)) -> \(statusName(status))")
            micStatus = status
        }
        refreshMenu()
        // Keep the idle HUD's body honest as permissions change under us.
        if !isCapturing && cloudTask == nil && finalQueue.pendingCaptureCount == 0 && injectionBlockedReason == nil && !utteranceDiverged {
            hud.set(.idle(idleBody()))
        }

        // Audio-flow watchdog: while capturing, the frame counter must move every tick.
        // Two consecutive stalled ticks (~2 s) = the engine/tap is dead. Restart the whole
        // capture session; `wantsDictation` is still true, so `syncDictation` at the end of
        // `finishCapture` brings dictation straight back and the user just keeps talking.
        if isCapturing, engine != nil {
            let (rms, frames) = levelBox.read()
            if frames == watchdogLastFrames {
                watchdogStalledTicks += 1
                if watchdogStalledTicks >= 2 {
                    watchdogStalledTicks = 0
                    trace("AUDIO WATCHDOG: no frames for ~2 s (stuck at \(frames)); restarting capture")
                    endCapture(reason: "audio watchdog: engine stopped delivering")
                }
            } else {
                watchdogStalledTicks = 0
            }
            watchdogLastFrames = frames

            // Recogniser-liveness. Measured failure (10:57:16): the ~60 s rotation stood
            // up a new request that emitted `.listening` and then NOTHING -- no partial,
            // no error -- while the engine kept delivering (the pipeline was still
            // cutting chunks half a minute later). The first version of this watchdog
            // required speech-level RMS at the moment of the check, which never fired:
            // when typing stops, the USER stops talking to look at the screen, so the
            // failure suppressed its own detector.
            //
            // Now: silence-based only. No recogniser event of ANY kind for >10 s while
            // capturing means either a wedged request or a >10 s deliberate pause; in
            // both cases quietly bouncing JUST the recogniser (engine, pipeline, ledger,
            // typed state all untouched) is invisible if it was healthy and a rescue if
            // it was not.
            //
            // The loud-tick gate itself is no longer a fixed literal. Track the room's
            // noise floor asymmetrically — fast down, slow up — and gate on a ratio over
            // it, so steady noise is tracked BY the floor and can never tick while speech,
            // 10-30 dB above it, always does. See `noiseFloor` for the coefficients, both
            // worst cases, and the 16:09-16:15 evidence that made a self-calibrating gate
            // non-optional. Tracked HERE and only here, because the tap that produces `rms`
            // runs only while capturing; the `else` branch at the bottom of this method
            // deliberately leaves the value alone so `finishCapture` can still print the
            // room as it was at teardown.
            //
            // A NON-FINITE SAMPLE IS REJECTED BEFORE IT REACHES THE FLOOR, and that branch
            // is verified arithmetic rather than defensive decoration (review finding).
            // Checked in Swift: `Float.infinity + 0.1 * (0.003 - .infinity)` is NaN after
            // ONE fall step, and a NaN floor is permanent — `rms < noiseFloor` is false for
            // every finite sample, so the else-branch below folds NaN into NaN forever, and
            // `max(Float(0.0025), Float.nan * 3.0)` returns 0.0025 because `y >= x` is false
            // for NaN. The gate would silently revert to the exact broken constant this
            // tracker replaced, for the rest of the capture: only `beginCapture`'s full
            // start clears it. The source is a virtual/aggregate device handing the tap
            // garbage; a 0/0 of our own making is not possible, `processTap` already guards
            // `frameCount > 0`. Logged, not swallowed — the line carries `levelTrace`, so
            // the poisoned value prints as `rms=nan` — but once per capture, because a 1 Hz
            // flood in the trace is its own defect.
            if !rms.isFinite {
                if !nonFiniteRMSTracedThisCapture {
                    nonFiniteRMSTracedThisCapture = true
                    trace("NOISE FLOOR: non-finite RMS sample from the tap (\(levelTrace(rms))); "
                        + "rejected from the floor and the speech gate — a virtual or "
                        + "aggregate input device is delivering garbage. Logged once per capture.")
                }
            } else if !noiseFloorSeeded {
                // The bound is `absoluteQuietFloor`, not `> 0`: any positive value would
                // let a ~3e-4 route-switch artifact seed the floor and pin the threshold to
                // the old broken constant for 60 ticks. See `noiseFloorSeeded`.
                if rms >= Self.absoluteQuietFloor {
                    noiseFloor = rms
                    noiseFloorSeeded = true
                }
            } else if rms < noiseFloor {
                noiseFloor += Self.noiseFloorFall * (rms - noiseFloor)
            } else {
                noiseFloor += Self.noiseFloorRise * (rms - noiseFloor)
            }
            // `isFinite` again rather than leaning on the chain above: `nan > thr` is false
            // and harmless, but `+inf > thr` is TRUE, and three of those would arm the whole
            // ladder off samples that never described a room.
            // Drained EVERY tick, not only on a LEVEL line, because the gate below needs
            // THIS tick's peak: a value left to accumulate across five ticks would keep the
            // gate armed for five seconds off a single door slam. `levelLinePeak` carries
            // the running maximum instead, so the LEVEL line still describes its full
            // window. One extra lock take per second, on the main actor, never on the tap.
            let tickPeak = levelBox.drainPeak()
            if tickPeak > levelLinePeak { levelLinePeak = tickPeak }
            // ── WHY THE GATE READS PEAK AS WELL AS RMS ────────────────────────────────
            // `noiseFloor` documents a known blind spot and closes with "do not add a
            // compensating gate on a hunch — get the numbers out of the trace first". The
            // numbers are now in the trace, and they say the blind spot is real and is the
            // rule rather than the exception for this speaker. Capture 14:36, LEVEL lines,
            // while Thai was being dictated continuously:
            //
            //   rms=0.02239 floor=0.01650 thr=0.04951 peak=0.16546 loudTicksSinceEvent=0
            //   rms=0.01623 floor=0.00425 thr=0.01276 peak=0.17419 loudTicksSinceEvent=1
            //   rms=0.00357 floor=0.00425 thr=0.01276 peak=0.12046 loudTicksSinceEvent=0
            //   rms=0.00416 floor=0.00416 thr=0.01249 peak=0.10116 loudTicksSinceEvent=0
            //
            // `rms` here is ONE ~10 ms buffer — whatever the tap happened to store last —
            // and Thai speech is peaky enough that the sample keeps landing in an
            // inter-word gap, reading 0.0036 against a 0.0125 threshold. The ladder needs
            // three ticks and reached zero or one. `peak`, held across the whole second,
            // never drops below 0.10: an 8x margin on a signal that does not collapse.
            //
            // So peak is ADDITIVE, never a replacement. The rms path is left exactly as it
            // was — this can only make the watchdog easier to arm, never harder, so no
            // previously-working calibration is put at risk — and the failure mode of the
            // new path is a spurious tier-1 bounce, which this file already argues costs
            // nothing and which the bounce backoff and the tier-2 damper both bound.
            if (rms.isFinite && rms > speechThreshold)
                || (tickPeak.isFinite && tickPeak > peakSpeechThreshold) {
                loudTicksSinceRecognizerEvent += 1
            }
            // THE PERIODIC LEVEL LINE — unconditional, ~5 s, for the whole of every
            // capture. This method runs at 1 Hz, so the tick counter IS elapsed seconds;
            // see `levelLineTicks` for why a measurement that prints only once something
            // has already gone wrong cannot describe how it got there.
            //
            // Placed HERE on purpose: after the floor update and after the loud-tick
            // increment, but before the strike branch below. So the line reports the exact
            // numbers the gate used on this tick — including the loud-tick count that the
            // strike branch is about to zero, which is the one number that separates
            // "ambient armed the ladder" from "the user talked into a dead recogniser".
            //
            // Cheap by construction, and nowhere near the realtime audio thread: it reuses
            // the `(rms, frames)` already read at the top of this block, takes the LevelBox
            // lock exactly once more (`drainPeak`), and formats one string per five ticks.
            // The tap still only stores; nothing was added to its critical path beyond the
            // one compare per frame that `processTap` folds into its existing loop.
            levelLineTicks += 1
            if levelLineTicks >= 5 {
                levelLineTicks = 0
                // The window maximum accumulated by the per-tick drain above, NOT a drain of
                // its own. `LevelBox.drainPeak` consumes and resets, so a second caller here
                // would silently shorten one of the two windows; the gate needs a per-tick
                // value and this line needs a per-window one, so the split happens on this
                // side of the lock instead.
                let peak = levelLinePeak
                levelLinePeak = 0
                // `&-` deliberately. `frames` and this baseline are zeroed together in
                // `beginCapture`, so it cannot legitimately underflow; if a future edit
                // ever breaks that pairing, a visibly absurd wrapped number in the trace is
                // a better outcome than trapping in the middle of a dictation session.
                let framesDelta = frames &- levelLineLastFrames
                levelLineLastFrames = frames
                // 240000 frames per line is exactly 5 s at 48 kHz, so the delta reads as a
                // pass/fail at a glance in a way a running total does not. This is the
                // number that proved NEGATIVE in the 14:26:19-14:41:25 capture — total
                // frames matched wall clock to the sample, so the audio path was healthy
                // and the recogniser was the thing that had died. That conclusion took a
                // whole post-mortem and one lucky end-of-capture line; it should take one
                // glance at any five-second window.
                //
                // `peak` beside `rms` is the other half of that: RMS alone cannot tell a
                // wedged Speech service from an input that went attenuated, and a peak held
                // across the window can (see `LevelBox.peak`). `sinceRealOutput` is the
                // recogniser's side of the same question — long and climbing while frames
                // keep arriving IS the failure signature, stated in one line.
                let outputAge = lastRealOutputAt == .distantPast
                    ? "sinceRealOutput=(none this launch)"
                    : String(format: "sinceRealOutput=%.0f s",
                             Date().timeIntervalSince(lastRealOutputAt))
                trace("LEVEL: \(levelTrace(rms)) "
                    + String(format: "peak5s=%.5f peakThr=%.5f ",
                             Double(peak), Double(peakSpeechThreshold))
                    + "loudTicksSinceEvent=\(loudTicksSinceRecognizerEvent) "
                    + "framesDelta=\(framesDelta) \(outputAge)")
            }
            let heardSpeechSinceSilence = loudTicksSinceRecognizerEvent >= 3
            // B2 fix (review finding): suppressed bounces every ~7 s for 70 s got this
            // process THROTTLED by the Speech service (kAFAssistantErrorDomain 1107 in the
            // 15:26 trace) — "an ambient bounce costs nothing" was measured false. Once
            // bounces are being suppressed (the damper says restarts are pointless), each
            // further attempt doubles the required silence window: 6 -> 12 -> 24 -> 48 s
            // (capped). Tier 3 fires on the 2nd suppressed bounce regardless, so real
            // systemic wedges still resolve fast; only the hopeless churn slows down.
            //
            // THE CEILING IS 12 s WHILE TIER 3 IS ONLY OBSERVING, and it has to be, because
            // above the rotation cadence this whole ladder switches itself off (review
            // finding). `suppressedBouncesSinceRestart` resets in exactly three places — a
            // real partial, a deliberate stop, tier 3's own success — and with the toggle
            // OFF none of them happen while a wedge persists, so the count ratchets
            // monotonically and pins the backoff at 48 s. Meanwhile `LiveRecognizer` keeps
            // stamping `lastRecognizerEventAt` right through a total wedge: `emitState` is
            // local and needs no answer from the Speech service, so a rotation seam stamps
            // even when the Speech service has stopped saying anything at all.
            //
            // THE NUMBERS HERE USED TO READ "+26/+28", from the 20 s rotation plus a 6 s
            // overlap fallback and a 2 s promote. Both of those mechanisms are gone with
            // the overlapped rotation. Under flush-then-replay the seam is effectively ONE
            // event: the flushed FINAL and the successor's `.listening` land together at
            // +20 s (`sessionRotationSeconds`), stretching to ~+22 s only in the case where
            // the flush yields neither final nor error and `finalFlushTimeoutSeconds`' 2 s
            // net restarts in their place. So the largest event-free window the guard below
            // can EVER observe is ~20 s, ~22 s worst case.
            //
            // THE 12 s CONCLUSION SURVIVES THE RENUMBERING, with more margin than it had.
            // The direction is what matters: the guard fires when the observed gap EXCEEDS
            // the ceiling, so the ceiling must sit BELOW the largest event-free window.
            // 12 s against ~20 s clears that more comfortably than 12 s against the old
            // settled 18 s did. The ~22 s figure is the DEGENERATE seam only — a flush that
            // answers with neither a final nor an error — so the steady-state cadence any
            // ceiling has to be chosen against is 20 s, and the paragraph further down
            // ("any ceiling at or above 20 s … can never produce") stands exactly as
            // written. The extra 2 s widens the margin under a 12 s ceiling; it does not
            // rehabilitate a 20 s one.
            //
            // At 48 s the guard is unsatisfiable forever — and it takes tiers 1 and 2 down
            // with it, so turning tier 3 off also disabled the cheap recovery that works
            // and the evidence gathering the toggle exists for. Measured, 30 runs x 4 environments: 1.7-2.0
            // `WOULD FIRE` lines and then total silence for the remaining ~1050 s.
            //
            // Simulated against that stamping model, 1200 s, user quiet 60 s in every 300 s
            // (one missed strike is all it takes to settle the schedule into its 18 s
            // cadence): ceilings of 18/20/24/26/48 s all go permanently silent — last ladder
            // line at 306/307/297/122/122 s. 16 s survives (60 bounces), 12 s survives (77),
            // 6 s survives (139). 12 s is chosen because it is the highest EXISTING rung of
            // the 6/12/24/48 ladder that clears the worst-case event-free window with
            // margin — 18 s under the stamping model that simulation was run against, ~20 s
            // under flush rotation, which only widens the margin — and because rung 6 is
            // the one that produced the ~7 s bounce cadence that got this process
            // throttled: capping there would reinstate the defect the backoff exists to
            // prevent. At 12 s the observed cadence is ~13 s minimum, ~15 s mean — one rung
            // slower than the measured-throttling cadence, permanently.
            //
            // Cap the BACKOFF, not the COUNTER. The counter is tier 3's arming evidence and
            // it is printed verbatim in the WOULD FIRE line; saturating it would make that
            // line under-report how long the wedge had persisted, which is the very defect
            // the `loudTicks` capture below exists to fix. A derived, unprinted quantity is
            // the safe thing to clamp.
            //
            // The paragraph above used to end "the ON path keeps 48 s exactly … if the
            // toggle is ever promoted to default-ON, this ceiling has to come with it."
            // The toggle HAS now been promoted to default-ON (see `daemonRestartEnabled`),
            // so the ceiling comes with it, exactly as that sentence required.
            //
            // 48 s was never merely aggressive — at this cadence it is UNSATISFIABLE, which
            // is worse. The window is measured from `lastRecognizerEventAt`, and the 20 s
            // request rotation emits a `.state` that re-stamps it on every cycle
            // (`sessionRotationSeconds`). Any ceiling at or above 20 s therefore describes a
            // silence that a rotating recogniser can never produce, and the ladder is gated
            // off entirely — precisely in the half-dead case it exists for, where `.state`
            // still flows but no partial ever does. Under the old default the 12 s rung sat
            // safely inside the cadence and tiers 1 and 2 fired; flipping the toggle without
            // this line would have silently disabled the watchdog this same change set was
            // repairing.
            //
            // So the ceiling is now the toggle-independent 12 s. Tier 3 is unaffected: it is
            // armed by `suppressedBouncesSinceRestart` and rate-limited by its own 120 s
            // window, neither of which is derived from this value.
            let backoffCeiling: Double = 12
            let bounceBackoff: Double = min(backoffCeiling,
                                            6 * pow(2, Double(min(suppressedBouncesSinceRestart, 3))))
            if !activeLocalDictation, heardSpeechSinceSilence,
               Date().timeIntervalSince(lastRecognizerEventAt) > bounceBackoff {
                // ── ENGINE GATE: THE LADDER BELOW IS APPLE'S, ALL THREE RUNGS ──────────
                // Tier 3 `kill -9`s `localspeechrecognition.xpc`, a macOS system service
                // that a WebSocket to Google does not touch — so against a Gemini stall it
                // is not merely useless, it is an unattended kill of an unrelated daemon
                // that may be transcribing for some other app. Tiers 1 and 2 are no better
                // founded: "bounce the request, then rebuild the engine" is the recovery
                // measured against SFSpeech wedges (14:02), and `LiveRecognizer` is what
                // guarantees the `persistent recognition failure` contract the whole
                // escalation is written against. None of that is knowledge about a socket.
                //
                // So the ladder stands down entirely, and the state it would have touched
                // is left alone — no strike, no `recognizerStalledTicks`, no
                // `suppressedBouncesSinceRestart`, so nothing this session accumulates can
                // arm tier 3 for the NEXT one. What IS reset is the same debounce a strike
                // would have consumed, which stops this branch from re-entering every tick.
                //
                // A Gemini stall is not left undetected: that engine reports it through its
                // own `.unavailable`, which arrives via the same event box and is handled
                // in `handleRecognizerState` like any other.
                guard activeEngineKind == .apple else {
                    // Read BEFORE the reset two lines down, for the reason the strike
                    // branch below states at length: the accumulated loud-tick count is
                    // the number that separates "ambient armed it" from "the user talked
                    // into a dead engine", and the reset destroys it.
                    let levels = levelTrace(rms, loudTicks: loudTicksSinceRecognizerEvent)
                    lastRecognizerEventAt = Date()
                    loudTicksSinceRecognizerEvent = 0
                    if Date().timeIntervalSince(lastEngineStandDownTracedAt) > 120 {
                        lastEngineStandDownTracedAt = Date()
                        trace("RECOGNIZER WATCHDOG: standing down — active engine is "
                            + "\(activeEngineKind.rawValue), and tiers 1-3 (bounce, capture "
                            + "restart, pkill localspeechrecognition) are specific to "
                            + "Apple's on-device service. \(levels) A stall on this engine "
                            + "surfaces as its own .unavailable state. Rate-limited to one "
                            + "line per 120 s.")
                    }
                    return
                }
                // Every trace this ladder emits carries the three numbers the gate actually
                // used. Non-negotiable: the previous round climbed all three tiers and
                // killed a system service twice with nothing anywhere recording what had
                // been measured, which made the whole escalation unfalsifiable after the
                // fact. Anything added to this ladder that traces must carry it too.
                //
                // FOUR numbers now, and the fourth is the one that was missing (review
                // finding). `rms` is the room on THIS tick; the strike was armed by up to
                // 26 s of accumulated speech-level ticks, and the reset two lines down used
                // to destroy that count before ANY of the nine `RECOGNIZER WATCHDOG` lines
                // below could print it. It is the single number that would have made the
                // 16:09-16:15 field failure diagnosable: it separates "three ambient ticks
                // armed the ladder" from "the user talked into a dead recogniser for twenty
                // seconds". Read it here, before the reset, and thread it through `levels`
                // so all nine lines carry it without any of them having to remember to.
                //
                // The label says "accumulated" for a reason: on most firing ticks the
                // printed `rms` is BELOW `thr`. That is correct — the counter deliberately
                // persists through the silence that follows, which is the whole reason it
                // beats an instantaneous RMS check (see `loudTicksSinceRecognizerEvent`) —
                // but on the page it reads as a self-contradiction, and a trace that has to
                // be explained by someone who already knows the answer is not a trace.
                let levels = levelTrace(rms, loudTicks: loudTicksSinceRecognizerEvent)
                lastRecognizerEventAt = Date()   // debounce: one action per silent window
                loudTicksSinceRecognizerEvent = 0
                recognizerStalledTicks &+= 1
                // ESCALATION LADDER — measured 14:02: ~35 s of continuous no-pause speech
                // wedged SFSpeech so hard that recogniser-only bounces came up silent
                // while the engine kept delivering. A bounce recreates only the
                // recognition request; a full capture restart (endCapture + self-heal)
                // also rebuilds the audio engine and its session, which is what actually
                // revived the identical wedge every time it was observed. Ladder: 6 s
                // silence -> one cheap bounce; 6 more seconds of silence -> full restart.
                // Worst-case gap ~12 s, and the 20 s request rotation upstream should
                // prevent most wedges from forming at all. The counter resets on any real
                // partial/final, so escalation needs CONSECUTIVE silent strikes only.
                //
                // ESCALATION DAMPER — measured 14:23: this room's ambient RMS sits
                // at/above the 0.0025 loud-tick threshold (and genuine quiet speech on
                // this mic measures below 0.01, so raising it is not an option). With the
                // toggle on and the user simply quiet, ambient ticks alone climbed the
                // whole ladder -- bounce at 6 s, full restart at 12 s, then again,
                // endlessly -- and fal confirmed those churned windows contained no
                // speech at all (0-char transcripts). So the FULL restart additionally
                // needs evidence of real recognition work: a session that has produced a
                // partial may always escalate; a session that never has gets at most one
                // speculative restart (`escalationsThisSession`, which survives the
                // self-heal restart), after which strikes keep bouncing -- cheap,
                // invisible -- until a real partial re-arms the ladder. Bounces stay
                // gated by loud ticks alone on purpose: an ambient bounce costs nothing.
                // A repeating suppressed-bounce loop is ALSO the signature of a
                // system-wide daemon wedge, which TIER 3 below catches.
                if recognizerStalledTicks >= 2, sessionSawPartial || escalationsThisSession == 0 {
                    recognizerStalledTicks = 0
                    escalationsThisSession += 1
                    trace("RECOGNIZER WATCHDOG: bounce did not revive it; escalating to full capture restart (\(levels))")
                    endCapture(reason: "recogniser watchdog: escalation after failed bounces")
                } else {
                    if recognizerStalledTicks >= 2 {
                        suppressedBouncesSinceRestart += 1
                        // TIER 3 — restart macOS's own speech daemon. Measured evidence
                        // chain: heavy Thai-English code-switching wedges the system's
                        // `localspeechrecognition` XPC service (Speech.framework) itself,
                        // not just our session — once wedged, EVERY new SFSpeech session
                        // in EVERY process produces zero partials while audio keeps
                        // flowing, so tiers 1 and 2 (bounce, full capture restart)
                        // cannot help by construction; the trace shows exactly the
                        // suppressed-bounce loop this branch handles. `kill -9` of the
                        // service was verified restorative live: before the kill, an
                        // endless "escalation suppressed ... bouncing instead" loop;
                        // after it, partials=10 on the same English-mixed phrase.
                        // launchd respawns the service on demand, so the kill is safe,
                        // and it runs as this user, so a plain same-user signal needs no
                        // entitlement (this app is not sandboxed). Trigger: the ladder
                        // has already spent its bounce and its one speculative full
                        // restart, and two MORE suppressed bounces have fired since —
                        // roughly 30 s into a systemic wedge — rate-limited to one
                        // daemon kill per two minutes.
                        //
                        // COUNTER-EVIDENCE, measured 16:09-16:15 on 2026-08-26 and kept
                        // beside the observation above rather than replacing it, because
                        // both happened. The ladder — armed by ambient noise, before
                        // `noiseFloor` existed — reached this tier and fired `pkill` twice.
                        // The FIRST kill was followed immediately by
                        // `kAFAssistantErrorDomain error 1107` and 3.5 more minutes of
                        // failure: it restored nothing and cost self-inflicted throttling.
                        // The second is ambiguous. One restorative case, one clear failure,
                        // one measured cost is not a mandate to `kill -9` a system service
                        // unattended, so the trigger below is now opt-in and default OFF;
                        // the detector is unchanged and still logs every time it would have
                        // fired. Re-litigate that default from the WOULD-FIRE lines, not
                        // from this paragraph.
                        //
                        // BLOCKER-A gate: recognition must have PROVABLY worked in the
                        // last 5 minutes. Before `noiseFloor` landed, ambient noise in
                        // this room could climb every other rung of this ladder; it can
                        // never have produced a partial, so it could never reach the kill.
                        // Kept as a second, independent guard even now that the loud-tick
                        // gate calibrates itself — this tier signals a SYSTEM service, and
                        // one gate is not enough for that.
                        let tier3Armed = suppressedBouncesSinceRestart >= 2
                            && Date().timeIntervalSince(lastDaemonKillAt) > 120
                            && Date().timeIntervalSince(lastRealPartialAt) < 300
                        // DETECTOR ON, TRIGGER OPT-IN (see `daemonRestartEnabled`). With
                        // the toggle off this branch changes no ladder state: it does NOT
                        // stamp `lastDaemonKillAt`, does NOT reset
                        // `suppressedBouncesSinceRestart` and does NOT touch the HUD,
                        // because none of that happened. It logs one rich line and falls
                        // through to the ordinary suppressed bounce below. The one thing it
                        // does write, `lastTier3WouldFireLoggedAt`, is the log's own rate
                        // limiter and nothing reads it but the `trace` guard below — kept
                        // separate from `lastDaemonKillAt` precisely so that this promise
                        // stays literally true.
                        //
                        // THE LINE IS RATE-LIMITED; THE DETECTION IS NOT. `tier3Armed` is
                        // evaluated on every strike and the fall-through to the ordinary
                        // suppressed bounce is unconditional — only the `trace` is throttled,
                        // and only to the 120 s the kill itself is limited to, through a
                        // separate stamp (see `lastTier3WouldFireLoggedAt`). Without it the
                        // 12 s backoff ceiling above prints this line on every armed strike
                        // — every ~13 s. Simulated over 1200 s: 73 near-identical lines when
                        // intermittent partials keep the detector armed throughout, 16-20 in
                        // a total wedge (where `lastRealPartialAt` disarms it at 300 s
                        // anyway). They would bury the tier-1 and tier-2 lines they are
                        // meant to be read beside. Throttled, the line means "tier 3 would
                        // have fired in this two-minute window", which is one line per
                        // counterfactual kill — and the DETECTIONS behind it are unthinned,
                        // still 73 and 16-20, because only the `trace` is gated.
                        //
                        // EXPECT IT TO REPEAT, and do not read the repetition as a loop bug:
                        // precisely because no LADDER state is stamped or reset, both
                        // counter-based conditions stay satisfied, so it re-prints every
                        // 120 s until
                        // `lastRealPartialAt` ages past 300 s and disarms it. That is what a
                        // detector with no trigger looks like. `lastServiceError` is carried
                        // for the same reason and read the same way: to be judged by a human
                        // later, not branched on now — see `lastServiceErrorDescription()`.
                        if tier3Armed, !daemonRestartEnabled,
                           Date().timeIntervalSince(lastTier3WouldFireLoggedAt) > 120 {
                            lastTier3WouldFireLoggedAt = Date()
                            trace("RECOGNIZER WATCHDOG TIER 3 WOULD FIRE (disabled): \(levels) "
                                + "suppressedBounces=\(suppressedBouncesSinceRestart) "
                                + String(format: "sinceLastRealPartial=%.0f s ",
                                         Date().timeIntervalSince(lastRealPartialAt))
                                + "lastServiceError=[\(lastServiceErrorDescription())]")
                        }
                        if tier3Armed, daemonRestartEnabled {
                            trace("RECOGNIZER WATCHDOG TIER 3: on-device speech service appears wedged system-wide; restarting localspeechrecognition (\(levels))")
                            let pkill = Process()
                            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                            pkill.arguments = ["-9", "-f", "localspeechrecognition.xpc"]
                            do {
                                try pkill.run()
                                // Synchronous wait is fine HERE and only here: pkill
                                // exits in milliseconds, we are on the main actor inside
                                // a 1 Hz timer tick, and dictation has already been dead
                                // for ~30 s — a one-off ~10 ms block is invisible next
                                // to that.
                                pkill.waitUntilExit()
                                guard pkill.terminationStatus == 0 else {
                                    // Nothing matched: the daemon was not running, so
                                    // "we restarted it" would be false and stamping the
                                    // rate limiter would burn the 120 s budget on a
                                    // no-op. Treat as an ordinary suppressed bounce.
                                    trace("RECOGNIZER WATCHDOG TIER 3: pkill matched nothing (status \(pkill.terminationStatus)); falling through to a suppressed bounce (\(levels))")
                                    recognizer.stop()
                                    do { try recognizer.start() } catch {
                                        endCapture(reason: "recogniser watchdog: restart failed")
                                    }
                                    return
                                }
                                trace("RECOGNIZER WATCHDOG TIER 3: pkill killed the service; launchd respawns it on demand (\(levels))")
                                lastDaemonKillAt = Date()
                                // Re-arm the WHOLE ladder: the next wedge is a fresh
                                // problem against a fresh daemon and earns its own bounce
                                // and speculative restart. (`recognizerStalledTicks` too,
                                // exactly as the tier-2 branch above does, so the healed
                                // session climbs from a cheap bounce instead of jumping
                                // straight back to a full restart.)
                                suppressedBouncesSinceRestart = 0
                                escalationsThisSession = 0
                                recognizerStalledTicks = 0
                                // The ONE watchdog action worth surfacing: the user has
                                // been talking into a dead system for ~30 s and deserves
                                // to know why text stopped and that it is coming back.
                                hud.set(.error("On-device speech service was stuck — restarted it, resuming dictation"))
                                endCapture(reason: "tier 3: speech service restarted")
                                // Capture is tearing down; the self-heal in
                                // `finishCapture` brings it back and binds a fresh
                                // recogniser to the fresh daemon. Bouncing the
                                // already-stopped recogniser below would fight the drain.
                                return
                            } catch {
                                // /usr/bin/pkill failing to LAUNCH is not a thing on
                                // macOS, but if it ever happens: note it and fall through
                                // to the normal suppressed bounce below.
                                trace("RECOGNIZER WATCHDOG TIER 3: pkill failed to launch (\(error.localizedDescription)); falling back to a suppressed bounce (\(levels))")
                            }
                        }
                        trace("RECOGNIZER WATCHDOG: escalation suppressed (no partials in THIS capture session, already restarted once); bouncing instead (\(levels))")
                    } else {
                        trace("RECOGNIZER WATCHDOG: speech heard but no recogniser events for >6 s; bouncing the recogniser (bounce #\(recognizerStalledTicks)) (\(levels))")
                    }
                    recognizer.stop()
                    do { try recognizer.start() } catch {
                        trace("RECOGNIZER WATCHDOG: restart threw — \(describeRecognizerError(error)); falling back to full capture restart (\(levels))")
                        endCapture(reason: "recogniser watchdog: restart failed")
                    }
                }
            }
        } else {
            watchdogStalledTicks = 0
            recognizerStalledTicks = 0
        }
    }

    // MARK: - Live text -> keystrokes

    /// Collapse every RUN of line breaks into exactly one space; return the string
    /// untouched when there is nothing to collapse.
    ///
    /// WHY THE LEDGER NEEDS THIS. `injectedForUtterance` is a claim about what is in the
    /// user's document, and the whole repair path is prefix arithmetic over that claim. A
    /// single-line field — a search box, a one-line `NSTextField`, most web inputs —
    /// SWALLOWS a newline it is handed: the app types "a\nb", the field ends up holding
    /// "ab", and from that instant every common-prefix computation is done against a
    /// document one character shorter than the ledger says. Nothing recovers from it
    /// before the next `.listening`, and every repair in between deletes the wrong range.
    /// Substituting a space costs one character of fidelity and removes the entire class.
    ///
    /// A RUN BECOMES ONE SPACE, not one space per scalar: "\r\n" is two scalars and a
    /// single line break, so a per-scalar substitution would insert two spaces and produce
    /// the same off-by-one desync in the opposite direction. `CharacterSet.newlines` is
    /// the membership test because it already names all six (\n, \r, \r\n, U+0085,
    /// U+2028, U+2029) — do not hand-roll that list.
    ///
    /// THIS DELIBERATELY DOES NOT LIVE INSIDE `TextInjector`. That type's contract is to
    /// type exactly what its caller asked for: `replaceRecentText` later searches the
    /// document for text this app claims to have written, so an injector that silently
    /// rewrote its argument would send that search hunting for a string that was never
    /// typed. Normalising is a decision about the LEDGER, so it belongs to the ledger's
    /// owner — here, applied once at the point the text enters the app, before the
    /// document, the ledger, the HUD and the cloud-search span can disagree about it.
    ///
    /// This runs on every partial, so the common path must not allocate: the membership
    /// scan is over `unicodeScalars` and hands back the original string.
    private func normalizeForInjection(_ s: String, kind: String) -> String {
        guard s.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            return s
        }
        var out = ""
        out.reserveCapacity(s.count)
        var replaced = 0
        var inRun = false
        for scalar in s.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                replaced += 1
                if !inRun {
                    out.unicodeScalars.append(" ")
                    inRun = true
                }
            } else {
                out.unicodeScalars.append(scalar)
                inRun = false
            }
        }
        // Counts and a source label only — the trace file is world-readable and never sees
        // transcript text. Traced ONLY when something changed, so a silent trace is itself
        // the evidence that on-device th-TH does not emit line breaks (both request sites
        // set `addsPunctuation = true`); a line here names which source did.
        trace("NORMALIZED: replaced \(replaced) newline(s) in \(kind) text")
        return out
    }

    /// `onPartial` delivers the WHOLE growing transcription each time, not a delta. We inject
    /// only the part we have not injected yet.
    private func insertStableTranscript(final: String? = nil) {
        guard !activeLocalDictation, !autoCorrectEnabled, isCapturing,
              let text = stableTranscript.finish(final: final) else { return }
        lastTranscript = text
        if let reason = injector.injectBuffered(text) {
            lifetime.injectFailures += 1; thisCapture.injectFailures += 1
            injectionBlockedReason = reason
            lastOutcome = "Transcript kept in preview — \(reason)"
            hud.set(.error(reason))
            hud.show()
            trace("STABLE TEXT: not inserted (\(text.count) chars) — \(reason); available to copy")
            refreshMenu()
            return
        }
        injectedForUtterance = text
        typedSinceLastChunk += text
        lifetime.injectedChars += text.count; thisCapture.injectedChars += text.count
        clearInjectionBlockAfterSuccessfulWrite()
        trace("STABLE TEXT: inserted completed transcript once (\(text.count) chars); no replacement")
    }

    private func handlePartial(_ raw: String) {
        guard isCapturing || drainTimer != nil else { return }
        // Shadowed before ANY use, so the ledger, the document, the HUD and (via
        // `noteFinalChunk`) the cloud-search span all see one string. See
        // `normalizeForInjection`.
        let raw = normalizeForInjection(raw, kind: "partial")
        lifetime.partialsSeen += 1; thisCapture.partialsSeen += 1
        currentOnDeviceText = raw
        hud.set(.transcribing(raw.isEmpty ? "…" : raw))
        if autoCorrectEnabled && !activeLocalDictation {
            deliver(raw)
        } else {
            stableTranscript.updatePartial(raw)
        }
    }

    private func handleFinal(_ raw: String) {
        if activeLocalDictation {
            lifetime.finalsSeen += 1; thisCapture.finalsSeen += 1
            currentOnDeviceText = normalizeForInjection(raw, kind: "preview final")
            return
        }
        // Same shadow, same reason, and it must precede the `raw.count` in the FINAL trace
        // below so the two counts printed there still describe the same string.
        let raw = normalizeForInjection(raw, kind: "final")
        lifetime.finalsSeen += 1; thisCapture.finalsSeen += 1
        // isFinal: the utterance FINAL must attempt to reconcile even after a failed
        // partial repair — extending and/or replacing via the same LCP logic — rather
        // than silently dropping the tail of the utterance.
        if autoCorrectEnabled {
            deliver(raw, isFinal: true)
        } else {
            insertStableTranscript(final: raw)
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        currentOnDeviceText = text
        if !text.isEmpty { lastTranscript = text }
        if !utteranceDiverged && injectionBlockedReason == nil {
            // An empty final means the utterance produced nothing, NOT that the session
            // ended — the microphone is still live and the next utterance is already being
            // listened for. This used to show `hudIdleBody` ("Idle — tap Right-Option to
            // start dictating") under the status word "Transcribing", which is wrong twice
            // over: it tells the user to start something already running, and it does so
            // while claiming to transcribe. `.listening` is what this state actually is.
            hud.set(text.isEmpty ? .listening : .transcribing(text))
        }
        // THIS IS THE LINE THE RETRACTION EVIDENCE CAME FROM — `FINAL: 6 chars, injected
        // 22 chars, diverged=false` was how 16 characters of retracted Thai left in the
        // user's document were spotted — so it has to be readable as a check on the repair
        // that now runs. Two of its three numbers were not comparable: `text` is TRIMMED
        // and `injectedForUtterance` holds the UNTRIMMED `raw` that `deliver` was given,
        // so a final carrying trailing whitespace printed a mismatch even after a perfectly
        // correct reconciliation. `raw` is printed alongside, and the two counts to compare
        // are `raw` and `injected`: equal means the document now matches the recogniser.
        trace("FINAL: \(text.count) chars (raw \(raw.count)), "
            + "injected \(injectedForUtterance.count) chars, diverged=\(utteranceDiverged)")
        refreshMenu()
    }

    private func handleRecognizerState(_ state: LiveRecognizer.State) {
        if activeLocalDictation, case .unavailable = state {
            trace("LOCAL FINAL: Apple preview unavailable; local transcription continues")
            return
        }
        switch state {
        case .idle:
            trace("recogniser state: idle")
        case .listening:
            if isCapturing {
                insertStableTranscript()
            }
            stableTranscript.reset()
            // A new recognition request just stood up (initial start, pause auto-restart,
            // error restart, or the 20 s rotation). Its partials start FROM SCRATCH, so
            // the typed-count high-water mark of the previous utterance must not survive
            // into it -- carrying it over silently ate the first N characters of every
            // sentence after the first pause (the "not continuous" bug). The error-restart
            // path never emits a final, so this is hooked to .listening, not to finals.
            if !injectedForUtterance.isEmpty {
                trace("utterance boundary: reset typed high-water mark (was \(injectedForUtterance.count) chars)")
            }
            // WHY THE RESET IS SOUND under flush-then-replay rotation, which is a DIFFERENT
            // argument from the one that stood here before. The old "overlapped" rotation
            // never actually overlapped (measured 21/21 same-second deaths), so the reset
            // was sound because the successor transcribed from scratch. That machinery is
            // gone. Under `beginFlushRotation` the seam is sample-partitioned instead:
            // the outgoing request is flushed with `endAudio()` and its FINAL — covering
            // everything up to the flush instant t0 — is delivered and typed via
            // `deliver(isFinal: true)` BEFORE this `.listening` arrives (the final is
            // emitted from the Speech callback before `restart` runs; ordering is inherent,
            // not scheduled). The successor then replays the ring from exactly t0. So the
            // audio behind this reset's "from scratch" assumption is audio the old request
            // NEVER transcribed — no duplication, no gap, by construction. The one bounded
            // exception: `append` may land at most one tap buffer (~21 ms) on both sides
            // of the mark; sub-phoneme, accepted and documented at the seam in
            // LiveRecognizer. If anyone widens the replay window to start BEFORE the
            // flushed final's coverage (e.g. "a little extra context"), this reset becomes
            // a text-DUPLICATION bug and must be revisited here first.
            //
            // Skipping the reset at a cutover was considered and REJECTED. Keeping the old
            // high-water mark leaves the replacement's first partial sharing no prefix with
            // it, so `deliver` takes the divergence branch with lcp == 0, `repairDivergence`
            // computes staleCount == injectedForUtterance.count, and the app DELETES THE
            // ENTIRE UTTERANCE in order to type the replacement's first word.
            injectedForUtterance = ""
            // Same boundary rule as the two latches below, and sound for the same reason
            // the divergence latch's clear is: the ledger was just emptied, so a repair
            // deferred against the PREVIOUS utterance's text has nothing left to describe
            // and must not spend this utterance's deferral budget.
            transientRepairSkips = 0
            cloudOwnsUtterance = false
            // Same boundary rule for the injection latch: an `inject()` failure blocks
            // the rest of the UTTERANCE it happened in, never the session. Secure-input
            // leaks (Cursor does it several times a day) and AX hiccups are transient;
            // every new utterance must re-probe delivery rather than stay muted while
            // the recogniser keeps producing. Before this reset lived here, the latch
            // was cleared only in `startUtterance()` — reachable only via toggle
            // off/on — so one transient failure silently killed typing for the whole
            // session.
            if injectionBlockedReason != nil {
                trace("utterance boundary: cleared injection-blocked latch")
                injectionBlockedReason = nil
            }
            // ── AND THE DIVERGENCE LATCH, FOR A REASON THE OTHER TWO DO NOT SHARE ──────
            // `utteranceDiverged` suppresses partials (see the guard in `deliver`) and was
            // documented as self-clearing: "live typing resumes once a final reconciles".
            //
            // THE HISTORY IS WHY THE FLAG WAS RETIRED. Under the OLD overlapped rotation
            // that sentence was simply false: on-device th-TH delivered no final at all —
            // `finals=0` in ALL EIGHT capture summaries across three consecutive launches —
            // because the outgoing request was cancelled WITHOUT `endAudio()`, and Speech's
            // own VAD final does not arrive for continuous speech. So the flag's only other
            // exits were `startUtterance()` (toggle off/on) and a capture restart: one
            // unrepairable revision muted live typing until the user noticed and
            // power-cycled the hotkey. Trace 14:36 is that failure end to end — a refusal
            // 2 s in, then `injectedChars=7`, `55`, `0`.
            //
            // THE PRESENT IS WHY IT STAYS RETIRED. Finals exist again: flush-then-replay
            // rotation delivers exactly one per 20 s seam (`beginFlushRotation`), and it is
            // delivered before this `.listening`. That does not reopen the removal, and the
            // design must not start depending on it in either direction. Trace 14:36 was an
            // 11 s capture with no seam before the hotkey was released, so "wait for the
            // final" would still have meant "wait for something that never came"; in a
            // longer capture it means suppressing up to a full window of partials to pay
            // for a refusal that may have lasted milliseconds. Correct under frequent
            // finals AND under a single window that produces none — suppression-until-final
            // is neither.
            //
            // Clearing it here is the same boundary rule the latch above already states,
            // and it is safe for a concrete reason rather than an optimistic one:
            // `injectedForUtterance` was just reset to "" three lines up, so the ledger and
            // the document agree again by construction (the ledger claims nothing, and
            // nothing is what the next partial will be diffed against).
            //
            // READ THIS BEFORE TRUSTING THE FLAG: `utteranceDiverged` is now INERT.
            // No CODE in this file assigns it true any more (a grep for the assignment
            // matches only prose, this paragraph included) — because the refusal path
            // stopped suppressing altogether
            // (`reanchorAfterUnrepairedRevision` keeps typing through a revision it could
            // not apply). Its guard in `deliver` and its remaining readers are therefore
            // dead branches, and this clear is a no-op kept for symmetry with the latch
            // above it.
            //
            // It is retained rather than deleted only to keep this change set to behaviour
            // that was actually measured; it SHOULD be removed along with its readers.
            // Documented here so the next post-mortem does not go hunting for a suppression
            // path that no longer exists — which is exactly how the previous round lost
            // twelve minutes to a watchdog everyone assumed was armed.
            if utteranceDiverged {
                trace("utterance boundary: cleared divergence latch; live typing resumes")
                utteranceDiverged = false
            }
            utteranceSeq &+= 1
            trace("recogniser state: listening")
        case .unavailable(let reason):
            trace("recogniser state: unavailable — \(reason)")
            // THIS TEST MUST STAY ABOVE THE ROUTINE SUPPRESSIONS BELOW. The ordering is
            // load-bearing, not stylistic: `reason` ends with the vendor's
            // `localizedDescription`, which is outside our control, and a Speech error
            // whose text happens to contain "retry" — entirely plausible for a throttling
            // or timeout message — would be swallowed as plumbing by the next branch and
            // this escalation would silently never run. The specific token is matched
            // first so no vendor wording can mask it. `LiveRecognizer` guarantees the
            // token appears verbatim on every emission of this state and on no other
            // message; that guarantee is written down beside the emission itself.
            //
            // WHY THIS BRANCH EXISTS AT ALL. Handling used to end at the red HUD below —
            // no `endCapture`, no `recognizer.start()`, nothing that could recover. That is
            // why capture 14:26:19-14:41:25 held a hot microphone and typed nothing for
            // twelve minutes after the recogniser declared itself dead: the app was TOLD
            // and did nothing with it. `LiveRecognizer` no longer gives up (it retries
            // indefinitely at an 8 s backoff cap), but it owns no audio engine, so the one
            // recovery ever observed to revive this failure — a full capture restart that
            // rebuilds the engine and its session — can only be performed from here.
            if reason.contains("persistent recognition failure") {
                let (rms, frames) = levelBox.read()
                // Same four numbers every ladder line carries, for the same reason: an
                // escalation nobody can reconstruct afterwards is unfalsifiable. `frames`
                // rides along because in this exact failure it is the discriminator — audio
                // still arriving while the recogniser reports itself dead.
                let levels = "\(levelTrace(rms)) frames=\(frames)"
                // A teardown is already in flight, or there is nothing to tear down.
                // `endCapture` no-ops on both of those conditions, so escalating here would
                // burn the rate limit and a damper credit on a call that does nothing —
                // and the drain already running IS the recovery arriving.
                guard isCapturing, drainTimer == nil else {
                    trace("RECOGNIZER RECOVERY: persistent recognition failure reported "
                        + "with no live capture to restart (capturing=\(isCapturing), "
                        + "draining=\(drainTimer != nil)); ignored (\(levels))")
                    return
                }
                // THE SAME DAMPER TIER 2 USES, deliberately, and it is not optional here.
                // A system-wide daemon wedge produces this report every ~8 s for as long as
                // it lasts; a time limit alone would turn each one into a full
                // endCapture/beginCapture cycle forever — a permanent capture-restart loop,
                // worse for the user than the silent death being removed. The damper's
                // measured rule (see tier 2) is that a session which has never produced a
                // partial gets at most ONE speculative restart. With `sessionSawPartial`
                // cleared by `beginCapture` and `escalationsThisSession` surviving the
                // self-heal, that resolves to: an unproductive wedge is restarted exactly
                // once and then only reported; a session that demonstrably worked and then
                // died earns one restart of its own, no oftener than the limit below.
                //
                // A suppressed report still feeds `suppressedBouncesSinceRestart`, which is
                // the only way tier 3 can ever arm on a wedge that produces zero partials
                // in every new session — the one shape of failure tiers 1 and 2 cannot fix
                // by construction. Two consequences, stated because a non-watchdog path
                // feeding a watchdog counter is exactly the kind of coupling this file
                // documents rather than leaves to be discovered:
                //   - it ARMS tier 3, it does not invoke it. Tier 3 still fires only from
                //     the strike branch in `tickStatus`, behind the loud-tick gate and the
                //     bounce backoff, and only with `daemonRestartEnabled` on.
                //   - it also feeds `bounceBackoff` = min(ceiling, 6·2^min(count, 3)). At
                //     the 8 s report cadence the count saturates in ~24 s, so the backoff
                //     pins at its ceiling. That ceiling is now the toggle-independent 12 s
                //     (see `backoffCeiling`), and it HAS to stay under the 20 s rotation
                //     cadence: the window is measured from `lastRecognizerEventAt`, which
                //     rotation re-stamps every 20 s, so any ceiling at or above that
                //     describes a silence a rotating recogniser can never produce and gates
                //     the ladder off entirely. Within 12 s the pin only makes the
                //     anti-throttling backoff arrive sooner, which during a confirmed
                //     persistent failure is the wanted direction.
                guard sessionSawPartial || escalationsThisSession == 0 else {
                    suppressedBouncesSinceRestart += 1
                    trace("RECOGNIZER RECOVERY: persistent recognition failure, restart "
                        + "suppressed by the escalation damper (no partials this session, "
                        + "already restarted \(escalationsThisSession)x); "
                        + "suppressedBounces=\(suppressedBouncesSinceRestart) (\(levels))")
                    return
                }
                // Rate limit. `LiveRecognizer` re-reports on every retry cycle at a backoff
                // capped at 8 s, so this window sits comfortably above that cadence: at
                // most one restart per window however often the report arrives, and short
                // enough that a genuinely recoverable wedge is retried promptly rather than
                // waited out. Unthrottled TRACING of the suppression is intended — at an
                // 8 s cadence it is a handful of lines a minute, not the 1 Hz flood the
                // other rate-limited lines in this file exist to prevent, and the whole
                // point of this change is that the next failure is diagnosable.
                guard Date().timeIntervalSince(lastPersistentFailureRestartAt)
                        > Self.persistentFailureRestartInterval else {
                    trace("RECOGNIZER RECOVERY: persistent recognition failure, restart "
                        + String(format: "rate-limited (%.0f s since the last one, limit "
                                 + "%.0f s) ",
                                 Date().timeIntervalSince(lastPersistentFailureRestartAt),
                                 Self.persistentFailureRestartInterval)
                        + "(\(levels))")
                    return
                }
                lastPersistentFailureRestartAt = Date()
                escalationsThisSession += 1
                // Cleared exactly as tiers 2 and 3 clear it, and for their reason: the
                // healed session is a fresh problem and should climb the ladder from a
                // cheap bounce rather than resume mid-escalation against a request that no
                // longer exists.
                recognizerStalledTicks = 0
                trace("RECOGNIZER RECOVERY: recogniser reports persistent failure and "
                    + "cannot recover itself; restarting the whole capture (\(levels))")
                // Mirrors the tier-2 call site exactly. `wantsDictation` is left true, so
                // `syncDictation` at the end of `finishCapture` walks straight back into
                // `beginCapture` and the user simply keeps talking. No HUD: unlike tier 3,
                // which had just `kill -9`'d a system service, this heals in about a second
                // and a red banner would read as "it broke" — the very thing the routine
                // suppressions below exist to avoid.
                endCapture(reason: "recogniser reported persistent recognition failure")
                return
            }
            // Quick retries are routine plumbing, not user-facing failures -- flashing the
            // HUD red for them reads as "it broke". Two former suppressions here are gone
            // because nothing emits their strings any more: "promoting warm replacement"
            // (the warm-overlap machinery was excised) and "rotating request" (the flush
            // rotation is trace-only — the seam emits a final and a `.listening`, never an
            // `.unavailable`). Do not re-add branches for strings nothing emits; grep
            // LiveRecognizer for `emitState(.unavailable` before adding one.
            if reason.contains("retry") {
                return
            }
            // NAME THE ENGINE THAT ACTUALLY FAILED. This string was hardcoded to
            // "On-device recogniser" when there was only one engine; with Gemini Live
            // selected it is a lie of exactly the class `DictationEngineKind.recognizerNoun`
            // exists to prevent (see its doc comment): it tells the user their voice is
            // being handled on this Mac at the moment the engine streaming it to Google is
            // the one reporting a failure. `recognizerNoun` resolves to the identical
            // "On-device recogniser" for `.apple`, so the Apple path's message is unchanged.
            let message = "\(activeEngineKind.recognizerNoun) unavailable — \(reason)"
            lastOutcome = message
            hud.set(.error(message))
            hud.show()
            refreshMenu()
        }
    }

    /// The core of live injection: type the new suffix when the partial is a
    /// prefix-extension of what we typed, and repair in place when it is not.
    ///
    /// SFSpeechRecognizer does revise — for Thai it does so constantly: tone marks, vowels,
    /// and word merges are rewritten as context grows, so a non-prefix partial is the norm,
    /// not an edge case. The repair keeps the longest common prefix and hands exactly the
    /// stale tail to `TextInjector.replaceLastInserted(count:with:)`, which replaces the
    /// exact range we own or does nothing and returns a reason. On a refusal injection no
    /// longer stops: `reanchorAfterUnrepairedRevision` re-anchors the ledger and typing
    /// carries on, leaving the unrepairable tail in the document.
    ///
    /// That last sentence used to read "and we never pretend text was delivered", with the
    /// FINAL and the cloud pass named as the two reconciliation paths. Both claims are
    /// superseded and the reason is worth keeping: under the old overlapped rotation
    /// on-device th-TH delivered NO finals (`finals=0` across every capture of three
    /// consecutive launches), so "stop and wait for the final" resolved to "stop".
    ///
    /// Flush-then-replay rotation has since restored one final per 20 s seam. That widens
    /// what the reconciliation paths CAN do without changing what this path MUST do: a
    /// refusal still has no reconciliation before the window it happens in ends, and a
    /// capture shorter than one rotation still has none at all. We still never
    /// blind-backspace; we now do knowingly tolerate a bounded, visible inaccuracy rather
    /// than an unbounded silence. See `reanchorAfterUnrepairedRevision` for why the error
    /// cannot compound — and for the one place where that bound is deliberately dropped,
    /// on a seam final.
    private func deliver(_ text: String, isFinal: Bool = false) {
        // The menu must disable every automatic document rewrite, including the
        // Apple partial-repair path, even when no second provider is installed.
        guard autoCorrectEnabled && !activeLocalDictation else { return }
        // ── THE FINAL-ONLY MUTE USED TO BE HERE, AND IT STAYS REMOVED ──────────────────
        // `if finalOnlyInjection && !isFinal { return }` was a reasonable trade when it was
        // written — skip live partials in an app that cannot host revision, let each
        // utterance FINAL land in one clean go. It rests entirely on finals existing, and
        // when it was removed they did not: `finals=0` in all eight capture summaries
        // across three consecutive launches, because the old overlapped rotation cancelled
        // the outgoing request without `endAudio()`. So the guard did not degrade typing to
        // whole sentences, it stopped typing outright, for the remainder of a capture, on
        // ONE refusal — and the refusal that triggered it in trace 14:36 was "no focused
        // element", 2 s into the session.
        //
        // Finals came back with flush-then-replay rotation — one per 20 s seam — so the
        // guard would now type SOMETHING, and the sentence above is history rather than a
        // current fact. It is still not coming back, for two reasons the change does not
        // touch. What it would type is one 20 s blob per seam, arriving all at once instead
        // of live text, which is not this product. And the failure is undiminished: a
        // refusal early in a window still stops typing for the remainder of that window,
        // and a capture that ends before its first seam still receives nothing at all.
        //
        // `finalOnlyInjection` survives with its meaning narrowed to the half that is still
        // true and still valuable: this app has proven it will refuse in-place repair, so do
        // not keep paying for the attempt (see `repairDivergence`, where it now short-
        // circuits an AX round trip measured in Electron at up to ~900 ms). It suppresses
        // nothing at all now — neither this guard nor any other. There is no suppression
        // left on the partial path: `utteranceDiverged` below is inert (nothing sets it,
        // see the note at the `.listening` clear) and the injection-blocked latch became a
        // report rather than a gate. That is the point of the change set — a continuous
        // speaker must never hit a state that stops typing until some later event, because
        // on this build no such later event arrives.
        // The cloud already corrected this utterance; its text is authoritative. An
        // on-device FINAL arriving afterwards must not rewrite it back.
        //
        // ── EXCEPT FOR THE PART THE CLOUD NEVER HEARD ────────────────────────────────
        // This branch used to return unconditionally, and under flush rotation that drops
        // precisely the text the rotation exists to recover. `cloudOwnsUtterance` is set
        // when a correction lands MID-window and is cleared only at `.listening` — which
        // arrives AFTER the seam's flushed final. So a final carrying everything spoken
        // between the cloud's audio chunk and the flush instant was being discarded in
        // full, at every seam where a correction had landed.
        //
        // The exception is narrow by construction: a STRICT EXTENSION of the ledger. The
        // final agrees with every character the ledger claims and then continues, and that
        // continuation is audio beyond the WHOLE ledger. `cloudOwnsUtterance` is only set
        // when the corrected span is a SUFFIX of the ledger, so the continuation lies
        // beyond the corrected span too — content the cloud never saw and cannot own.
        // Appending it rewrites nothing.
        //
        // IT IS CONTENT-CORRECT EVEN THOUGH THE LEDGER DOES NOT MATCH THE DOCUMENT HERE,
        // and that is worth spelling out because the mismatch is deliberate:
        // `applyCloudResult` never folds cloud text into `injectedForUtterance` (see the
        // "NEVER assign cloud text into `injectedForUtterance`" note there), so after a
        // correction the ledger holds the recogniser's wording while the document holds
        // fal's. The skew is irrelevant to THIS write. The suffix is new speech, it goes
        // at the caret, and the caret sits after whatever the document actually ends with
        // — corrected or not. What must never happen is a final REPLACING the divergent
        // part, and strict extension is exactly the condition under which no divergent
        // part exists.
        //
        // Anything else — a final that revises text the cloud already rewrote — keeps
        // today's drop. There is no honest way to reconcile the two wordings that does not
        // delete applied cloud text on the strength of the worse transcription.
        //
        // NOTE THE FALL-THROUGH: this branch no longer always returns, which is unusual
        // enough to say out loud. On the extension shape control continues into the
        // ordinary append path below, deliberately: that path already owns the secure-input
        // probe, the standing-selection rule, both ledgers, the counters and the
        // retry-on-failure semantics, and a bespoke copy of it here would drift from it.
        // `cloudOwnsUtterance` stays SET — the cloud still owns the earlier span, and
        // `.listening` is still the only thing that clears it.
        var appendedPastCloudOwnedText = false
        if isFinal && cloudOwnsUtterance {
            let finalLcp = commonPrefixLength(injectedForUtterance, text)
            guard !injectedForUtterance.isEmpty,
                  finalLcp == injectedForUtterance.count,
                  text.count > finalLcp else {
                trace("FINAL: skipped — cloud correction already owns this utterance")
                return
            }
            // The empty-ledger clause is not reachable today — `.listening` clears the
            // ledger and this flag in the same block — and is written down anyway, because
            // with an empty ledger the extension test is trivially true for ANY text. Drop
            // it and this becomes "type the whole window again after the cloud's copy of
            // it", the text-DUPLICATION failure the `.listening` reset is documented to
            // guard against.
            appendedPastCloudOwnedText = true
        }
        guard !utteranceDiverged || isFinal else { return }
        // ── THE LAST MUTE, REMOVED ────────────────────────────────────────────────────
        // This used to be `guard injectionBlockedReason == nil || isFinal else { return }`,
        // and it is the same shape as the two latches above it: block the rest of the
        // utterance and rely on a FINAL to reconcile. When it was removed there were no
        // finals at all (`finals=0`, see above), so the `|| isFinal` escape could never
        // fire and the only exit was the `.listening` boundary. Flush rotation has since
        // made that escape reachable — one per 20 s seam — and it changes nothing here,
        // because the argument never rested on finals being absent: waiting for the seam
        // still means dropping up to a full window of partials to pay for a failure that
        // may have lasted a second. The reachable case is not exotic: `inject()` returns
        // "Secure input is active" when the flag flips between the non-latching probe and
        // the CGEvent post, which this file documents Cursor/Electron doing several times
        // a day.
        //
        // Retrying instead is safe for a mechanical reason, not an optimistic one: a failed
        // `inject()` returns BEFORE `injectedForUtterance = text` below, so the ledger still
        // describes the document exactly. The next partial recomputes its LCP against the
        // truth and simply tries again — the transient clears itself and typing resumes at
        // the next partial rather than at the next rotation.
        //
        // `injectionBlockedReason` survives as the REPORT (menu text, the cloud-pass gate,
        // `lastOutcome`), which is all it should ever have been.
        guard !text.isEmpty else { return }
        if text == injectedForUtterance {
            if isFinal && utteranceDiverged {
                // The final agrees with what was typed after all — nothing is stale.
                utteranceDiverged = false
                lastOutcome = nil
            }
            return
        }

        // Never type into a password field. TextInjector refuses too, but checking here as
        // well means the refusal is attributed to *this* app's own policy in the trace rather
        // than looking like a generic injection failure.
        //
        // NON-LATCHING on purpose: show the notice and return WITHOUT setting
        // `injectionBlockedReason`. This probe runs on every delivery, so typing is
        // suppressed exactly as long as the secure-input flag is actually held — and
        // resumes by itself the instant it is released. Latching here turned Cursor's
        // several-times-a-day transient leak into a session-wide mute.
        if injector.secureInputActive() {
            lifetime.secureInputRefusals += 1; thisCapture.secureInputRefusals += 1
            let message = "Secure input is active (password field, Terminal secure entry, or a "
                + "Cursor/Electron leak). Nothing was typed."
            trace("SECURE INPUT: refused to touch the focused app (\(text.count) chars pending)")
            lastOutcome = "Secure input active — nothing typed"
            hud.set(.error(message))
            hud.show()
            refreshMenu()
            return
        }

        // ── Forward-only typing was the ORIGINAL trade, and the user has reversed it ──
        //
        // The rule used to be "just keep typing; if it's wrong I'll fix it myself": when
        // the recogniser revised earlier words we did NOT go back, we only appended what
        // lay beyond the COUNT already typed. That decision is preserved here because it
        // was a real one — its whole point was that the app could not delete anything, so
        // it could never eat text the user typed by hand. What it also could not do was
        // stay correct, and for Thai it did not:
        //
        //   let typedCount = injectedForUtterance.count
        //   guard text.count > typedCount else { return }
        //   let suffix = String(text.dropFirst(typedCount))
        //
        // `dropFirst` never checked that `injectedForUtterance` is a PREFIX of `text`, and
        // for Thai it routinely is not. Two separate mechanisms, both reproduced in a
        // standalone harness (5 of the 6 measured sequences landed wrong):
        //
        //   * COUNT-STALL. Adding a tone mark to an existing cluster does not raise
        //     `text.count` — "เดียว" and "เดี๋ยว" are both 4 grapheme clusters — so the
        //     `>` gate returned and the mark was lost PERMANENTLY: the next growing
        //     partial sliced straight past it. "ก"→"ก่"→"ก่อ"→"ก่อน" typed "กอน".
        //   * MISALIGNMENT. A word-merge revision passes the gate and then slices at the
        //     wrong place: "ไม่ เป" (5 clusters) → "ไม่เป็นไร" (7) typed "ไม่ เปไร".
        //     Same class, non-Thai trigger: "👩"→"👩‍"→"👩‍💻"→"👩‍💻 hi" typed "👩 hi".
        //
        // So the gate is now "does the document differ from what I typed", not "is the
        // text longer", and the comparison is by CONTENT in grapheme clusters, never by
        // count. `commonPrefixLength` is the only arbiter:
        //
        //   * lcp == injectedForUtterance.count — `text` is a strict extension of what we
        //     typed. This is the overwhelming majority of partials and it was already
        //     correct, so it keeps the cheap append path below, untouched.
        //   * otherwise — the recogniser revised, merged, or RETRACTED characters we have
        //     already put in the user's document. Delete back to the common prefix and
        //     retype the remainder, via `repairDivergence` → `replaceLastInserted`.
        //
        // The retraction case falls out of the same branch with no special handling: a
        // shrinking partial has lcp == text.count < injectedForUtterance.count, so the
        // replacement is the empty string and the repair is a pure delete. That is the
        // fix for the field evidence where a `FINAL: 6 chars, injected 22 chars` line
        // meant 16 characters of retracted Thai were simply left in the document.
        //
        // THIS IS THE FIRST TIME THIS APP CAN DELETE ANYTHING, and the user authorised it
        // knowing exactly that: the old path could not eat hand-typed text because it
        // could not remove text at all. What makes it safe is entirely inside
        // `replaceLastInserted` — the `expecting:` content check, the caret-must-be-a-caret
        // guard, the clamped-range read-back, and the caret restore on every refusal.
        // Do not weaken any of them, and never follow a refusal with blind backspaces.
        let lcp = commonPrefixLength(injectedForUtterance, text)
        guard lcp == injectedForUtterance.count else {
            // Revision, merge, or retraction: everything from `lcp` onwards is stale.
            repairDivergence(to: text, isFinal: isFinal)
            return
        }
        let suffix = String(text.dropFirst(lcp))
        guard !suffix.isEmpty else { return }

        // ── COLLAPSE A STANDING SELECTION, BUT ONLY MID-UTTERANCE ─────────────────────
        // `kAXSelectedText` REPLACES a selection rather than inserting beside it, so an
        // "append" made while a selection stands does not append — it DELETES. Whether
        // that is wanted depends entirely on position within the utterance, which is why
        // the flag is the caller's decision and not TextInjector's:
        //
        //   * FIRST injection of an utterance (`injectedForUtterance.isEmpty`) — replace-
        //     selection is the FEATURE. Selecting a word and dictating over it is how a
        //     user rewrites it, and this app must not take that away. Flag off, exactly as
        //     the fresh-start site below has always had it.
        //   * MID-utterance — the user has not reached for the mouse since we started
        //     typing, so a selection standing here can only be OURS: TextInjector
        //     deliberately leaves the stale tail SELECTED when it refuses a repair. The
        //     sequence is not hypothetical. In Electron the refusal classifies transient,
        //     `repairDivergence` defers it without re-anchoring, and this line then writes
        //     over the standing selection — silently deleting the exact stale tail the
        //     ledger still claims is in the document, which desynchronises every later
        //     `replaceLastInserted` content check in the utterance. The deferral this
        //     change set added makes that path MORE reachable, not less.
        //
        // The cost, stated honestly because this runs on every mid-utterance partial: two
        // extra AX round trips (a focused-element copy plus one selection read), which
        // TextInjector's own measurements put in the sub-millisecond band even in Electron.
        // The 40 ms settle inside `collapseStandingSelectionToEnd` is paid only when a
        // selection is ACTUALLY standing — once per refused repair, not once per partial.
        if let reason = injector.inject(suffix,
                                        collapseStandingSelection: !injectedForUtterance.isEmpty) {
            lifetime.injectFailures += 1; thisCapture.injectFailures += 1
            // Recorded, not latched (see the note where the guard used to be). Every
            // subsequent partial retries, so a persistently broken injector reaches this
            // branch several times a second — hence the change test on the NOISY outputs:
            // the trace line and the menu fire only when the REASON changes, which keeps a
            // genuine new failure loud and a repeating one quiet, and makes a transient
            // recognisable in the trace as a single line.
            //
            // THE HUD IS DELIBERATELY OUTSIDE THAT GATE, and the asymmetry is load-bearing.
            // `handlePartial` calls `hud.set(.transcribing(raw))` immediately before every
            // `deliver`, so the HUD is overwritten on each partial. Gating the error behind
            // `isNewReason` therefore showed it once and let the very next partial replace
            // it with scrolling transcript — the user would watch text stream past while
            // NOTHING reached the document and no error was on screen. That is the same
            // "looks like it is working while doing nothing" failure this change set exists
            // to remove, relocated from the typing layer to the indicator layer. Re-setting
            // it every failed partial is what keeps it on screen, and it is what shipped
            // before this branch was rewritten.
            let isNewReason = (injectionBlockedReason != reason)
            injectionBlockedReason = reason      // already names the pane to open
            hud.set(.error(reason))
            hud.show()
            if isNewReason {
                trace("INJECT FAILED: \(suffix.count) chars — \(reason); retrying on the "
                    + "next partial (the ledger is unchanged, so nothing is stranded)")
                lastOutcome = "Injection failed"
                refreshMenu()
            }
            return
        }

        injectedForUtterance = text
        if appendedPastCloudOwnedText {
            // Traced only once the write has actually landed. A failed `inject()` returned
            // above with its own INJECT FAILED line, and announcing an append that did not
            // happen is the same class of lie as announcing a correction that did not.
            trace("FINAL: appended \(suffix.count) chars past cloud-owned text")
        }
        // Characters landed, so whatever transient made a repair unapplicable is over;
        // the next one starts its own deferral budget rather than inheriting a spent one.
        transientRepairSkips = 0
        lifetime.injectedChars += suffix.count; thisCapture.injectedChars += suffix.count
        // Typed-span ledger: record exactly what landed in the document since the last
        // FINAL audio chunk was cut. `noteFinalChunk` snapshots and resets this at each
        // chunk boundary; the snapshot is what the cloud correction searches for.
        typedSinceLastChunk += suffix
        if isFinal && utteranceDiverged {
            // A FINAL that extends the typed text after an earlier failed repair means the
            // typed text is no longer stale.
            utteranceDiverged = false
            lastOutcome = nil
        }
        clearInjectionBlockAfterSuccessfulWrite()
    }

    /// Characters just landed in the document, so whatever made `inject()` fail earlier in
    /// this utterance is demonstrably over -- keeping the latch set would leave the menu
    /// saying "Injection blocked — <reason>" and would suppress `handleFinal`'s HUD
    /// transcript until the next `.listening`, a mute indicator sitting over text the user
    /// can watch arriving.
    ///
    /// This used to say "only a FINAL can reach a successful write while the latch is set",
    /// because `deliver` had a guard that dropped every partial once it was set. That guard
    /// is gone (see "THE LAST MUTE, REMOVED"), so PARTIALS are now the normal caller — and
    /// that is exactly what makes this the reset for the change test in the failure branch:
    /// a transient clears the latch as soon as one partial writes, so a later recurrence is
    /// reported loudly instead of being swallowed as "same reason as before".
    private func clearInjectionBlockAfterSuccessfulWrite() {
        guard injectionBlockedReason != nil else { return }
        injectionBlockedReason = nil
        trace("injection-blocked latch cleared — a write landed after the failure "
            + "(normally a partial; the failure was transient)")
    }

    /// Longest common prefix, counted in Characters — the same unit `injectedForUtterance`
    /// and `replaceLastInserted(count:)` speak. Extended grapheme clusters matter for Thai:
    /// a base consonant plus its tone/vowel marks is one Character, and splitting inside one
    /// would make the replace range a lie.
    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var n = 0
        var ia = a.startIndex
        var ib = b.startIndex
        while ia < a.endIndex, ib < b.endIndex, a[ia] == b[ib] {
            n += 1
            ia = a.index(after: ia)
            ib = b.index(after: ib)
        }
        return n
    }

    /// Longest common suffix of `a` and `b`, in the same unit and by the same walk as
    /// `commonPrefixLength`, from the end. `repairDivergence` calls it on the stale tail
    /// and its replacement — both already cut at the common prefix — so it cannot overlap
    /// the prefix, and it stops at the shorter string, so it never exceeds
    /// `min(a.count, b.count)`. Stepping by `Character` is what keeps a Thai base
    /// consonant with its marks: a scalar walk would call "บ่" and "ก่" one unit alike and
    /// put the cut inside a cluster; this walk calls them different and returns 0.
    private func commonSuffixLength(_ a: String, _ b: String) -> Int {
        var n = 0
        var ia = a.endIndex
        var ib = b.endIndex
        while ia > a.startIndex, ib > b.startIndex {
            let pa = a.index(before: ia)
            let pb = b.index(before: ib)
            guard a[pa] == b[pb] else { break }
            n += 1
            ia = pa
            ib = pb
        }
        return n
    }

    /// Does a `replaceLastInserted` refusal describe a PERSISTENT property of the focused
    /// app, or a momentary one? Only a persistent one may downgrade this capture to
    /// `finalOnlyInjection`; see that declaration for the trace evidence that forced the
    /// split. This is the ONLY classifier -- `repairDivergence` is its only caller -- so
    /// the two lists cannot drift apart.
    ///
    /// Matched on stable substrings, the same discipline the recogniser's `unavailable`
    /// reasons already use. Both anchors are byte-identical in `TextInjector`'s two
    /// replace paths, and "clamped the selection" sits before the interpolated range
    /// numbers in its message, so neither can be split by a value.
    ///
    ///   * "does not accept AX text replacement" -- the AX role/attribute set of the
    ///     focused element. It cannot change while focus stays where it is.
    ///   * "clamped the selection" -- the field rewrote the range we asked for. A field
    ///     that does this does it every time.
    ///
    /// EVERYTHING ELSE IS TRANSIENT, INCLUDING REASONS THIS FUNCTION HAS NEVER SEEN --
    /// a selection the user held for one frame, focus moving mid-partial, a secure-input
    /// leak, a caret caught mid-cluster. The default is deliberately the permissive one:
    /// an unrecognised refusal that was really structural costs some repair churn, while
    /// an unrecognised refusal misfiled as structural silently mutes live typing for the
    /// rest of the capture -- which is the bug this classifier exists to fix. A refusal
    /// string added to `TextInjector` later therefore fails SAFE, and has to be listed
    /// here explicitly before it can latch anything.
    private func refusalIsStructural(_ reason: String) -> Bool {
        let structuralMarkers = [
            "does not accept AX text replacement",
            "clamped the selection",
        ]
        return structuralMarkers.contains { reason.contains($0) }
    }

    /// Why a revision is at `resolveUnrepairedRevision` instead of in the document. The
    /// routing there reads on this, so it is an enum rather than a second string beside
    /// `why:` — `why:` is the trace text, this is the decision.
    private enum UnrepairedReason {
        /// The focused app would not perform the AX replacement — a real refusal from
        /// `replaceLastInserted` (structural, or a transient that outlived its budget), or
        /// the attempt skipped because `finalOnlyInjection` has already latched.
        case appRefused
        /// `repairDivergence` refused before writing: the effective change was over
        /// `reanchorMaxStaleChars`, or a pure retraction over `retractionMaxStaleChars`.
        /// The app was never asked and, the fast-skip not having fired, is one that
        /// accepts repair — which is what lets this route re-anchor past the cap.
        case capRefused
    }

    /// A partial (or the final) revised, merged, or RETRACTED characters we already typed.
    /// Keep the longest common prefix; replace exactly the stale tail via
    /// `replaceLastInserted(count:with:)`. On success, injection simply continues on the
    /// next partial. On a refusal, stop injecting for this utterance and let the FINAL /
    /// cloud pass be the recovery — NEVER follow the refusal with blind backspaces.
    ///
    /// A retraction reaches here as `replacement == ""` and is therefore a pure DELETE of
    /// the stale tail. That is the one shape that can remove text without putting any
    /// back, and it is exactly what the field evidence asked for (`FINAL: 6 chars,
    /// injected 22 chars` left 16 characters of retracted Thai in the document).
    ///
    /// HISTORY, because the trace numbers from before today mean the opposite of what they
    /// look like: until this build this function had ZERO call sites. It is the only writer
    /// of the divergence counters and the only caller of `replaceLastInserted`, so every
    /// `divergences=0` in a pre-existing trace line was not a health signal — the counter
    /// could not be non-zero. `deliver()` now calls it on every non-extension partial, so
    /// the counters below measure something for the first time. They are split into
    /// repaired/refused deliberately: a single total cannot distinguish "the document was
    /// corrected" from "the app declined to touch the document", and those are the two
    /// outcomes a reader of the trace actually needs to tell apart.
    /// A revision the focused app would not let us apply in place. Keep typing anyway.
    ///
    /// ── THIS DELIBERATELY MAKES `injectedForUtterance` INACCURATE, ONCE, BY A BOUNDED
    ///    AMOUNT — AND THAT IS THE POINT ────────────────────────────────────────────────
    /// `deliver`'s contract has always been "we never pretend text was delivered", and the
    /// refusal path honoured it by suppressing partials until a FINAL or the cloud pass
    /// reconciled the document. That contract is sound. Its recovery mechanism was gone
    /// when this was written: on-device th-TH delivered no finals at all — `finals=0` in
    /// all eight capture summaries across three consecutive launches — because utterance
    /// boundaries came from request rotation and the old rotation cancelled the outgoing
    /// request without `endAudio()`. "Suppress until a final" therefore evaluated to
    /// "suppress until the user gives up".
    ///
    /// Flush-then-replay rotation has since restored one final per 20 s seam, and this
    /// design does not go back. It never depended on finals being absent forever — only on
    /// a refusal having no reconciliation WITHIN the window it happens in, which is still
    /// true, and on a capture shorter than one rotation having none at all, which is
    /// exactly the trace below: 11 s, no seam before the hotkey was released. What is
    /// written here has to hold both when a final arrives every 20 s and when a whole
    /// window produces none.
    ///
    /// Trace 14:36 is the whole argument. A refusal 2 s into an 11 s capture, no rotation
    /// before the hotkey was released, `injectedChars=7`: the user spoke for nine more
    /// seconds into a document that never moved. Clearing the latch at the `.listening`
    /// boundary (which this change set also does) does not save that capture — it only
    /// shortens the dead window to the 20 s rotation cadence in longer ones.
    ///
    /// So on a refusal we re-anchor the ledger to what the recogniser now says and carry
    /// on. The document keeps the stale tail — typically the 3-7 characters the trace
    /// shows — and everything spoken afterwards is typed instead of lost.
    ///
    /// WHY THE ERROR CANNOT COMPOUND, which is what makes this safe rather than merely
    /// expedient. Say the document holds "ABC" and the recogniser revises to "ABD":
    ///   * the repair is refused, so the document keeps "ABC" while the ledger becomes
    ///     "ABD" — one wrong character;
    ///   * the next partial "ABDE" is a clean prefix-extension of the ledger, so "E" is
    ///     appended normally: document "ABCE", ledger "ABDE" — still one wrong character;
    ///   * a later revision to "ABDF" computes `expected` as the ledger's tail "E", and
    ///     "E" IS what sits in the document, so `replaceLastInserted` matches and SUCCEEDS.
    /// Normal in-place repair resumes for everything typed after the anchor. Each refusal
    /// strands its own stale tail and nothing more; the errors are local, visible, and the
    /// HUD continues to show the correct transcript beside them.
    ///
    /// ── AND WHY THAT ARGUMENT ONLY BECAME TRUE WITH THE TWO LAYERS ABOVE ─────────────
    /// "Each refusal strands its own stale tail and nothing more" was quietly incomplete
    /// when it was written, because it says nothing about how BIG that tail is. At
    /// `lcp == 0` — the shape a Thai pre-posed vowel (เ แ โ ใ ไ) produces legitimately at
    /// index 0, and the shape behind the traced `kept 0 common chars … no focused element`
    /// line — `staleCount` IS the entire utterance, up to twenty seconds of speech
    /// stranded permanently to answer one momentary AX hiccup. Nothing here bounded that.
    ///
    /// Three layers now do:
    ///   * `repairDivergence` DEFERS a transient refusal (up to `maxTransientRepairSkips`
    ///     in a row) without re-anchoring at all, so the momentary hiccup — which is what
    ///     the trace evidence actually shows — never gets here;
    ///   * `repairDivergence` REFUSES, before asking the app at all, a repair whose
    ///     effective change exceeds `reanchorMaxStaleChars`, or a pure retraction past
    ///     `retractionMaxStaleChars` — the run-5 wipe, `replaced 175 stale chars with
    ///     178` — and routes it through `resolveUnrepairedRevision` as `.capRefused`;
    ///   * `resolveUnrepairedRevision` diverts an APP refusal longer than
    ///     `reanchorMaxStaleChars` to a fresh start instead of stranding it — ON A
    ///     PARTIAL.
    /// So on the app-refused PARTIAL path this function strands at most
    /// `reanchorMaxStaleChars` clusters, which is what turns the compounding argument
    /// above into a real bound rather than a hopeful one. Both of this function's call
    /// sites go through `resolveUnrepairedRevision`; call it directly and the bound is
    /// gone.
    ///
    /// The CAP-refused path in an app that accepts repair is deliberately NOT bounded
    /// this way since run 7: it re-anchors whatever the stale count, so the strand it
    /// leaves is the whole rewritten region — 18 to 36 clusters at run 7 lines 40-68.
    /// The compounding argument holds for it unchanged (each strand is local, the next
    /// partial diffs against the truth); what makes the larger strand acceptable is
    /// stated at `reanchorMaxStaleChars`: it is one utterance deep and the correction
    /// pass replaces it, which a fresh start made impossible.
    ///
    /// ── ON A FINAL THE STRAND IS DELIBERATELY UNBOUNDED ──────────────────────────────
    /// `resolveUnrepairedRevision` now sends every FINAL here regardless of `staleCount`,
    /// so the cap above describes the partial path only. That is a knowing trade, argued
    /// in full at that guard: under flush rotation a fresh start on a final retypes a whole
    /// 20 s window, at every seam, in exactly the apps that refuse in-place repair.
    ///
    /// The compounding argument does not need the bound on this path, because compounding
    /// needs a NEXT PARTIAL to compound into and a final does not have one: `.listening`
    /// follows it and empties the ledger, so the re-anchored mark never gets diffed against
    /// anything. The user keeps a stale tail in the document instead of a duplicated
    /// window, and loses the gap text, which the trace says out loud.
    ///
    /// Since the run-5 wipe this door is also reached from an app that ACCEPTS repair:
    /// `repairDivergence` refuses, before calling `replaceLastInserted`, a final whose
    /// effective change exceeds `reanchorMaxStaleChars` (`replaced 175 stale chars with
    /// 178` at run 5 line 115), and a "stale tail" of that size is the sentence the user
    /// watched being typed. Keeping it, and dropping the recogniser's rewrite, is the
    /// point of the refusal — the argument above is unchanged, the beneficiary is new.
    ///
    /// Note what is NOT touched: `injectedChars` and `typedSinceLastChunk` both describe
    /// characters actually written to the document, and this path writes none. Inflating
    /// them here would corrupt the cloud pass's span accounting, which is the one consumer
    /// that still needs the ledger to mean "what is really in the document".
    ///
    /// `utteranceDiverged` is deliberately NOT set. It is the suppression this function
    /// exists to replace; leaving it set would reinstate the mute one line after removing
    /// it. Since these were its only writers, the flag is now inert everywhere — see the
    /// note at the `.listening` clear. Do not "restore" it here on the assumption that
    /// something else still depends on it.
    /// The single door to "this revision will not be applied in place" — reached from the
    /// structural fast-skip, from a real refusal, and from the two cap gates alike, which
    /// is the point: an app that refuses EVERY repair (Electron, via `finalOnlyInjection`)
    /// is precisely where the unbounded strand recurs, so routing only the refusal branch
    /// through the cap would leave the common case uncapped.
    ///
    /// The rule, in the order the code tests it:
    ///   * a FINAL re-anchors, whatever the stale count (argued at the first guard);
    ///   * a stale tail within the cap — a revision, a merge, a tone mark — re-anchors;
    ///   * a CAP refusal in an app that accepts repair re-anchors too, past the cap, so
    ///     the stranded rewrite stays inside the one-utterance span the correction pass
    ///     can replace (run 7; the measurement is at `reanchorMaxStaleChars`);
    ///   * an APP refusal past the cap on a partial is not a revision at all — it is the
    ///     recogniser having replaced the whole utterance in an app that cannot fix it —
    ///     so the app types the transcript again, in full, after a separator, and says so.
    /// `reason` is what separates the last two; `why` is only the trace text.
    private func resolveUnrepairedRevision(to text: String,
                                           lcp: Int,
                                           staleCount: Int,
                                           isFinal: Bool,
                                           reason: UnrepairedReason,
                                           why: String) {
        // ── A FINAL NEVER FRESH-STARTS, WHATEVER THE STALE COUNT ──────────────────────
        // The fresh start below types the whole transcript again. On a PARTIAL that is the
        // right trade: the utterance is still open, the alternative is stranding everything
        // said so far, and the duplicate is paid once.
        //
        // On a FINAL it is the wrong trade, and flush rotation is what changed the
        // arithmetic. There is now one final per 20 s seam, and in an app that has set
        // `finalOnlyInjection` (Electron) every revision takes the structural fast-skip
        // straight into this function with no transient budget in front of it, while
        // `addsPunctuation` makes a deep-lcp revision on a final the ordinary case rather
        // than the exotic one. Fresh-starting there retypes an ENTIRE 20 s window — and
        // then does it again at the next seam, and the next.
        //
        // Weigh the two: a fresh start on a final buys at most the gap characters between
        // the common prefix and the recogniser's text, and costs a duplicated window,
        // repeatably. Re-anchoring loses those same gap characters and nothing else,
        // because the final is immediately followed by `.listening`, which empties the
        // ledger anyway — and it loses them in an app where in-place repair is already
        // structurally impossible. Stale text beats duplication.
        //
        // The sacrifice is traced rather than swallowed, because the user is losing real
        // words here and the trace is where that has to be visible.
        if isFinal, staleCount > Self.reanchorMaxStaleChars {
            trace("DIVERGENCE: seam final diverged too deeply (\(staleCount) stale); "
                + "re-anchored without retyping — gap text not recovered in this app")
        }
        // `!isFinal` is part of the guard, not of the branch above, so that BOTH final
        // shapes — deep and shallow — leave through the same re-anchor call. The fresh
        // start below is therefore partial-only; its trace still carries the
        // "(final reconciliation)" suffix, now unreachable, kept so the line stays correct
        // if this rule is ever revisited.
        //
        // ── A CAP REFUSAL IN AN APP THAT ACCEPTS REPAIR RE-ANCHORS, PAST THE CAP ──────
        // The third clause is run 7's correction (`TEST-2026-09-03-run7-trace.txt` lines
        // 40-68, argued at `reanchorMaxStaleChars`): a cap refusal on a partial always has
        // `staleCount` over the cap, so without it every one fresh-started, the first
        // sentence was typed six times, and the correction pass refused its own fix
        // against the inflated span (line 76). Re-anchoring instead leaves the rewritten
        // region in the document, one utterance deep, where that pass can replace it.
        //
        // `!finalOnlyInjection` is unreachable today — the cap gates sit BELOW the
        // structural fast-skip in `repairDivergence`, so a `.capRefused` always comes from
        // an app that has not latched — and is written anyway so the rule is complete in
        // one place: in an app that cannot be repaired there is no pass to clean a strand
        // up, and the fresh start stays the better failure there (run 6).
        let capRefusedInRepairableApp = reason == .capRefused && !finalOnlyInjection
        guard staleCount > Self.reanchorMaxStaleChars, !isFinal, !capRefusedInRepairableApp
        else {
            reanchorAfterUnrepairedRevision(to: text, lcp: lcp, staleCount: staleCount,
                                            isFinal: isFinal, why: why)
            return
        }

        // ── THE LEADING SPACE IS LOAD-BEARING, NOT COSMETIC ────────────────────────────
        // The whole design rests on "the document tail equals the ledger", and a bare join
        // can break that silently. Swift segments graphemes over the CONCATENATION: if the
        // stale text ends in a base consonant and `text` opens with a combining mark — an
        // everyday shape in Thai, and the reason this file counts in Characters everywhere
        // — the two merge into ONE cluster in the document. The document would then hold
        // one cluster fewer than the ledger's `text`, `injectedForUtterance.suffix(...)`
        // would name the wrong span, and EVERY later `replaceLastInserted` content check
        // in the utterance would refuse against text it should have matched. A space is a
        // cluster nothing combines across, so the boundary is guaranteed by construction.
        //
        // It is deliberately NOT written into `injectedForUtterance`: the ledger means
        // "what the recogniser said that is now in the document", `deliver` diffs the next
        // partial against it, and a space the recogniser never uttered would put every
        // subsequent common prefix off by one. `typedSinceLastChunk` is the opposite case
        // and DOES get it — that ledger is a document-side span the cloud pass searches
        // the document for, so it has to record what literally landed.
        let separated = " " + text
        if let reason = injector.inject(separated, collapseStandingSelection: true) {
            // Record NOTHING. The ledger still describes the document, so the next partial
            // recomputes honestly and retries — the same argument as a deferred repair.
            trace("DIVERGENCE: fresh start not typed — \(staleCount) stale chars exceeded "
                + "cap \(Self.reanchorMaxStaleChars) but the injection was refused "
                + "(\(reason)); ledger unchanged, retrying on the next partial")
            return
        }

        lifetime.freshStarts += 1; thisCapture.freshStarts += 1
        injectedForUtterance = text
        // Both counters describe characters that REALLY landed, separator included — the
        // opposite of `reanchorAfterUnrepairedRevision`, which leaves them alone precisely
        // because it writes nothing. This path writes.
        lifetime.injectedChars += separated.count; thisCapture.injectedChars += separated.count
        typedSinceLastChunk += separated
        // A write landed, so the deferral budget starts over and the injection-blocked
        // report must stop claiming the app cannot type.
        transientRepairSkips = 0
        lastTranscript = text
        lastOutcome = "Typed the sentence again; \(staleCount) stale character(s) left before it"
        clearInjectionBlockAfterSuccessfulWrite()
        trace("DIVERGENCE: fresh start — \(staleCount) stale chars exceeded cap "
            + "\(Self.reanchorMaxStaleChars); typed full transcript (\(text.count) chars) "
            + "after a separator; the old text stays in the document"
            + (isFinal ? " (final reconciliation)" : "") + " — \(why)")
        refreshMenu()
    }

    private func reanchorAfterUnrepairedRevision(to text: String,
                                                 lcp: Int,
                                                 staleCount: Int,
                                                 isFinal: Bool,
                                                 why: String) {
        lifetime.divergencesRefused += 1; thisCapture.divergencesRefused += 1
        lastTranscript = text
        lastOutcome = "Kept typing; \(staleCount) stale character(s) left in the text"
        injectedForUtterance = text
        trace("DIVERGENCE: re-anchored\(isFinal ? " (final reconciliation)" : "") — "
            + "kept \(lcp) common chars, left \(staleCount) stale chars in the document, "
            + "typing continues from the recogniser's text — \(why)")
        refreshMenu()
    }

    private func repairDivergence(to text: String, isFinal: Bool) {
        let lcp = commonPrefixLength(injectedForUtterance, text)
        let staleCount = injectedForUtterance.count - lcp
        let replacement = String(text.dropFirst(lcp))

        let expected = String(injectedForUtterance.suffix(staleCount))
        // ── THIS APP HAS ALREADY PROVEN IT REFUSES IN-PLACE REPAIR ─────────────────────
        // The only thing `finalOnlyInjection` still gates, and the only part of its old job
        // that was ever load-bearing: skip an attempt whose outcome is known. The call
        // below is not cheap — `replaceLastInserted` polls AX under a 0.9 s budget, and
        // this file's own Electron measurement puts a refusal at ~1.1 s, twice per Thai
        // utterance — so retrying it on every revision in an app that structurally cannot
        // serve it burns roughly a second of the main actor to learn nothing.
        //
        // No HUD here on purpose: in such an app this is the expected steady state, not an
        // incident, and an error banner on every revision would be noise that trains the
        // user to ignore the one that matters.
        //
        // ── RE-ANCHOR, DO NOT SUPPRESS ────────────────────────────────────────────────
        // `reanchorAfterUnrepairedRevision` is what keeps typing alive; see its definition
        // below for why pretending is the lesser evil once finals stopped existing.
        //
        // ── AND IT GOES THROUGH THE SAME K-BOUND AS A REAL REFUSAL ────────────────────
        // `resolveUnrepairedRevision`, not `reanchorAfterUnrepairedRevision` directly. In
        // an app that has set this latch EVERY revision lands here, so this is exactly
        // where an `lcp == 0` whole-utterance strand recurs; skipping the cap here would
        // cap the rare path and leave the common one unbounded.
        if finalOnlyInjection {
            resolveUnrepairedRevision(to: text, lcp: lcp, staleCount: staleCount,
                isFinal: isFinal, reason: .appRefused,
                why: "this app structurally refuses in-place repair (attempt skipped)")
            return
        }

        // ── AND AN APP THAT ACCEPTS REPAIR IS STILL NOT HANDED A WIPE ─────────────────
        // Everything above bounds what a REFUSED repair may strand. Nothing bounded what
        // an ACCEPTED one may overwrite, and `TEST-2026-08-31-run5-trace.txt` line 115 is
        // the result: `kept 10 common chars, replaced 175 stale chars with 178 chars` —
        // the recogniser rewrote an early word, the common prefix collapsed to 10, and
        // the call below selected and overwrote the user's entire sentence in one AX
        // write. Thai has no spaces, so th-TH re-segments the Thai before an English
        // word (`ผมใช้ Python` → `พรชัยพีเทิร์น`, TEST-2026-08-31-mixed-language.md line
        // 54); `lcp` then lands near 0 and `staleCount` is the whole 20 s window. The
        // user reports it as "the system resets and deletes all the words". Same trace,
        // line 124: `kept 1 … replaced 18 stale chars with 22`.
        //
        // The bound is on what the write DESTROYS — not on `staleCount`, and not on the
        // size of the write. `replaceLastInserted` selects exactly `staleCount` clusters
        // and pastes `replacement` over them. A cluster that sits at the end of both is
        // deleted and put straight back, so it costs the user nothing; and a replacement
        // that is merely LONGER than the tail it replaces is new speech being typed, not
        // typed speech being removed. The second is in the trace: `replaced 3 stale chars
        // with 12` at line 144 is a revision that arrived with a burst of new text behind
        // it, and a bound on `max(staleCount, replacement.count)` would refuse it — and a
        // refusal here re-anchors, which DROPS the replacement, so that shape would lose
        // nine clusters of speech to protect three. The first is NOT measured: the old
        // success line printed no suffix, so the effective change of `replaced 93 stale
        // chars with 83` at line 86 is unknown, and a raw `staleCount > 10` cannot tell a
        // re-emitted tail from a wipe at all — it refuses both. The constructed version
        // of that shape with an 80-cluster suffix lands at 13 and is refused too
        // (tools/cap-test/RESULT-2026-09-03.txt, case 3). Each false refusal trades a
        // correct repair for a stranded tail or a duplicated sentence. So: the common
        // suffix comes off, and only the stale clusters that are NOT put back are
        // counted against the cap.
        //
        // WHAT A REFUSAL COSTS, stated here because the alternative was a wipe and the
        // trade must stay visible. The route is `resolveUnrepairedRevision` with
        // `.capRefused`, and in this app — one that accepts repair, or the fast-skip above
        // would have returned — it RE-ANCHORS, partial or final: the recogniser's rewrite
        // is dropped, the document keeps what the user watched being typed, and the
        // ~1 s correction pass gets a span the size of one utterance to replace. S1 first
        // sent a partial to a fresh start instead, and run 7 measured the cost in TextEdit
        // (`TEST-2026-09-03-run7-trace.txt` lines 40-68): six refusals in a row on one
        // sentence, six retyped transcripts, and the correction pass refusing its own fix
        // as `span 225 vs cloud 38` (line 76). The full argument sits at
        // `reanchorMaxStaleChars`. It is not deferred like a transient refusal, because it
        // is not transient — the next partial carries the same rewrite — and it leaves
        // `transientRepairSkips` alone, because nothing was written and nothing was
        // learned about the app.
        //
        // The trace line ends in "re-anchoring", and since run 7 that is what happens;
        // `resolveUnrepairedRevision` prints its own outcome line (re-anchored / seam
        // final diverged too deeply) immediately after, and the harness greps this one
        // by its prefix.
        let suffix = commonSuffixLength(expected, replacement)
        let effectiveChange = staleCount - suffix

        // ── A PURE RETRACTION GETS THE TIGHTER CAP ────────────────────────────────────
        // `replacement.isEmpty` is the one shape that removes text and puts none back
        // (`deliver` calls it a pure delete), and the recogniser does not always mean it:
        // run 5 lines 123-124 are a 3-cluster delete and, in the same second, a rewrite
        // of the same region. Deleting a whole clause on a partial that the next partial
        // reverses is the wipe again with extra steps. `retractionMaxStaleChars` says why
        // four. Checked before the general cap so a large retraction is counted as what
        // it is; `suffix` is 0 here by construction, so `effectiveChange == staleCount`.
        if replacement.isEmpty, staleCount > Self.retractionMaxStaleChars {
            lifetime.retractionsRefused += 1; thisCapture.retractionsRefused += 1
            trace("DIVERGENCE: retraction refused — \(staleCount) stale chars with nothing "
                + "to type back exceeds cap \(Self.retractionMaxStaleChars); re-anchoring")
            resolveUnrepairedRevision(to: text, lcp: lcp, staleCount: staleCount,
                isFinal: isFinal, reason: .capRefused,
                why: "pure retraction of \(staleCount) chars exceeded cap "
                    + "\(Self.retractionMaxStaleChars) (refused before writing)")
            return
        }
        if effectiveChange > Self.reanchorMaxStaleChars {
            lifetime.repairsRefusedTooLarge += 1; thisCapture.repairsRefusedTooLarge += 1
            trace("DIVERGENCE: repair refused — effective change \(effectiveChange) exceeds "
                + "cap \(Self.reanchorMaxStaleChars) (stale \(staleCount), replacement "
                + "\(replacement.count), common suffix \(suffix)); re-anchoring")
            resolveUnrepairedRevision(to: text, lcp: lcp, staleCount: staleCount,
                isFinal: isFinal, reason: .capRefused,
                why: "effective change \(effectiveChange) exceeded cap "
                    + "\(Self.reanchorMaxStaleChars) (refused before writing)")
            return
        }
        guard let repair = TailRepair.plan(typed: injectedForUtterance,
                                          staleCount: staleCount, replacement: replacement) else {
            trace("DIVERGENCE: invalid repair span; nothing replaced")
            return
        }
        if let reason = injector.replaceLastInserted(count: repair.count, with: repair.replacement,
                                                     expecting: repair.expected) {
            trace("DIVERGENCE: repair FAILED\(isFinal ? " (final reconciliation)" : "") — "
                + "kept \(lcp) common chars, could not replace \(staleCount) stale chars "
                + "with \(replacement.count) chars — \(reason)")
            // The structural latch now buys ONE thing only: never pay for this refusal
            // again in an app that has proven it cannot serve the request. It no longer
            // decides whether typing continues — `reanchorAfterUnrepairedRevision` does,
            // identically for both classes.
            if refusalIsStructural(reason), !finalOnlyInjection {
                finalOnlyInjection = true
                trace("IN-PLACE REPAIR DISABLED: focused app structurally refused it; "
                    + "skipping the attempt for the rest of this capture — typing continues")
            }

            // ── DEFER A TRANSIENT BEFORE PAYING FOR IT ────────────────────────────────
            // Re-anchoring is a PERMANENT answer: the stale tail stays in the user's
            // document forever. The traced refusal that motivated all of this — "no
            // focused element", at `lcp == 0`, `kept 0 common chars` — is the opposite of
            // permanent; it is one AX round trip catching focus mid-move. Answering it
            // by stranding an entire utterance is the wrong trade in both directions.
            //
            // So a transient refusal buys the document nothing and changes nothing: no
            // write, no re-anchor, ledger untouched. That is safe for the mechanical
            // reason `deliver` already relies on for a failed `inject()` — the refusal
            // returned before anything was written, so `injectedForUtterance` still
            // describes the document exactly and the next partial recomputes its common
            // prefix against the truth. See `transientRepairSkips` for why it is bounded,
            // and note there is deliberately no `isFinal` carve-out: on a final there is
            // no "next partial", so the tail simply survives to the `.listening` reset,
            // which is harmless while the ledger stays honest.
            //
            // REVISITED, as the parenthesis that stood here asked: flush rotation has
            // restored real finals, one per 20 s seam. The decision is unchanged — the
            // deferral keeps no `isFinal` carve-out. Deferring on a final writes nothing,
            // re-anchors nothing and leaves the ledger describing the document exactly,
            // which is the same "harmless" as before, except that the `.listening` reset
            // now makes it harmless by construction rather than by argument. The decision
            // that DID change sits one layer down, in `resolveUnrepairedRevision`: a final
            // never fresh-starts, whatever the stale count.
            if !refusalIsStructural(reason), transientRepairSkips < Self.maxTransientRepairSkips {
                transientRepairSkips += 1
                trace("DIVERGENCE: repair deferred (transient: \(reason)); ledger unchanged, "
                    + "retrying on next partial "
                    + "(skip \(transientRepairSkips)/\(Self.maxTransientRepairSkips))")
                return
            }

            // Structural, or a "transient" that has now failed
            // `maxTransientRepairSkips` times in a row and is therefore behaving
            // structurally whatever the classifier calls it.
            resolveUnrepairedRevision(to: text, lcp: lcp, staleCount: staleCount,
                                      isFinal: isFinal, reason: .appRefused, why: reason)
            return
        }

        lifetime.divergencesRepaired += 1; thisCapture.divergencesRepaired += 1
        injectedForUtterance = text
        transientRepairSkips = 0
        lifetime.injectedChars += replacement.count; thisCapture.injectedChars += replacement.count

        // Keep the CHUNK ledger honest about the document, exactly as the cloud path does
        // after its own replace. `typedSinceLastChunk` is what `noteFinalChunk` snapshots
        // and what `replaceRecentText(find:)` later searches the document for; if it still
        // held the stale tail we just deleted, that search would look for a span that no
        // longer exists and the cloud correction would refuse — silently converting every
        // repaired utterance's cloud result into `cloudUnapplied`.
        //
        // Matched with `.backwards, .anchored, .literal` rather than by Character
        // arithmetic: the ledger is a CONCATENATION of injected suffixes, so its own
        // grapheme segmentation can merge across a join that neither source string had
        // (a leading combining mark absorbing the character before it). An anchored
        // literal match is the same unit discipline `replaceLastInserted` uses, and it
        // simply fails rather than mis-slicing.
        if expected.isEmpty {
            typedSinceLastChunk += replacement
        } else if let stale = typedSinceLastChunk.range(of: expected,
                                                        options: [.backwards, .anchored, .literal]) {
            typedSinceLastChunk.replaceSubrange(stale, with: replacement)
        } else {
            // The stale tail reaches back past the last chunk cut, so this repair spans a
            // boundary the ledger cannot express. Leave it alone and say so: an unpatched
            // ledger costs one cloud correction, a mis-patched one rewrites the wrong span.
            trace("DIVERGENCE: chunk ledger NOT patched — the \(staleCount) stale chars "
                + "reach back past the last chunk boundary (ledger holds \(typedSinceLastChunk.count) chars)")
        }

        if utteranceDiverged {
            // The reconciliation succeeded after an earlier failed repair: the typed text
            // is correct again, so injection may resume.
            utteranceDiverged = false
            lastOutcome = nil
        }
        clearInjectionBlockAfterSuccessfulWrite()
        // `replaced N stale chars` keeps its wording — tools/run-correction-harness.sh
        // greps it — and the parenthetical that follows is what makes "no repair above
        // the cap" checkable from the trace: raw N can exceed the cap on a correct repair
        // (stale 175 / suffix 170 / effective 5), so the harness must read `effective`.
        trace("DIVERGENCE: repaired in place\(isFinal ? " (final reconciliation)" : "") — "
            + "kept \(lcp) common chars, replaced \(staleCount) stale chars with "
            + "\(replacement.count) chars (effective \(effectiveChange), suffix \(suffix))"
            + (replacement.isEmpty ? " (RETRACTION: pure delete)" : ""))
    }

    // MARK: - Chunk loop (cloud accuracy pass)

    /// Poll the pipeline for finalized utterances and hand each one to the cloud pass.
    ///
    /// `nonisolated` and driven from `Task.detached`, so it runs on the generic executor:
    /// this is neither the main actor nor — emphatically — the realtime audio thread.
    /// `takeChunk()` is documented as "call from a background Task", and this is that Task.
    nonisolated private func chunkLoop(pipeline: AudioPipeline,
                                       cloud: any CorrectionProvider,
                                       generation: Int,
                                       flushRequest: FlushRequestBox) async {
        trace("LOOP[\(generation)]: chunk loop started (correction via \(cloud.displayName))")
        var polls = 0
        var chunks = 0
        var finals = 0
        var dispatched = 0

        loop: while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                break loop   // cancelled while sleeping
            }
            if Task.isCancelled { break loop }

            polls += 1
            // Liveness. In a silent room there may be zero chunks for the whole run, so this
            // is the only line that distinguishes "loop running, nothing to say" from "loop
            // died on its first iteration". ~1 line per 3 s; cheap.
            if polls % 15 == 0 {
                trace("LOOP[\(generation)]: alive — polls=\(polls) chunks=\(chunks) "
                    + "finals=\(finals) cloudDispatched=\(dispatched)")
            }

            guard let chunk = pipeline.takeChunk() else { continue }
            chunks += 1
            // Interim windows existed to keep the old whisper-driven UI alive. LiveRecognizer
            // does that job now, word by word, so interims are dropped here rather than
            // burning a cloud request on audio that is about to be re-sent.
            guard chunk.isFinal else { continue }
            finals += 1
            trace(String(format: "CHUNK[%d]: FINAL %.2fs wavBytes=%d",
                         generation, chunk.seconds, chunk.wav.count))
            if await dispatchFinalChunk(chunk, cloud: cloud, generation: generation) {
                dispatched += 1
            }
        }

        // Release-drain flush. The trailing-silence gate needs the room to fall below the
        // RMS threshold for 0.6 s; an ambient floor above the threshold (the measured
        // failure: ≈0.014 vs 0.01) means it NEVER opens and every session ends with
        // finalChunks=0. The hotkey release *is* the utterance boundary, so once the drain
        // completes the main actor requests this flush and cancels the loop; the flush runs
        // here — the same single-consumer context that calls takeChunk(), never the main
        // actor, never the audio thread — and its chunk goes through the exact same gates
        // (`dispatchFinalChunk` → `noteFinalChunk`, generation checked inside the MainActor
        // hop) as a silence-finalized one.
        if flushRequest.consume() {
            if let chunk = pipeline.flush() {
                trace(String(format: "FLUSH[%d]: forced final %.2fs wavBytes=%d",
                             generation, chunk.seconds, chunk.wav.count))
                if await dispatchFinalChunk(chunk, cloud: cloud, generation: generation) {
                    dispatched += 1
                }
                finals += 1
            } else {
                trace("FLUSH[\(generation)]: nothing to flush — below minimum buffered speech")
            }
        }

        trace("LOOP[\(generation)]: chunk loop ended — polls=\(polls) chunks=\(chunks) "
            + "finals=\(finals) cloudDispatched=\(dispatched) cancelled=\(Task.isCancelled)")
    }

    /// Route one finalized chunk through the cloud gate and, when it passes, dispatch the
    /// cloud pass. Shared by the polling loop and the release-drain flush so both travel
    /// the exact same path — same anti-hallucination gate, same single-request rule, same
    /// generation check inside the MainActor hop. Returns true when a request was sent.
    ///
    /// ONE MainActor job does gate + create + register, in that order, before returning.
    /// Registration used to be a second, later `MainActor.run`; a request that failed
    /// instantly (e.g. offline: the detached task starts on another thread and its
    /// completion hop is enqueued at once) could land on the MainActor BETWEEN the two
    /// jobs — `applyCloudFailure` cleared a still-nil `cloudTask` (a no-op) and the late
    /// register then stored the already-finished task, which nothing would ever clear.
    /// From that moment the one-in-flight gate refused every chunk for the life of the
    /// process. With create-and-register inside the same synchronous MainActor job, any
    /// completion hop is necessarily a LATER MainActor job and always finds its task
    /// registered.
    nonisolated private func dispatchFinalChunk(_ chunk: AudioPipeline.Chunk,
                                                cloud: any CorrectionProvider,
                                                generation: Int) async -> Bool {
        let wav = chunk.wav
        // Extracted out here beside `wav`, for the same reason `wav` is: the MainActor
        // closure below then captures two Sendable values instead of the chunk itself,
        // which is the Sendable question this function already went out of its way to
        // sidestep. This is the audio length the spend ledger counts.
        let seconds = chunk.seconds
        return await MainActor.run { [weak self] () -> Bool in
            guard let self else { return false }
            // Gate (generation stale-guard included) — unchanged semantics, now simply
            // called in the same job that will register the task it approves.
            guard let handle = self.noteFinalChunk(generation: generation),
                  handle.runCloud else { return false }
            // Immutable copies of the MainActor-taken snapshot; String and [String] are
            // Sendable, so this is the whole cross-isolation story for the typed span and
            // the glossary (`activeKeyterms`, read here and nowhere off the main actor).
            let typedSpan = handle.typedSpan
            let typedSpanSeq = handle.typedSpanSeq
            let utteranceID = handle.id
            let keyterms = self.activeKeyterms
            let task = Task.detached { [weak self] in
                guard let self else { return }
                await self.cloudPass(wav: wav, utteranceID: utteranceID, typedSpan: typedSpan,
                                     typedSpanSeq: typedSpanSeq,
                                     generation: generation, client: cloud,
                                     keyterms: keyterms)
            }
            self.registerCloudTask(task, utteranceID: utteranceID, generation: generation,
                                   seconds: seconds)
            return true
        }
    }

    /// Decide, on the main actor, whether this finalized utterance may reach the cloud.
    ///
    /// ── Why there is a gate at all ────────────────────────────────────────────────────
    /// Routing hallucinated text through the cloud pass *launders* it. A speech model fed
    /// silence or room tone does not return nothing — it invents fluent, plausible Thai. If
    /// that chunk were forwarded, the cloud model would transcribe the same silence and
    /// return something similar, the two would appear to agree, and the UI would then
    /// present invented text as cloud-confirmed. The user's own ears would be the only thing
    /// left to catch it. A confident wrong answer is strictly worse than no answer. (This
    /// gate long predates Gemini and is provider-independent by design — it is a statement
    /// about how speech models behave on silence, not about whose model it is.)
    ///
    /// So an utterance only reaches the cloud when two independent witnesses agree there was
    /// speech:
    ///   1. AudioPipeline's own speech accounting. A chunk is only marked `isFinal` after at
    ///      least `minFinalSpeechSeconds` of above-threshold audio — the silence-ended branch
    ///      checks `speech >= minFinalSpeech` and drops the chunk otherwise, and the
    ///      length-cap branch can only be reached after speech, because pre-roll trimming
    ///      keeps an idle mic from ever accumulating 25 s of room tone. `chunk.isFinal` IS
    ///      the audio-side gate.
    ///   2. The on-device recogniser produced non-empty text for this utterance.
    ///
    /// Either witness alone is forgeable. Together they are not.
    private func noteFinalChunk(generation: Int) -> FinalizedUtterance? {
        // Stale-guard, checked INSIDE the MainActor hop — never before it.
        guard generation == captureGeneration else {
            trace("noteFinalChunk: generation \(generation) is stale (now \(captureGeneration)); dropped")
            return nil
        }
        lifetime.finalChunks += 1; thisCapture.finalChunks += 1

        // Snapshot the typed-span ledger for THIS chunk and reset it — on the MainActor,
        // which is the only place the ledger is ever touched. The reset happens for EVERY
        // final chunk, even ones the gates below refuse to send: the audio span has
        // passed either way, and letting its span leak into the next chunk's snapshot
        // would make a later correction replace text that belongs to different audio.
        let typedSpan = typedSinceLastChunk
        typedSinceLastChunk = ""

        let heard = currentOnDeviceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else {
            lifetime.cloudSkipped += 1; thisCapture.cloudSkipped += 1
            trace("CLOUD GATE: final chunk with no on-device text — not sent "
                + "(silence-hallucination guard)")
            return nil
        }
        // Both the SELECTED kind and the kind this session's loop was built for: the loop
        // dispatches to the provider captured in `beginCapture`, so after a mid-session
        // switch (say gemini -> local, "audio stays on this Mac") the selected kind and
        // the provider that would actually receive the audio disagree until the next
        // capture. Refusing here is what a mid-session toggle OFF did at HEAD (main.swift
        // 4838, `guard cloudEnabled, cloudAvailable`): the send stops at this gate now,
        // and the new provider takes effect at the next capture (`selectCorrection`).
        guard correctionEnabled, correctionKind == activeCorrectionKind else {
            let why = !correctionEnabled
                ? correctionGateState
                : "changed mid-session (\(activeCorrectionKind.rawValue) -> "
                    + "\(correctionKind.rawValue)); takes effect at the next capture"
            trace("CLOUD GATE: pass is \(why); not sent")
            return FinalizedUtterance(id: 0, runCloud: false, typedSpan: "", typedSpanSeq: 0)
        }
        if let running = cloudTask {
            // One request in flight at a time — but a HUNG request must not hold the gate
            // shut for its full timeout. Every chunk refused here has already had its
            // ledger snapshot consumed (above), so its span is permanently uncorrectable;
            // a dropped network could silently do that to every chunk for up to a minute.
            // Younger than `cloudSupersedeAfterSeconds` → normal refusal (a healthy round
            // trip is still likely to land). Older → presumed hung: cancel it and let
            // THIS chunk through. Cancellation routes to `applyCloudFailure(cancelled:
            // true)`, which does not count an error; the slot is de-registered here, and
            // the late hop's id-guarded clear leaves the new registration alone.
            let age = cloudTaskStartedAt.map { Date().timeIntervalSince($0) }
            guard let age, age > cloudSupersedeAfterSeconds else {
                lifetime.cloudSkipped += 1; thisCapture.cloudSkipped += 1
                trace("CLOUD GATE: a request is already in flight; this utterance is not sent")
                return FinalizedUtterance(id: 0, runCloud: false, typedSpan: "", typedSpanSeq: 0)
            }
            running.cancel()
            cloudTask = nil
            cloudTaskStartedAt = nil
            trace(String(format: "CLOUD GATE: in-flight request is %.1f s old — presumed hung; "
                       + "cancelled and superseded by the new chunk", age))
        }

        let id = nextUtteranceID
        nextUtteranceID += 1
        lastCloudUtteranceID = id
        hud.set(.correcting(heard))
        hud.show()
        return FinalizedUtterance(id: id, runCloud: true, typedSpan: typedSpan, typedSpanSeq: utteranceSeq)
    }

    private func registerCloudTask(_ task: Task<Void, Never>, utteranceID: Int, generation: Int,
                                   seconds: Double) {
        guard generation == captureGeneration, utteranceID == lastCloudUtteranceID else {
            task.cancel()
            trace("registerCloudTask: superseded before it started; cancelled")
            return
        }
        cloudTask = task
        cloudTaskStartedAt = Date()   // drives the supersede rule in noteFinalChunk
        lifetime.cloudSent += 1; thisCapture.cloudSent += 1

        // Seconds and requests are counted HERE: past the supersede guard above (which
        // cancels before the request ever reaches the wire, so that path is honestly not a
        // dispatch), and before any result can come back. See `cloudAudioSecondsSent` for
        // why the completion side is the wrong place — the id-guards there discard
        // superseded results the provider has already served and can already have billed.
        //
        // TOKENS ARE NOT COUNTED HERE, and cannot be: the billing unit only exists in a
        // response. `applyCloudResult` adds them.
        //
        // Written through to UserDefaults on every dispatch rather than at terminate: this
        // app is a menubar agent that gets force-quit, and a lifetime counter that only
        // survives a graceful exit is not a lifetime counter.
        cloudAudioSecondsSent += seconds
        cloudRequestsSent += 1
        UserDefaults.standard.set(cloudAudioSecondsSent, forKey: Self.cloudSecondsDefaultsKey)
        UserDefaults.standard.set(cloudRequestsSent, forKey: Self.cloudRequestsDefaultsKey)
        trace(String(format: "SPEND: +%.1f s audio → %.0f s / %d req lifetime",
                     seconds, cloudAudioSecondsSent, cloudRequestsSent))
    }

    /// One cloud round trip for one finalized utterance.
    ///
    /// `nonisolated` and only ever entered from `Task.detached` — a multi-second HTTP request
    /// has no business on the main actor, and `any CorrectionProvider` is `Sendable`
    /// precisely so it can be used this way. Every UI touch hops explicitly and the
    /// generation is checked on the far side of that hop. `keyterms` arrives as a value
    /// captured in `dispatchFinalChunk`'s MainActor hop: this function reads no main-actor
    /// state, which `-swift-version 6` would refuse anyway.
    ///
    /// A failure here is never allowed to disturb anything: the on-device text is already
    /// typed and stays exactly as it is. The lines keep the old `GEMINI[…]` shape under a
    /// provider-neutral prefix, with the provider named on every one.
    nonisolated private func cloudPass(wav: Data, utteranceID: Int, typedSpan: String,
                                       typedSpanSeq: UInt64, generation: Int,
                                       client: any CorrectionProvider,
                                       keyterms: [String]) async {
        let provider = client.displayName
        trace("CORRECTION[\(generation)] \(provider): sending utterance #\(utteranceID) — "
            + "\(wav.count) wav bytes, \(keyterms.count) keyterms, audio "
            + (client.sendsAudioOffDevice ? "LEAVES this Mac" : "stays on this Mac"))
        do {
            let result = try await client.transcribe(wav: wav, keyterms: keyterms)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // `audioTokens`, not the old `langProb`: this is the EXACT unit Gemini bills,
            // straight from the response, so the one number worth carrying per request is
            // the one that costs money. A confidence figure was interesting; this is
            // actionable, and it is the only place it can ever be observed. Local whisper
            // reports 0 — nothing is billed and nothing is counted.
            trace("CORRECTION[\(generation)] \(provider): utterance #\(utteranceID) OK — "
                + String(format: "%.0f ms, %d chars, audioTokens=%d",
                         result.elapsedMS, text.count, result.audioTokens))
            await MainActor.run { [weak self] in
                self?.applyCloudResult(text: text, utteranceID: utteranceID,
                                       typedSpan: typedSpan,
                                       typedSpanSeq: typedSpanSeq,
                                       elapsedMS: result.elapsedMS,
                                       audioTokens: result.audioTokens,
                                       generation: generation, provider: provider)
            }
        } catch {
            let ns = error as NSError
            let wasCancelled = error is CancellationError
                || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
            let d = describeCloudError(error)
            trace("CORRECTION[\(generation)] \(provider): utterance #\(utteranceID) FAILED "
                + "(cancelled=\(wasCancelled)) — \(d.summary)")
            await MainActor.run { [weak self] in
                self?.applyCloudFailure(d.summary, utteranceID: utteranceID,
                                        generation: generation, cancelled: wasCancelled,
                                        httpStatus: d.httpStatus, provider: provider)
            }
        }
    }

    private func applyCloudResult(text rawText: String, utteranceID: Int, typedSpan: String,
                                  typedSpanSeq: UInt64,
                                  elapsedMS: Double, audioTokens: Int, generation: Int,
                                  provider: String) {
        // ── Token ledger, ABOVE EVERY GUARD BELOW, deliberately ──────────────────────
        // A response exists, therefore Google served it, therefore it was billed — and
        // none of that is undone by this app deciding the text is stale. The stale-guards
        // a few lines down discard superseded results, and counting after them would
        // under-report exactly when usage is highest, which is the same mistake
        // `cloudAudioSecondsSent` documents at length and avoids by counting at dispatch.
        // Tokens cannot be counted at dispatch (the figure does not exist yet), so this is
        // as early as the count can possibly happen. See `cloudAudioTokensSent`.
        if audioTokens > 0 {
            cloudAudioTokensSent += audioTokens
            UserDefaults.standard.set(cloudAudioTokensSent, forKey: Self.cloudTokensDefaultsKey)
            trace("SPEND: +\(audioTokens) audio tokens → \(cloudAudioTokensSent) lifetime")
        }

        // Settle the one-in-flight gate ONLY when this hop belongs to the task that is
        // actually registered. A hung request superseded in `noteFinalChunk` was
        // cancelled and de-registered there, and by the time its late hop lands here a
        // NEWER task may occupy the slot — an unconditional clear would re-open the gate
        // with that request still in flight. Utterance ids are unique per dispatch, so
        // the id match identifies the registered task exactly.
        if utteranceID == lastCloudUtteranceID {
            cloudTask = nil
            cloudTaskStartedAt = nil
        }
        // Stale-guard, checked INSIDE the MainActor hop.
        guard generation == captureGeneration, utteranceID == lastCloudUtteranceID else {
            trace("applyCloudResult: superseded (generation \(generation) vs \(captureGeneration), "
                + "utterance \(utteranceID) vs \(lastCloudUtteranceID)); discarded")
            return
        }
        // A request that came back at all proves the quota was not exhausted and the rate
        // limit was not shut, so any 429 run ends here — "2 CONSECUTIVE 429s" has to mean
        // consecutive, and a success sitting between two of them means they were not. Reset
        // before the empty-result branch below, which is an HTTP success whatever it says
        // about the audio. Cheap insurance against auto-disabling a working account.
        consecutive429s = 0

        lastCloudLatencyMS = elapsedMS
        guard !rawText.isEmpty else {
            // NOT an error, and deliberately not counted as one. `GeminiClient` documents
            // an empty transcript as a legitimate "heard nothing" — Google returns it by
            // design for a silent or near-silent chunk, with `finishReason: STOP` and a
            // normal bill — so counting it here inflated `errors=` in the menu and the
            // summary for every capture that happened to end on a quiet chunk, and made a
            // healthy account look like it was failing. Counted separately instead, so the
            // rate stays visible without being mistaken for breakage.
            lifetime.cloudEmpty += 1; thisCapture.cloudEmpty += 1
            lastOutcome = "\(provider) heard nothing in that span; on-device text kept"
            trace("CORRECTION (\(provider)): empty result (silence — not counted as an "
                + "error); on-device text kept")
            settleAfterCloud()
            return
        }

        // ONE string from here down, which is why this is not done at the
        // `replaceRecentText` call the way the newline work was first scoped. Normalising
        // only the argument to the replace would put a string in the document that differs
        // from the one recorded in `typedSinceLastChunk` below, shown in the HUD, and
        // offered by "Copy cloud correction" — and the NEXT chunk's span search would then
        // hunt the document for text that was never typed, which is the same permanent
        // desync the normalisation exists to prevent. The cloud pass returns punctuated
        // prose and is the realistic source of a line break here (this was true of fal and
        // is no less true of Gemini); the on-device pass has never produced one. The
        // parameter is `rawText` rather than a shadow because Swift forbids using a name
        // earlier in a scope than the local declaration that shadows it, and the
        // empty-result guard above must test what the cloud actually sent.
        let text = normalizeForInjection(rawText, kind: "cloud")
        lastTranscript = text

        if text == injectedForUtterance {
            // Nothing to change: the cloud agrees with what is already in the target app.
            // This is the ONLY case in which "corrected" is a true statement, so it is the
            // only case that gets to say it.
            lifetime.cloudApplied += 1; thisCapture.cloudApplied += 1
            unappliedCloudText = ""
            lastOutcome = "\(provider) confirmed the typed text "
                + String(format: "(%.0f ms)", elapsedMS)
            trace("CORRECTION (\(provider)): result matches the typed text exactly "
                + String(format: "(%d chars, %.0f ms)", text.count, elapsedMS))
            hud.set(.corrected(text))
            hud.show()
            refreshMenu()
            return
        }

        // ── Live auto-correction ─────────────────────────────────────────────────────
        // The cloud text differs from what the live pass typed. `typedSpan` is the ledger
        // snapshot taken when this chunk was cut: exactly the characters injected for this
        // audio span. `replaceRecentText(find:with:)` rewrites the LAST occurrence of that
        // span strictly before the caret and restores the caret — it verifies the span is
        // really there before touching anything, so a moved caret or changed focus fails
        // the match and degrades to the copyable fallback below, never to corrupted text
        // in someone else's document. ".corrected" as an APPLIED correction is announced
        // ONLY when the replacement actually happened — announcing a correction that did
        // not happen is the same class of lie as laundering a hallucination.
        var repairFailure: String?
        if !autoCorrectEnabled {
            repairFailure = "auto-correct is off; cloud text shown, not injected"
        } else if typedSpan.count < 10 {
            // Too short to match safely (replaceRecentText refuses < 3 graphemes anyway;
            // refusing here keeps the reason honest in the trace).
            // 10 graphemes, not 3: measured in production, a 3-char span ("การ", "ครับ")
            // occurs all over Thai prose -- one such match replaced CORRECT text. A span
            // shorter than a phrase cannot be located safely, period.
            // KEPT AT 10 FOR THE LOCAL PROVIDER, and the cost is stated: the user's own
            // report ("I say time and it does not appear") is a short utterance — `ขอ
            // time` alone types as five or six clusters — so v1 corrects such a word only
            // inside an utterance of ten clusters or more; a shorter one is shown in the
            // HUD and offered under "Copy correction", not typed. Lowering the floor
            // safely needs a caret-relative match in `TextInjector`, not a smaller number.
            repairFailure = "typed span too short to match safely (\(typedSpan.count) chars)"
        } else if injector.secureInputActive() {
            // Same policy as the live path: never touch a secure field. This is a quiet
            // refusal to auto-apply, not a broken session — no error flash.
            lifetime.secureInputRefusals += 1; thisCapture.secureInputRefusals += 1
            repairFailure = "secure input active; cloud text shown, not injected"
        } else if text.count * 2 < typedSpan.count || text.count > typedSpan.count * 3 {
            // Size sanity: the cloud text should be the same utterance, give or take
            // punctuation and corrections. A wildly different length means the span and
            // the audio chunk drifted apart (the ledger lags the audio cut) -- replacing
            // would swap in text belonging to a different stretch of speech.
            repairFailure = "cloud text size mismatch (span \(typedSpan.count) vs cloud \(text.count) chars)"
        } else if let why = CorrectionScript.refusal(typed: typedSpan, correction: text) {
            // ── SCRIPT SANITY ─────────────────────────────────────────────────────────
            // The size gate above cannot see a hallucination that keeps the length:
            // whisper's Vietnamese for the `check` clip (`chui, chết, hay nòi`) was the
            // same length as the Thai it would have replaced. `CorrectionScript` says
            // what is measured and what the two tests are. Refused BEFORE the exact-
            // match branch on purpose: an unreadable script is never "confirmed".
            repairFailure = "script sanity refused it — \(why)"
        } else if text == typedSpan {
            // The cloud agrees with exactly what was typed for this chunk.
            lifetime.cloudApplied += 1; thisCapture.cloudApplied += 1
            unappliedCloudText = ""
            lastOutcome = "\(provider) confirmed the typed text "
                + String(format: "(%.0f ms)", elapsedMS)
            trace("CORRECTION (\(provider)): result matches the typed span exactly "
                + String(format: "(%d chars, %.0f ms)", text.count, elapsedMS))
            hud.set(.corrected(text))
            hud.show()
            refreshMenu()
            return
        } else {
            repairFailure = injector.replaceRecentText(find: typedSpan, with: text)
        }

        if repairFailure == nil {
            // The document now reads `text` where `typedSpan` used to be.
            lifetime.cloudApplied += 1; thisCapture.cloudApplied += 1
            unappliedCloudText = ""
            lastOutcome = "\(provider) corrected the typed text "
                + String(format: "(%.0f ms)", elapsedMS)
            trace("CORRECTION (\(provider)): auto-corrected span "
                + "(\(typedSpan.count) -> \(text.count) chars)")

            // ── Bookkeeping: the recogniser-side mark is NOT touched here ───────────
            // `injectedForUtterance` is consumed by `deliver()` against RECOGNIZER text,
            // so the mark must stay in recognizer-text units at all times. The cloud text
            // is a document-side rewrite in the cloud model's own units: it adds spaces
            // and punctuation, so the strings differ. Folding it into the mark (as this block
            // once did) desynchronised a still-open utterance: later partials first
            // compared shorter than the inflated mark and were skipped (typing froze),
            // and once they outgrew it, `dropFirst(mark.count)` cut into genuinely new
            // speech (characters eaten).
            //
            // `deliver()` no longer consumes the mark by COUNT — it diffs it by CONTENT,
            // in grapheme clusters, and a mismatch now makes it DELETE from the user's
            // document (see the block in `deliver`). That makes this rule strictly
            // stronger, not weaker: cloud text in the mark would no longer merely
            // desynchronise a count, it would present the next partial with a common
            // prefix computed against text the recogniser never said, and the repair
            // would delete correct characters to "fix" them. The document-side effect of
            // the replace is recorded where document units live — the
            // `typedSinceLastChunk` ledger patch just below.
            // NEVER assign cloud text into `injectedForUtterance`.
            //
            // What we DO record is ownership: the cloud has rewritten this utterance's
            // typed text, and a late on-device FINAL must not "reconcile" it back to
            // the recogniser's worse text. Ownership only when the span was snapshotted
            // under the utterance still on screen — after a boundary, a coincidental
            // suffix match belongs to a NEWER utterance whose FINAL must not be gagged
            // (`.listening` owns the mark there, and the document replace was already
            // verified unambiguous by TextInjector). `hasSuffix` covers the
            // whole-utterance case too: a string is its own suffix.
            if typedSpanSeq == utteranceSeq, injectedForUtterance.hasSuffix(typedSpan) {
                cloudOwnsUtterance = true
            }

            // The ledger was snapshot-and-reset at dispatch, so the replaced span should
            // never still be in `typedSinceLastChunk` — but if it somehow is, a future
            // snapshot would ask the cloud to "correct" text this replace already rewrote.
            // Guard: make the ledger reflect the document.
            if !typedSinceLastChunk.isEmpty,
               let stale = typedSinceLastChunk.range(of: typedSpan, options: [.backwards, .literal]) {
                typedSinceLastChunk.replaceSubrange(stale, with: text)
            }

            hud.set(.corrected(text))
            hud.show()
            refreshMenu()
            return
        }

        // The better text could not be swapped in. Say what actually happened, and put the
        // text one click away in the menubar. Never follow the refusal with blind backspaces.
        lifetime.cloudUnapplied += 1; thisCapture.cloudUnapplied += 1
        unappliedCloudText = text
        lastOutcome = "\(provider) text ready but NOT typed — use “Copy correction”"
        trace("CORRECTION (\(provider)): result differs from the typed text "
            + String(format: "(correction %d chars vs typed %d chars, %.0f ms); "
                        + "NOT applied — ",
                     text.count, injectedForUtterance.count, elapsedMS)
            + (repairFailure ?? "unknown reason"))
        // A neutral offer, not an error — NO error flash: either the app chose not to
        // inject (toggle off, secure input, span too short) or replaceRecentText refused
        // and left the document untouched. Reporting the cloud's better text as a failure
        // would be the same class of lie as announcing a correction that did not happen.
        hud.set(.corrected(text))
        hud.show()
        refreshMenu()
    }

    private func applyCloudFailure(_ summary: String, utteranceID: Int,
                                   generation: Int, cancelled: Bool, httpStatus: Int?,
                                   provider: String) {
        // Id-guarded for the same reason as applyCloudResult: a superseded request's
        // cancellation hop must not clear the NEW task registered after it.
        if utteranceID == lastCloudUtteranceID {
            cloudTask = nil
            cloudTaskStartedAt = nil
        }
        guard generation == captureGeneration, utteranceID == lastCloudUtteranceID else { return }
        if !cancelled { lifetime.cloudErrors += 1; thisCapture.cloudErrors += 1 }
        lastOutcome = cancelled
            ? "\(provider) cancelled; on-device text kept"
            : "\(provider) failed — \(summary). On-device text kept."

        // ── HTTP 429: quota or rate limit ────────────────────────────────────────────
        // 429, NOT 402. fal signalled "out of credit" with a 402; Google never sends one,
        // so the 402 branch this replaces would have been dead code wearing the costume of
        // a safety net — the pass would have gone on uploading audio into a quota wall
        // forever. See `max429sBeforeAutoDisable` for why two consecutive 429s is a weaker
        // signal than two consecutive 402s were, and why the rule is kept at two anyway.
        //
        // Inside the `!cancelled` arm, both branches of it. A cancellation is not evidence
        // about the quota either way, so it must neither increment NOR reset: if a
        // supersede (which cancels — see `noteFinalChunk`) reset the run, two genuine 429s
        // straddling one supersede would never trip the rule, and on a dead network that
        // is the likeliest ordering there is.
        // GEMINI ONLY: a quota is a property of the Google account. Local whisper-server
        // has no 429 to send, and if a status of that number ever did arrive from
        // loopback it would not mean "quota", so it must neither count here nor produce
        // the "hit Gemini quota" wording.
        if !cancelled, correctionKind == .gemini {
            if httpStatus == 429 {
                consecutive429s += 1
                if consecutive429s >= Self.max429sBeforeAutoDisable, correctionEnabled {
                    // SESSION-ONLY: `cloudPassDefaultsKey` IS DELIBERATELY NOT WRITTEN.
                    // That stored value records the user's opt-in, and hitting a quota is
                    // not a change of mind. After the quota resets and a relaunch the pass
                    // must come back exactly as they left it; writing `false` here would
                    // revoke a preference on the app's own authority and leave no trace of
                    // having done it. This matters MORE than it did under fal: a rate limit
                    // clears by itself in a minute, so a persisted opt-out would outlive the
                    // condition that caused it by an arbitrary margin. `correctionEnabled`
                    // is computed from this reason, so setting it IS the switch-off.
                    cloudAutoDisabledReason = "hit Gemini quota"
                    trace("CLOUD PASS AUTO-DISABLED: \(Self.max429sBeforeAutoDisable) consecutive "
                        + "HTTP 429 (quota or rate limit); re-enable from the menubar — "
                        + "check quota at \(googleQuotaURL)")
                    // Overwrites the generic failure line set just above, on purpose: the
                    // pass turning itself off is the more important half of this event.
                    lastOutcome = "Correction auto-disabled — hit Gemini quota"
                    refreshMenu()
                }
            } else {
                consecutive429s = 0
            }
        }

        settleAfterCloud()
    }

    /// After the cloud pass settles, put the HUD back to whatever the truth now is without
    /// clobbering a live session or an error the user has not seen yet.
    private func settleAfterCloud() {
        guard !utteranceDiverged, injectionBlockedReason == nil else {
            refreshMenu()
            return
        }
        if isCapturing {
            hud.set(.transcribing(currentOnDeviceText.isEmpty ? hudIdleBody : currentOnDeviceText))
        } else {
            showIdleHUD()
        }
        refreshMenu()
    }

    // MARK: - Usage read-outs
    //
    // Two menu lines and nothing else. THERE IS NO NETWORK CALL IN THIS SECTION — under fal
    // there was one (a billing probe, firewalled from dictation, with its own task and its
    // own rate limits), and the rule it kept is now enforced by construction instead of by
    // discipline: Google exposes no key-readable balance, so there is nothing to ask and no
    // way for a billing endpoint to cost the user a character of typed text.

    /// Titles for the two usage lines. Split out of `refreshMenu` because it is a formatting
    /// job with its own rules, and inlining it would bury the dictation read-outs that matter
    /// considerably more.
    ///
    /// Both lines are driven by `cloudAudioTokensSent`/`cloudRequestsSent` — the same
    /// counters, never a second copy — so the clickable line and the read-out can never
    /// disagree about the same launch.
    private func refreshCreditItems() {
        // Hidden until there IS usage, and hidden on the same variable it reports, or the
        // line would render "Usage: 0 audio tokens this Mac" and read as a broken fetch.
        creditItem.isHidden = cloudAudioTokensSent == 0
        if cloudAudioTokensSent > 0 {
            creditItem.isEnabled = true
            creditItem.title = "Usage: \(Self.formattedCount(cloudAudioTokensSent)) audio tokens this Mac"
            // The title says "this Mac" because that is all it can honestly claim; the
            // tooltip says where the account-wide truth lives, which is also where the click
            // goes.
            creditItem.toolTip = "Counted locally by MicTest. Your account's real usage and "
                + "quota live at \(googleQuotaURL) — click to open."
        }

        // Hidden until there is something to report; see `buildStatusItem`.
        spendItem.isHidden = cloudRequestsSent == 0
        if cloudRequestsSent > 0 {
            spendItem.title = String(format: "Sent from this Mac: %d req, %.1f min, ",
                                     cloudRequestsSent, cloudAudioSecondsSent / 60)
                + "\(Self.formattedCount(cloudAudioTokensSent)) audio tokens"
            // NO DOLLAR ESTIMATE LIVES HERE ANY MORE. The old title led with "~$0.42",
            // derived from fal's $0.008/audio-minute plus a 30% keyterms premium. That price
            // belonged to a vendor this app no longer calls, and the honest replacement for a
            // wrong number is no number — not a guessed Gemini price dressed in the same
            // tilde. The tokens beside it are the exact billing unit and are not an estimate
            // at all; converting them to money is Google's job, on Google's current rates.
            spendItem.toolTip = "Gemini bills by audio token; see Google AI Studio for "
                + "current rates and your quota."
        }
    }

    /// `48900` → `48,900`.
    ///
    /// Grouped, because a six-figure token count is unreadable otherwise, and this number is
    /// meant to be compared by eye against the figure Google's own console shows. Deliberately
    /// NOT the user's locale: under a Thai locale a localised formatter would render the
    /// count in a shape that console never uses, which defeats the one job the line has.
    /// A formatter per call rather than a shared static — this runs at menu-refresh rate, not
    /// in a loop, and a mutable `NumberFormatter` stored on a type is a Swift 6 concurrency
    /// problem bought for nothing.
    private nonisolated static func formattedCount(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Menu actions

    @objc private func toggleDictation() {
        dictationEnabled.toggle()
        trace("MENU: dictation -> \(dictationEnabled ? "on" : "off")")
        if !dictationEnabled {
            wantsDictation = false
            finishCapture(reason: "dictation switched off")
        }
        showIdleHUD()
        refreshMenu()
    }

    /// The submenu's entries paired with their kinds, in menu order.
    private var correctionEntries: [(CorrectionProviderKind, NSMenuItem)] {
        [(.off, correctionOffItem), (.local, correctionLocalItem),
         (.gemini, correctionGeminiItem)]
    }

    /// Resolve `correctionKind` at launch: stored, migrated, or computed — the rule is on
    /// the property. Returns a phrase for the launch trace saying which, or nil for an
    /// ordinary stored choice.
    private func resolveCorrectionKind() -> String? {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Self.correctionProviderDefaultsKey) {
            if let stored = CorrectionProviderKind(rawValue: raw) {
                correctionKind = stored
                return nil
            }
            // A string nobody recognises: the privacy-preserving reading, and say so.
            correctionKind = .off
            return "stored value \"\(raw)\" not recognised; off"
        }
        if d.object(forKey: Self.cloudPassDefaultsKey) != nil {
            let legacy = d.bool(forKey: Self.cloudPassDefaultsKey)
            correctionKind = legacy ? .gemini : .off
            d.set(correctionKind.rawValue, forKey: Self.correctionProviderDefaultsKey)
            return "migrated from cloudPassEnabled=\(legacy) -> \(correctionKind.rawValue);"
                + " new key written, old key not consulted again"
        }
        correctionKind = localCorrectionConfigured ? .local : .off
        return "default — nothing stored; local when binary and model exist, else off;"
            + " not written"
    }

    @objc private func selectCorrection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let next = CorrectionProviderKind(rawValue: raw) else { return }
        let previous = correctionKind
        guard next != previous else { return }
        // Refuse a dead provider rather than select it: a toggle that silently picks an
        // engine that cannot run presents as "corrections just stopped".
        switch next {
        case .off: break
        case .local: guard localCorrectionConfigured else { return }
        case .gemini: guard geminiKeyAvailable else { return }
        }
        correctionKind = next
        let d = UserDefaults.standard
        d.set(next.rawValue, forKey: Self.correctionProviderDefaultsKey)
        // The legacy key says "gemini or not", never "on or not" — see `correctionKind`.
        d.set(next == .gemini, forKey: Self.cloudPassDefaultsKey)
        // Every deliberate change clears the auto-disable memory. On the way back to a
        // provider that is load-bearing: without it, one stale 429 from before the quota
        // reset plus one new failure would trip the rule again immediately and the pass
        // would appear to refuse to stay on. On the way OFF it is simply true — the reason
        // exists to explain an off state the user did not choose, and this one they did.
        cloudAutoDisabledReason = nil
        consecutive429s = 0
        trace("MENU: correction provider \(previous.rawValue) -> \(next.rawValue) "
            + "(model=\(correctionModelName(for: next)); audio "
            + (next == .gemini ? "is sent to Google" : "stays on this Mac") + ")")
        // The running session's loop keeps the provider it started with
        // (`activeCorrectionKind`); `noteFinalChunk` refuses every later send of that
        // session because the kinds now differ. A local server it was using is stopped
        // when that session ends (`finishCapture` → `armLocalIdleStop`), not now.
        if previous == .local, !isCapturing, drainTimer == nil, !localDictationEnabled, finalQueue.pendingCaptureCount == 0 {
            stopLocalServer(reason: "provider changed to \(next.rawValue)")
        }
        startLocalServer(reason: "provider selected")
        // The chunk loop is created (or skipped) once, at session start, from the state
        // read there. `isCapturing && chunkTask == nil` identifies exactly "this session
        // started realtime-only"; `activeCorrectionKind != next` is a session whose loop
        // is bound to the previous provider. Say so, or the missing activity looks like
        // a bug.
        if correctionEnabled && isCapturing && chunkTask == nil {
            trace("MENU: correction pass enabled mid-session — takes effect at the NEXT "
                + "session (tap \(defaultHotkeyName) to stop, then again to start)")
        } else if correctionEnabled && isCapturing && activeCorrectionKind != next {
            trace("MENU: correction provider changed mid-session — this session's "
                + "remaining utterances are not sent; \(next.rawValue) takes effect at "
                + "the NEXT session (tap \(defaultHotkeyName) to stop, then again to start)")
        }
        refreshMenu()
    }

    // MARK: - Local server lifecycle

    /// Chain `operation` after whatever the chain is already doing. See `serverLifecycle`.
    private func enqueueServerLifecycle(isStart: Bool,
                                        _ operation: @escaping @Sendable () async -> Void) {
        let previous = serverLifecycle
        serverLifecycleIsStart = isStart
        serverLifecycle = Task {
            await previous?.value
            await operation()
        }
    }

    /// Start (or re-verify) the local server and warm it, then report ONE outcome. No
    /// progress callback: `ensureReady(progress:)` fires from the actor twice a second,
    /// and feeding the HUD from it would need a Task per call — the unordered shape
    /// `RecognizerEventBox` bans, where a late `.loadingModel` lands after `.ready`. The
    /// terminal outcome is enough for the trace and the menu. A no-op unless `.local` is
    /// selected and configured, so every caller may call it unconditionally.
    private func startLocalServer(reason: String) {
        guard (correctionKind == .local && localCorrectionConfigured) || localDictationEnabled else { return }
        localIdleStopTask?.cancel()
        localIdleStopTask = nil
        localServerRequested = true
        let manager = WhisperServerManager.shared
        enqueueServerLifecycle(isStart: true) { [weak self] in
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let url = try await manager.ensureReady()
                let readyMS = Self.milliseconds(started.duration(to: clock.now))
                let ownership = await manager.currentOwnership
                let warm = await manager.warmUp()
                await MainActor.run {
                    self?.noteLocalServerReady(url: url, readyMS: readyMS,
                                               ownership: ownership, warm: warm,
                                               reason: reason)
                }
            } catch {
                await MainActor.run {
                    self?.noteLocalServerFailed(error, reason: reason)
                }
            }
        }
    }

    private func noteLocalServerReady(url: URL, readyMS: Double,
                                      ownership: WhisperServerManager.Ownership,
                                      warm: WhisperServerManager.WarmUpOutcome,
                                      reason: String) {
        let port = url.port ?? WhisperServerManager.defaultPort
        let warmText: String
        switch warm {
        case .warmed(let seconds):
            warmText = String(format: "warmed in %.0f ms", seconds * 1000)
        case .alreadyWarm: warmText = "already warm"
        case .skipped(let why): warmText = "warm-up skipped — \(why)"
        case .failed(let why): warmText = "warm-up FAILED — \(why)"
        }
        localServerStatus = "ready on port \(port) (\(ownership))"
        trace(String(format: "correction: local server ready port=%d in %.0f ms ",
                     port, readyMS)
            + "ownership=\(ownership)"
            + (ownership == .adopted
                ? " (not started by this app: model and -l unverified; not stopped by it)"
                : "")
            + (ownership == .reclaimed
                ? " (orphan of an earlier run of this app, per its pidfile; stopped by it)"
                : "")
            + "; \(warmText) [\(reason)]")
        forwardManagerNotes()
        refreshMenu()
    }

    private func noteLocalServerFailed(_ error: Error, reason: String) {
        if error is CancellationError {
            trace("correction: local server start cancelled [\(reason)]")
            return
        }
        let text = String(describing: error)
        localServerStatus = "FAILED — \(text)"
        trace("correction: local server FAILED — \(text) [\(reason)]")
        forwardManagerNotes()
        refreshMenu()
    }

    /// Forward the manager's own `[manager]` notes, and ONLY those, into the trace. The
    /// ring also holds the child's stdout/stderr, which is under the child's control —
    /// an adopted server started with `--print-realtime` would fill it with transcript
    /// segments — and the trace never carries transcript text (`trace()`'s contract).
    /// Forwarded once each: `totalLines` counts what the ring has ever held.
    private func forwardManagerNotes() {
        let manager = WhisperServerManager.shared
        let total = manager.log.totalLines
        let fresh = total - forwardedManagerLogLines
        guard fresh > 0 else { return }
        forwardedManagerLogLines = total
        for line in manager.recentLog(fresh) where line.hasPrefix("[manager]") {
            trace("correction: \(line)")
        }
    }

    /// Stop the local server through the chain. A start still loading its model is
    /// cancelled first so the stop is not held behind a 60 s readiness wait; the
    /// cancelled start traces "cancelled" and the stop runs after it. The cancellation
    /// reaches the wrapper only — `WhisperServerManager.startShared` awaits an inner
    /// task that it does not cancel — so the manager is also told to veto the spawn:
    /// without that, a start cancelled before `launch` still spawned whisper-server and
    /// began the model load that the queued `stop()` then SIGTERMed. A stop is never
    /// cancelled (see `serverLifecycleIsStart`). No-op with no trace when nothing was
    /// ever started, so the sleep/lock observers may call it on every event.
    private func stopLocalServer(reason: String) {
        localIdleStopTask?.cancel()
        localIdleStopTask = nil
        guard localServerRequested else { return }
        localServerRequested = false
        let manager = WhisperServerManager.shared
        if serverLifecycleIsStart {
            manager.vetoPendingStart()
            serverLifecycle?.cancel()
        }
        trace("correction: local server stopping — \(reason)")
        enqueueServerLifecycle(isStart: false) { [weak self] in
            await manager.stop()
            await MainActor.run {
                guard let self else { return }
                self.localServerStatus = "stopped (\(reason))"
                self.forwardManagerNotes()
                self.refreshMenu()
            }
        }
    }

    /// After a capture ends: release the server if the session's provider is no longer
    /// the selected one, else start the idle clock. Both are no-ops when nothing runs.
    private func armLocalIdleStop() {
        localIdleStopTask?.cancel()
        localIdleStopTask = nil
        guard finalQueue.pendingCaptureCount == 0 else { return }
        guard correctionKind == .local || localDictationEnabled else {
            stopLocalServer(reason: "provider is \(correctionKind.rawValue)")
            return
        }
        guard localServerRequested else { return }
        let seconds = Self.localServerIdleStopSeconds
        localIdleStopTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !self.isCapturing, self.drainTimer == nil, self.finalQueue.pendingCaptureCount == 0 else { return }
            self.stopLocalServer(reason: "idle for \(Int(seconds)) s")
        }
    }

    /// Route SIGTERM through ordinary AppKit termination so local captures flush
    /// and pending results finish before the owned server is stopped. SIGKILL
    /// cannot drain work; a later launch only reclaims an exact owned PID record.
    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGTERM, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler {
            // Nonisolated, so it runs right here on the global queue; the terminate is
            // one hop to the main actor, and one hop has no ordering to lose.
            trace("SIGTERM received — finishing pending work and terminating through "
                + "NSApp.terminate so applicationWillTerminate runs")
            Task { @MainActor in NSApp.terminate(nil) }
        }
        source.resume()
        sigtermSource = source
    }

    /// Read the user's glossary off the main thread, merge it ahead of the built-ins,
    /// and publish `activeKeyterms`. See `UserKeyterms`.
    private func reloadKeyterms(reason: String) {
        guard correctionKind != .off || localDictationEnabled else { return }
        Task.detached(priority: .utility) { [weak self] in
            let loaded = UserKeyterms.load()
            let merged = UserKeyterms.merge(user: loaded.terms, builtin: cloudKeyterms)
            let rendering = WhisperClient.promptRendering(from: merged)
            let bytes = rendering.sentence.utf8.count
            await MainActor.run {
                self?.publishKeyterms(loaded, merged: merged, promptKept: rendering.kept,
                                      promptDropped: rendering.dropped, promptBytes: bytes,
                                      reason: reason)
            }
        }
    }

    private func publishKeyterms(_ loaded: UserKeyterms.Loaded, merged: [String],
                                 promptKept: Int, promptDropped: Int, promptBytes: Int,
                                 reason: String) {
        activeKeyterms = merged
        // Counts and a path only — never a term. `dropped` is the number the user file
        // exists to keep at zero.
        trace("keyterms: user=\(loaded.terms.count) "
            + "(\(loaded.path)\(loaded.present ? "" : " absent")) "
            + "builtin=\(cloudKeyterms.count) merged=\(merged.count) "
            + "localPrompt=\(promptKept) kept/\(promptDropped) dropped "
            + "\(promptBytes)/\(WhisperClient.maxPromptBytes) bytes [\(reason)]")
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    /// Switch the dictation engine between Apple's on-device recogniser and Gemini Live.
    ///
    /// TAKES EFFECT AT THE NEXT CAPTURE, never mid-session, and that is the same rule
    /// `selectCorrection` follows one screen up — but here it is a correctness requirement
    /// rather than a convenience. `activeEngineKind` and the `activeEngine` reference it
    /// resolves are captured once in `beginCapture` and are what `processTap` feeds on the
    /// realtime audio thread; swapping the engine under a live session would hand a
    /// half-streamed utterance to a different recogniser, with the consumer's typed-span
    /// ledger still describing the first one's text. So the flip only ever moves
    /// `selectedEngineKind`, and the running session keeps the engine it started with.
    ///
    /// Guarded on `geminiLiveAvailable` for the same reason `selectCorrection` refuses an
    /// unconfigured provider: with no `GOOGLE_API_KEY` on disk the Gemini engine cannot
    /// start, and a toggle that silently selects a dead engine would present as "dictation
    /// just stopped working". `refreshMenu` renders that unavailable state with the key
    /// name and path, so the user is told what to create.
    @objc private func toggleEngine() {
        let next: DictationEngineKind = (selectedEngineKind == .apple) ? .geminiLive : .apple
        // Only the way IN is gated. Falling back to Apple must always be possible — it is
        // the on-device engine and the recovery path if the cloud one misbehaves.
        if next == .geminiLive && !geminiLiveAvailable {
            trace("MENU: dictation engine -> geminiLive REFUSED (no key / cloud unavailable)")
            refreshMenu()
            return
        }
        selectedEngineKind = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.engineDefaultsKey)
        trace("MENU: dictation engine -> \(next.rawValue)")
        if next == .geminiLive {
            // Said once, plainly, at the moment of the choice. The menu title and tooltip
            // carry it too, but this is the line that lands in the trace beside the audio
            // that was actually streamed, which is what makes the record honest.
            trace("PRIVACY: Gemini Live streams microphone audio to Google for as long as "
                + "dictation runs; the Apple engine never sends audio off this Mac")
        }
        if isCapturing && next != activeEngineKind {
            trace("MENU: engine switch takes effect at the NEXT session "
                + "(tap \(defaultHotkeyName) to stop, then again to start) — this session "
                + "continues on \(activeEngineKind.rawValue)")
        }
        refreshMenu()
    }

    @objc private func toggleDaemonRestart() {
        daemonRestartEnabled.toggle()
        UserDefaults.standard.set(daemonRestartEnabled, forKey: Self.daemonRestartDefaultsKey)
        trace("MENU: restart macOS speech service when wedged -> \(daemonRestartEnabled ? "on" : "off")")
        refreshMenu()
    }

    @objc private func toggleAutoCorrect() {
        guard !isCapturing && drainTimer == nil else { return }
        autoCorrectEnabled.toggle()
        UserDefaults.standard.set(autoCorrectEnabled, forKey: Self.autoCorrectDefaultsKey)
        trace("MENU: auto-apply corrections -> \(autoCorrectEnabled ? "on" : "off")")
        refreshMenu()
    }

    @objc private func copyLastTranscript() {
        copyToPasteboard(lastTranscript, label: "last transcript")
    }

    @objc private func copyCloudCorrection() {
        copyToPasteboard(unappliedCloudText, label: "cloud correction")
    }

    /// Writing to the pasteboard is only ever done on an explicit menu click — never
    /// automatically. Silently replacing the user's clipboard to work around our own
    /// inability to type is not a fix, it is a second bug.
    private func copyToPasteboard(_ text: String, label: String) {
        guard !text.isEmpty else {
            trace("MENU: copy \(label) — nothing to copy")
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        lastOutcome = ok ? "Copied the \(label) (\(text.count) chars)" : "Copy failed"
        trace("MENU: copy \(label) — \(text.count) chars, setString -> \(ok)")
        refreshMenu()
    }

    @objc private func showHUDPressed() {
        trace("MENU: show HUD")
        showIdleHUD()
    }

    @objc private func openAccessibilitySettings() { openPane(accessibilityPaneURL, name: "Accessibility") }
    @objc private func openMicrophoneSettings() { openPane(microphonePaneURL, name: "Microphone") }
    @objc private func openSpeechSettings() { openPane(speechPaneURL, name: "Speech Recognition") }

    /// Google AI Studio's key page — where quota and usage actually live.
    ///
    /// AI Studio and not the Cloud console, because this is the "how much have I used"
    /// button; the console is where a REJECTED KEY is fixed, and `describeCloudError`'s
    /// 401/403 branch names that one instead. Two destinations, each reached from the state
    /// it can resolve.
    ///
    /// Deliberately NOT routed through `openPane(_:name:)`, despite the identical shape:
    /// that helper's failure path tells the user to go to "System Settings > Privacy &
    /// Security > <name>", which is exactly the wrong advice for a web page and would send
    /// someone hunting through a settings pane that has nothing to do with Gemini.
    @objc private func openCloudQuota() {
        guard let url = URL(string: googleQuotaURL) else {
            trace("ERROR: could not build the Gemini quota URL from \(googleQuotaURL)")
            return
        }
        let ok = NSWorkspace.shared.open(url)
        trace("MENU: open Gemini quota — NSWorkspace.open -> \(ok)")
        if !ok {
            lastOutcome = "Could not open a browser — Gemini quota is at \(googleQuotaURL)"
            refreshMenu()
        }
    }

    private func openPane(_ urlString: String, name: String) {
        guard let url = URL(string: urlString) else {
            trace("ERROR: could not build the \(name) settings URL from \(urlString)")
            return
        }
        let ok = NSWorkspace.shared.open(url)
        trace("NSWorkspace.open(\(name)) -> \(ok)")
        if !ok {
            lastOutcome = "System Settings did not open — go to Privacy & Security > \(name)"
            refreshMenu()
        }
    }

    // MARK: - Headless regression hook

    /// Inert unless MICTEST_AUTOSTART=1 is in the environment.
    ///
    /// Originally this existed to prove the realtime-thread isolation crash was fixed:
    /// "launch it and see if it stays alive" is a false pass, because the executor check that
    /// used to trap only runs *inside* the tap callback, so an app that never starts
    /// capturing survives happily with the bug fully present. The only honest proof is a
    /// nonzero frame count in the trace, which means the tap really did run, many times, on
    /// the audio thread, without trapping.
    ///
    /// It now also has to prove the new machinery runs, and that has the same shape of trap:
    /// in a silent room the recogniser legitimately returns nothing, so "no text appeared"
    /// cannot distinguish a working pipeline from one that died immediately. So the chunk
    /// loop emits liveness lines (`LOOP[n]: alive — polls=…`) that are true regardless of
    /// speech, and `autostartQuit` prints a summary. Read those, not the transcript.
    ///
    /// It drives the SAME path the hotkey drives — `wantsDictation` plus `syncDictation()` —
    /// so a headless run exercises the real begin/end code rather than a parallel one. It
    /// cannot press a physical key, so the CGEventTap delivery path itself is NOT covered;
    /// only tap health is, via the trace and the menu.
    ///
    /// LAUNCH IT WITH `open`, NEVER BY EXEC'ING THE INNER MACH-O. This paragraph used to say
    /// the opposite — that `open` cannot forward environment variables, so one should run
    /// `MICTEST_AUTOSTART=1 ~/Desktop/MicTest.app/Contents/MacOS/MicTest`, and that "bundle
    /// identity and signature still resolve (Bundle.main is the .app), so TCC is unaffected."
    /// Both halves were wrong, and the second one wrong in the expensive direction:
    ///
    ///     open -W -n -g --env MICTEST_AUTOSTART=1 --env MICTEST_AUTOSTART_HOLD=50 \
    ///          -a ~/Desktop/MicTest.app
    ///
    ///   * `--env` forwards variables perfectly well; `-W` waits for exit, `-n` forces a new
    ///     instance, `-g` keeps the launch from stealing focus.
    ///   * Exec'ing the inner binary crashes 100% of the time, with SIGABRT, the instant
    ///     `LiveRecognizer.requestAuthorization()` is reached: TCC namespace, "attempted to
    ///     access privacy-sensitive data without a usage description ... must contain an
    ///     NSSpeechRecognitionUsageDescription key". The key IS present and correct in the
    ///     built Info.plist, and `Bundle.main` DOES resolve to the .app — the trace prints
    ///     the right bundle id and path a line before it dies. TCC's usage-description
    ///     lookup simply does not honour that when the executable is exec'd directly rather
    ///     than launched as a bundle.
    ///   * The reason this cost a whole test round rather than announcing itself: the
    ///     process exits **0**, and the trace just stops after the last startup line. It
    ///     reads exactly like a run that did nothing, not like a crash. The evidence is in
    ///     ~/Library/Logs/DiagnosticReports/MicTest-*.ips, which is not where anyone looks
    ///     when the exit status is success.
    ///
    /// `MICTEST_AUTOSTART_HOLD=<seconds>` lengthens the simulated hold. THIS IS NOT A
    /// CONVENIENCE KNOB. The default hold is 8.5 s and the rotation cadence is 20 s, so the
    /// default run tears the capture down before a single rotation happens — meaning the
    /// flush-then-replay seam path (the fix for words being cut every 20 s, the whole point
    /// of Phase 2) is exercised ZERO times by a default headless run, and its absence from
    /// the trace looks identical to it being broken. Pass a hold of 45 s or more to cross
    /// two seams; two, not one, because a single seam cannot show whether the replay window
    /// is consumed correctly on the pass that follows it.
    ///
    /// Release is always hold-seconds after the press, and quit is 6 s after the release —
    /// that tail is the cloud pass's window to settle, so the CLOUD SUMMARY has something
    /// true to print rather than racing the reply. Derived, not independently configurable:
    /// the two failure modes of a hand-tuned schedule are quitting before the release and
    /// quitting before the cloud answers, and both print a clean-looking summary full of
    /// zeroes.
    private func maybeArmAutostart() {
        guard ProcessInfo.processInfo.environment["MICTEST_AUTOSTART"] == "1" else { return }
        // Clamped, not trusted. A typo'd or non-numeric hold silently becoming 0 would end
        // the capture in the same runloop turn it began and report `frames=0`, which reads
        // as an audio-thread failure rather than as bad input. Floor of 1 s keeps a
        // malformed value in "short run" territory; the 600 s ceiling exists because this
        // harness quits the app on a timer and an unbounded value would hang a CI run.
        let holdEnv = ProcessInfo.processInfo.environment["MICTEST_AUTOSTART_HOLD"]
        // `.isFinite`, not just a nil check, and NOT `min(max(...))` alone. `TimeInterval`
        // is `Double`, so `TimeInterval("nan")` parses successfully to NaN — and NaN passes
        // straight through `min(max(x, 1.0), 600.0)` unchanged, because every comparison
        // against NaN is false. The result was a NaN hold, NaN timer intervals for all three
        // scheduled selectors, no "is not a number" warning (`TimeInterval("nan") == nil` is
        // false) and no sub-20s warning either (`nan < 20.0` is false): a run that schedules
        // nothing and says nothing, which is precisely the silent failure this clamp exists
        // to prevent. `inf` was already handled correctly by the ceiling; `nan` was not.
        let parsedHold = holdEnv.flatMap(TimeInterval.init).flatMap { $0.isFinite ? $0 : nil }
        let hold = min(max(parsedHold ?? 8.5, 1.0), 600.0)
        if let holdEnv, parsedHold == nil {
            trace("MICTEST_AUTOSTART_HOLD=\(holdEnv) is not a usable number — using the 8.5s default")
        }
        let press: TimeInterval = 1.5
        let release = press + hold
        let quit = release + 6.0
        trace(String(format: "MICTEST_AUTOSTART=1 — simulated hold at t+%.1fs, "
                   + "release at t+%.1fs (hold %.1fs), quit at t+%.1fs", press, release, hold, quit))
        if hold < 20.0 {
            trace("AUTOSTART: hold \(String(format: "%.1f", hold))s < the 20s rotation cadence — "
                + "this run will NOT reach a seam; rotation/replay lines are expected to be "
                + "absent. Set MICTEST_AUTOSTART_HOLD=45 to exercise them.")
        }
        let schedule: [(TimeInterval, Selector)] = [
            (press, #selector(autostartBegin)),
            (release, #selector(autostartEnd)),
            (quit, #selector(autostartQuit))
        ]
        for (delay, selector) in schedule {
            let t = Timer(timeInterval: delay, target: self, selector: selector,
                          userInfo: nil, repeats: false)
            RunLoop.main.add(t, forMode: .common)
        }
    }

    @objc private func autostartBegin() {
        trace("AUTOSTART: simulated hotkey press")
        wantsDictation = true
        syncDictation()
    }

    @objc private func autostartEnd() {
        trace("AUTOSTART: simulated hotkey release")
        wantsDictation = false
        syncDictation()
    }

    @objc private func autostartQuit() {
        finishCapture(reason: "autostart run complete")
        let (_, frames) = levelBox.read()
        let cloudLatency = lastCloudLatencyMS.map { String(format: "%.0f ms", $0) } ?? "—"
        // NO `balance=` FIELD ANY MORE: it reported a number fetched from fal's billing
        // endpoint, and Google has no key-readable equivalent to fetch. `spentAudioTokens`
        // takes its place and is a better field than the one it replaces — measured here
        // from the responses themselves rather than reported by a vendor, and in the exact
        // unit Gemini bills.
        // LIFETIME on purpose, both lines. This is the verdict for an entire headless run,
        // printed once at exit, and `sessions=` in the same line is what the totals are
        // counted against — per-capture numbers here would describe only the last capture,
        // which `finishCapture` tore down two lines above and which in an autostart run is
        // the only capture anyway. Do not "fix" these to `thisCapture`.
        // (`frames` is the one exception and always was: `levelBox` only ever holds the
        // most recent capture's count. In a one-hold autostart run the two coincide.)
        trace("AUTOSTART SUMMARY: sessions=\(sessions) frames=\(frames) "
            + "micStatus=\(statusName(micStatus)) "
            + "speechAuthorized=\(speechAuthorized.map(String.init(describing:)) ?? "pending") "
            + "recognizerSupported=\(recognizer.isSupported) "
            + "axTrusted=\(hotkey.permissionGranted()) tapHealthy=\(hotkey.isHealthy) "
            + "partials=\(lifetime.partialsSeen) finals=\(lifetime.finalsSeen) "
            + "injectedChars=\(lifetime.injectedChars) injectFailures=\(lifetime.injectFailures) "
            + "divergencesRepaired=\(lifetime.divergencesRepaired) "
            + "divergencesRefused=\(lifetime.divergencesRefused) "
            + "repairsRefusedTooLarge=\(lifetime.repairsRefusedTooLarge) "
            + "retractionsRefused=\(lifetime.retractionsRefused) "
            + "secureInputRefusals=\(lifetime.secureInputRefusals)")
        trace("AUTOSTART CLOUD SUMMARY: available=\(correctionAvailable) "
            + "enabled=\(correctionEnabled) correctionProvider=\(correctionKind.rawValue) "
            + "correctionModel=\(correctionModelName(for: correctionKind)) "
            + "finalChunks=\(lifetime.finalChunks) sent=\(lifetime.cloudSent) "
            + "applied=\(lifetime.cloudApplied) unapplied=\(lifetime.cloudUnapplied) "
            + "errors=\(lifetime.cloudErrors) skipped=\(lifetime.cloudSkipped) "
            + "lastCloudLatency=\(cloudLatency) setupError=\(cloudSetup.error ?? "(none)") "
            + String(format: "spentSeconds=%.0f spentRequests=%d spentAudioTokens=%d ",
                     cloudAudioSecondsSent, cloudRequestsSent, cloudAudioTokensSent)
            + "lastOutcome=\(lastOutcome ?? "(none)")")
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point (top-level code; this file is compiled without -parse-as-library)

let app = NSApplication.shared
// Held in a top-level (global) binding because NSApplication.delegate is a weak reference.
let micTestDelegate = AppDelegate()
app.delegate = micTestDelegate
// Accessory from the very first instant: a `.regular` flash here would put a Dock icon on
// screen for a frame before the delegate demoted it.
app.setActivationPolicy(.accessory)
app.run()
