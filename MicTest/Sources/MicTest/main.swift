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
//      what we have already typed and inject only the new suffix.
//    * fal Scribe v2 can run an accuracy pass on each finalized utterance — OPT-IN,
//      default OFF: the user explicitly declined auto-correction in favour of realtime
//      speed, so the chunk loop that feeds it is not even started unless the menubar
//      toggle was switched on. See `noteFinalChunk` for the gate that stops it
//      laundering hallucinations when it does run.
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
//  them: AudioPipeline, LiveRecognizer, TextInjector, HotkeyMonitor, DictationHUD,
//  FalClient, WhisperClient.
//

import AppKit
import AVFoundation

// MARK: - Constants

/// Technical vocabulary, used for BOTH halves of the recognition stack:
///   * handed to `FalClient.transcribe(wav:keyterms:)` so the cloud pass biases towards
///     these spellings instead of transliterating them into Thai phonetics, and
///   * handed to `LiveRecognizer.setContextualStrings` so the on-device pass biases the
///     same way and the live text does not have to be undone by the cloud text.
///
/// THIS IS THE LIST TO EDIT — it is the single knob that decides whether "commit" comes
/// back as `commit` or as `คอมมิต`. Keep entries short (fal caps a keyterm at 50
/// characters and the list at 100 entries) and keep them to words that are genuinely
/// ambiguous in a Thai sentence.
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

/// Local whisper.cpp (`WhisperClient.swift`) is superseded by `LiveRecognizer` for live
/// text: on-device speech recognition is word-by-word and near-zero latency, whereas the
/// whisper round trip is chunked and hundreds of milliseconds behind.
///
/// DECISION: the file is retained but is NOT called from anywhere. There is no fallback
/// path and no toggle — a dormant second transcriber that can silently take over is how
/// you get two different answers for the same audio and no way to tell which one you are
/// reading. This flag exists only so the choice is stated in the trace rather than
/// implied by an absence.
let localWhisperFallbackEnabled = false

/// System Settings panes. Named exactly, because "grant Accessibility" without the pane
/// is a treasure hunt.
let accessibilityPaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
let microphonePaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
let speechPaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"

/// How long the audio engine keeps running after the hotkey is released.
///
/// `AudioPipeline` finalises an utterance on trailing silence. If we tore the engine down
/// the instant the key came up, no further buffers would arrive, trailing silence would
/// stop growing, and the last utterance would be stranded in the ring — never finalised,
/// never sent to the cloud pass. Holding the engine open for slightly longer than the
/// pipeline's own 0.6 s silence window lets that final chunk fall out naturally.
let releaseDrainSeconds: TimeInterval = 0.9

/// How long one in-flight cloud request may hold the one-request gate shut before a NEW
/// final chunk is allowed to supersede it. A healthy fal round trip settles in ~1-3 s;
/// only a hung request (dropped network, waiting on FalClient's much longer timeout) ever
/// reaches this age. The stakes: while the gate is held shut, every refused chunk's
/// typed-span ledger snapshot has ALREADY been consumed by `noteFinalChunk`, so each
/// refused span becomes permanently uncorrectable. Past this age the gate cancels the
/// hung request (cancellation routes to `applyCloudFailure(cancelled: true)`, which does
/// not count an error) and lets the new chunk through.
let cloudSupersedeAfterSeconds: TimeInterval = 5.0

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

/// Flatten a `FalClient` failure into something printable, and separately surface the key
/// path when the failure is "there is no key", because that path is the one thing the user
/// can act on. Nothing here ever renders the key itself.
func describeFalError(_ error: Error) -> (summary: String, missingKeyPath: String?) {
    if let ce = error as? FalClient.ClientError {
        switch ce {
        case .missingKey(let path):
            return ("no fal API key — expected FAL_KEY in \(path)", path)
        case .http(let status, let body):
            return ("fal HTTP \(status) — \(body.prefix(200))", nil)
        case .decoding(let snippet):
            return ("fal response could not be parsed — \(snippet.prefix(160))", nil)
        case .transport(let reason):
            return ("could not reach fal — \(reason)", nil)
        }
    }
    let ns = error as NSError
    return ("\(ns.domain) code \(ns.code) — \(ns.localizedDescription)", nil)
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

    func store(rms newValue: Float, frameCount: Int) {
        lock.lock()
        rms = newValue
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

    func reset() {
        lock.lock()
        rms = 0
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
final class RecognizerEventBox: @unchecked Sendable {
    /// Ceiling so a wedged main thread cannot turn a stuck recognizer into unbounded memory.
    /// Partials supersede each other, so dropping the oldest loses nothing that a later
    /// partial does not already contain.
    private static let capacity = 512

    private let lock = NSLock()
    private var events: [RecognizerEvent] = []
    private var dropped = 0

    func post(_ event: RecognizerEvent) {
        lock.lock()
        events.append(event)
        if events.count > Self.capacity {
            let excess = events.count - Self.capacity
            events.removeFirst(excess)
            dropped += excess
        }
        lock.unlock()
    }

    /// Returns the queued events in order, plus how many were dropped since the last drain.
    func drain() -> (events: [RecognizerEvent], dropped: Int) {
        lock.lock()
        let e = events
        let d = dropped
        events.removeAll(keepingCapacity: true)
        dropped = 0
        lock.unlock()
        return (e, d)
    }

    /// Discard anything left over from a previous session so a late partial cannot be
    /// mistaken for the first partial of the next utterance.
    func clear() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        dropped = 0
        lock.unlock()
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
    var secureInputRefusals = 0
    var finalChunks = 0
    var cloudSent = 0
    var cloudApplied = 0
    var cloudUnapplied = 0
    var cloudErrors = 0
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
    private let cloudItem = NSMenuItem()
    private let autoCorrectItem = NSMenuItem()
    private let daemonRestartItem = NSMenuItem()
    private let micStatusItem = NSMenuItem()
    private let speechStatusItem = NSMenuItem()
    private let axStatusItem = NSMenuItem()
    private let tapStatusItem = NSMenuItem()
    private let activityItem = NSMenuItem()
    private let copyTranscriptItem = NSMenuItem()
    private let copyCloudItem = NSMenuItem()

    // ---- Machinery -----------------------------------------------------------------
    private let hotkey = HotkeyMonitor()
    private let injector = TextInjector()
    private let recognizer = LiveRecognizer()
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
    ///     does go deaf at tick 75 of speech with NO gap at all, which is unreachable in
    ///     practice twice over: three ticks arm the ladder and it acts at six, and real
    ///     speech has inter-word gaps where the 0.1 fall rate claws back 19% of the
    ///     excursion every two seconds.
    ///   - a genuine 5x STEP in ambient (aircon switching on) ticks spuriously for exactly
    ///     37 ticks until the floor catches up. That window can reach a tier-1 bounce and,
    ///     at most once, a tier-2 restart; it cannot reach tier 3, which additionally needs
    ///     a real partial inside 300 s.
    ///
    /// KNOWN BLIND SPOT, written down so it is diagnosable instead of surprising: at ratio
    /// 3.0 an ambient of 0.004 puts the threshold at 0.012, above the sub-0.01 quiet speech
    /// this mic measures — a quiet speaker in a moderately noisy room stops arming the
    /// watchdog. Dictation itself is unaffected; only the watchdog goes to sleep. Every
    /// watchdog trace line and the "capture stopped" line now print `rms`/`floor`/`thr`,
    /// which is how this will be recognised if it ever happens. Do not add a compensating
    /// gate on a hunch — get the numbers out of the trace first.
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

    /// The `rms=… floor=… thr=…` group, so every watchdog trace and the "capture stopped"
    /// line carry the same three numbers in the same shape. Five decimals because four
    /// leaves barely two significant digits at these magnitudes. The previous debugging
    /// round climbed all three tiers and killed a system service twice without one line
    /// anywhere recording what the gate had measured; this is the fix for that, and it is a
    /// requirement of the design, not a convenience.
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

    /// True once this session learned the focused app cannot do AX in-place replacement
    /// (Chromium/Electron and friends). From then on partials are NOT typed live -- only
    /// each utterance FINAL is injected, so divergence repair is never needed and the user
    /// gets complete sentences instead of a stale 3-char stump. Reset per session: focus
    /// usually changes between sessions, so the next app gets live typing again.
    private var finalOnlyInjection = false

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

    /// Constructed once, at init. `FalClient.init()` throws when there is no key on disk,
    /// and that is a perfectly ordinary state — it must disable the toggle and name the file
    /// to create, not crash and not silently do nothing.
    private let falSetup: (client: FalClient?, error: String?, keyPath: String?) = {
        do {
            return (try FalClient(), nil, nil)
        } catch {
            let d = describeFalError(error)
            return (nil, d.summary, d.missingKeyPath)
        }
    }()
    private var cloudAvailable: Bool { falSetup.client?.isConfigured == true }

    /// "Cloud accuracy pass" menu toggle — REALTIME-FIRST, default OFF. The user's explicit
    /// directive: "I don't need auto-correction. I need realtime and fast dictation." The
    /// cloud pass (10 s chunk uploads, ~2-4 s round trips, span-matching replacement) is
    /// therefore opt-in from the menubar, not the default. Persisted in UserDefaults with
    /// nil-means-OFF semantics: a stored explicit value (a previous menubar toggle) wins,
    /// so opting in survives relaunches. The effective value is computed at launch
    /// (`applicationDidFinishLaunching`) because it also requires `cloudAvailable`, which
    /// depends on the `falSetup` stored property and so cannot be read in a property
    /// initializer here.
    private nonisolated static let cloudPassDefaultsKey = "cloudPassEnabled"
    private var cloudEnabled = false

    /// "Auto-correct from cloud" menu toggle — default OFF, same realtime-first reasoning
    /// and same nil-means-OFF UserDefaults semantics as the master toggle above (an
    /// explicit stored choice wins). When ON, a fal result that differs from the span
    /// typed for its audio chunk is applied IN PLACE via
    /// `TextInjector.replaceRecentText(find:with:)`; when OFF (or when the replace
    /// refuses) the result falls back to the display-only park under "Copy cloud
    /// correction", exactly the pre-toggle behaviour. Persisted in UserDefaults so the
    /// choice survives relaunches (same pattern as the hotkey override).
    private nonisolated static let autoCorrectDefaultsKey = "cloudAutoCorrect"
    private var autoCorrectEnabled: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: AppDelegate.autoCorrectDefaultsKey) == nil
            ? false
            : d.bool(forKey: AppDelegate.autoCorrectDefaultsKey)
    }()

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
    private var daemonRestartEnabled: Bool = {
        let d = UserDefaults.standard
        return d.object(forKey: AppDelegate.daemonRestartDefaultsKey) == nil
            ? false
            : d.bool(forKey: AppDelegate.daemonRestartDefaultsKey)
    }()

    /// One cloud request in flight at a time. A second concurrent request would race the
    /// first to update the same HUD line, and fal is billed per call.
    private var cloudTask: Task<Void, Never>?

    /// When the in-flight `cloudTask` was registered; nil exactly when `cloudTask` is nil
    /// (set in `registerCloudTask`, cleared wherever the task is cleared). Read only by
    /// `noteFinalChunk`'s supersede rule — see `cloudSupersedeAfterSeconds`.
    private var cloudTaskStartedAt: Date?

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
        trace("localWhisperFallbackEnabled=\(localWhisperFallbackEnabled) "
            + "(WhisperClient.swift is retained but never called; LiveRecognizer drives live text)")
        trace("hotkey: keyCode \(hotkey.keyCode) (Right-Option is \(ModifierKey.rightOption))")

        // Accessory, not regular: no Dock icon, no app switcher entry, no main menu bar.
        // The status item and the HUD are the entire surface.
        NSApp.setActivationPolicy(.accessory)

        // Realtime-first: nil-means-OFF. The cloud pass runs only when the user has
        // explicitly opted in from the menubar (stored true) AND a key is configured.
        // The trace states the EFFECTIVE state and never any key material.
        let storedCloudChoice = UserDefaults.standard.object(forKey: Self.cloudPassDefaultsKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: Self.cloudPassDefaultsKey)
        cloudEnabled = cloudAvailable && storedCloudChoice
        if cloudAvailable {
            trace(cloudEnabled
                ? "fal: configured; cloud pass ON (stored menubar opt-in; keyterms: \(cloudKeyterms.count))"
                : "fal: configured; cloud pass OFF by default (enable from the menubar)")
        } else {
            trace("fal: NOT configured — \(falSetup.error ?? "unknown reason"); cloud pass disabled")
        }
        trace("auto-correct from cloud: \(autoCorrectEnabled ? "ON (stored opt-in)" : "OFF (default)")")
        trace("restart macOS speech service when wedged: "
            + (daemonRestartEnabled
                ? "ON (stored opt-in) — watchdog tier 3 may pkill localspeechrecognition"
                : "OFF (default) — watchdog tier 3 detects and logs only"))

        buildStatusItem()
        wireHUD()
        wireRecognizer()
        wireHotkey()
        wireSystemStateObservers()

        // The HUD comes up idle rather than hidden, and stays that way: see the header. This
        // is the affordance that survives a status item hiding behind the notch.
        showIdleHUD()

        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        trace("initial authorizationStatus(.audio): \(statusName(micStatus))")

        // Contextual strings before the first start(), so the very first utterance already
        // biases towards the technical vocabulary rather than only later ones.
        recognizer.setContextualStrings(cloudKeyterms)
        trace("recognizer: isSupported=\(recognizer.isSupported) "
            + "contextualStrings=\(cloudKeyterms.count)")

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

    func applicationWillTerminate(_ notification: Notification) {
        wantsDictation = false
        finishCapture(reason: "app terminating")
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

        cloudItem.title = "Cloud accuracy pass"
        cloudItem.target = self
        cloudItem.action = #selector(toggleCloud)
        menu.addItem(cloudItem)

        autoCorrectItem.title = "Auto-correct from cloud"
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

        copyCloudItem.title = "Copy cloud correction"
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
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    private func refreshMenu() {
        dictationItem.title = dictationEnabled
            ? "Dictation: on — tap \(defaultHotkeyName) to start/stop"
            : "Dictation: OFF"
        dictationItem.state = dictationEnabled ? .on : .off

        if cloudAvailable {
            cloudItem.title = cloudEnabled ? "Cloud accuracy pass: on" : "Cloud accuracy pass: off"
            cloudItem.state = cloudEnabled ? .on : .off
            cloudItem.isEnabled = true
        } else {
            cloudItem.title = "Cloud accuracy pass unavailable — "
                + (falSetup.keyPath.map { "create \($0) with FAL_KEY=…" } ?? (falSetup.error ?? "no key"))
            cloudItem.state = .off
            cloudItem.isEnabled = false
        }

        autoCorrectItem.title = autoCorrectEnabled
            ? "Auto-correct from cloud: on"
            : "Auto-correct from cloud: off — cloud text is display-only"
        autoCorrectItem.state = autoCorrectEnabled ? .on : .off
        // Meaningless without the cloud pass itself.
        autoCorrectItem.isEnabled = cloudAvailable

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

    /// The compact idle form. `DictationHUD.Mode` has no `.idle` case and `.hidden` calls
    /// `hide()`, so the least-wrong of the six is `.transcribing` with a body string we
    /// control — the body carries the truth ("Idle — hold Right-Option to dictate") and the
    /// panel stays on screen and clickable, which is what this requirement is about.
    /// A genuine `.idle` case would need an edit to DictationHUD.swift, which is out of scope.
    private func showIdleHUD() {
        hud.set(.transcribing(idleBody()))
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
        if speechAuthorized == false {
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

    /// These three closures are `@Sendable` and run on Speech's own queue. They capture the
    /// event box — a lock-protected `@unchecked Sendable` class — and nothing else. In
    /// particular they do not capture `self`, do not touch the main actor, and do not call
    /// `trace()` (a file write per partial would be both slow and a privacy leak).
    private func wireRecognizer() {
        let box = events
        recognizer.onPartial = { text in box.post(.partial(text)) }
        recognizer.onFinal = { text in box.post(.final(text)) }
        recognizer.onState = { state in box.post(.state(state)) }
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
        stopBecauseOffSwitchIsUnreachable(
            why: "the Mac is going to sleep",
            message: "Dictation stopped because the Mac is going to sleep.")
    }

    @objc private func screenWasLocked(_ note: Notification) {
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
        // A press that arrives during the drain window cancels the teardown: the user has
        // pressed again, and this is one continuous session as far as the engine is concerned.
        if drainTimer != nil {
            drainTimer?.invalidate()
            drainTimer = nil
            trace("beginCapture: cancelled a pending drain")
            if isCapturing {
                // The engine is still live but the recogniser was stopped on release; restart
                // it so the new utterance gets its own session rather than silently producing
                // no partials at all.
                do {
                    try recognizer.start()
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
                    // leave the microphone hot and chunks still uploading to fal while the
                    // HUD claims failure, with `wantsDictation` forced false so the next
                    // tap is a no-op — the user would need three taps to actually stop.
                    // `finishCapture` tears all of that down; its deferred syncDictation
                    // then no-ops (wantsDictation is false), and `fail()`'s error HUD is
                    // the last write, so the user sees the recogniser error, not idle.
                    finishCapture(reason: "drain-cancel restart failed")
                    let desc = describeRecognizerError(error)
                    fail("On-device recogniser could not restart: \(desc)",
                         context: "beginCapture(drain): recognizer.start() threw — \(desc)")
                }
                return
            }
        }

        guard !isCapturing else { return }

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

        // Build the pipeline BEFORE installing the tap. If its init throws we want to return
        // from a state with no tap installed and no engine started — a tap left attached to
        // an abandoned node is precisely what makes the *next* start raise the double-install
        // exception.
        let pipe: AudioPipeline
        do {
            pipe = try AudioPipeline(inputFormat: format)
        } catch {
            let desc = describePipelineError(error)
            fail("Audio pipeline could not start: \(desc)",
                 context: "beginCapture: AudioPipeline init threw — \(desc)")
            return
        }
        pipe.reset()

        events.clear()
        levelBox.reset()
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

        do {
            try recognizer.start()
        } catch {
            let desc = describeRecognizerError(error)
            fail("On-device recogniser could not start: \(desc)",
                 context: "beginCapture: recognizer.start() threw — \(desc)")
            return
        }
        // A fresh recogniser has produced no events yet; a timestamp inherited from a
        // previous session is stale by definition. Stamp the liveness clock now so the
        // recogniser watchdog cannot bounce a brand-new, healthy request on its first tick.
        lastRecognizerEventAt = Date()
        // No partial has been drained for this brand-new session yet.
        // `escalationsThisSession` deliberately does NOT reset here: the watchdog's own
        // escalation lands back in this very path via the self-heal, and resetting would
        // hand every churned-up session a fresh speculative restart -- the exact ambient
        // loop the damper exists to stop. The count resets when a DELIBERATE stop ends
        // the session instead (see `finishCapture`).
        sessionSawPartial = false

        // Capture only Sendable collaborators; never self, never UI.
        let box = levelBox
        let rec = recognizer

        // The `@Sendable` here is load-bearing, not decoration. See AppDelegate.processTap.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            // Realtime audio thread. Hand the buffer on and store the level, nothing else.
            AppDelegate.processTap(buffer, into: box, pipeline: pipe, recognizer: rec)
        }

        e.prepare()
        do {
            try e.start()
        } catch {
            let ns = error as NSError
            input.removeTap(onBus: 0)   // undo the tap we just installed
            recognizer.stop()
            fail("Audio engine did not start: \(ns.localizedDescription)",
                 context: "beginCapture: engine.start() threw \(ns.domain) code \(ns.code)")
            return
        }

        engine = e
        pipeline = pipe
        isCapturing = true
        sessions += 1

        captureGeneration &+= 1
        let gen = captureGeneration
        chunkTask?.cancel()
        chunkTask = nil
        flushRequest = nil

        // REALTIME-FIRST GATE: the chunk loop exists only to feed the cloud pass. When the
        // pass is disabled at capture start there is nothing to feed — polling takeChunk()
        // (a ring-buffer copy + WAV encode per chunk) only for noteFinalChunk to refuse
        // every dispatch is pure waste on the consumer side of the audio path, so the loop
        // is not created at all. (The pipeline itself stays: the tap's append writes into
        // a preallocated 30 s ring whose count saturates at capacity, and chunks are cut
        // lazily inside takeChunk()/flush(), so an unpolled pipeline cannot grow memory.)
        // The effective state is read HERE, on the MainActor, at session start; toggling
        // cloud ON mid-session therefore takes effect at the NEXT session start — traced
        // in `toggleCloud` so it is not mistaken for a bug. The stop paths already
        // tolerate the nils: `drainElapsed` flushes via `flushRequest?.request()` and
        // `finishCapture` cancels via `chunkTask?.cancel()`, both optional-chained no-ops.
        if cloudEnabled && cloudAvailable {
            let cloud = falSetup.client
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
            trace("LOOP[\(gen)]: chunk loop not started (cloud pass disabled)")
        }

        finalOnlyInjection = false   // new session, new focused app: try live typing again
        // New pipeline, new generation: a span typed for a previous session's audio must
        // never be offered to this session's cloud pass.
        typedSinceLastChunk = ""
        startUtterance()
        lastOutcome = nil
        trace(String(format: "capture started OK — session %d, generation %d, %.0f Hz / %u ch",
                     sessions, gen, format.sampleRate, format.channelCount))
        refreshMenu()
    }

    /// Reset the per-utterance injection bookkeeping and put the HUD into listening.
    private func startUtterance() {
        injectedForUtterance = ""
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
        recognizer.stop()
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
        chunkTask?.cancel()
        chunkTask = nil
        flushRequest = nil
        drainTimer?.invalidate()
        drainTimer = nil

        guard isCapturing, let e = engine else { return }
        // Remove the tap before stopping — the reverse order can leave a tap attached to a
        // stopped node and trip an exception the next time around.
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
        pipeline = nil
        isCapturing = false
        recognizer.stop()

        let (rms, frames) = levelBox.read()
        // THIS CAPTURE unprefixed, lifetime in the trailing bracket, and the bracket is
        // labelled because that ambiguity is precisely what made this line lie for as long
        // as it did (see `TraceCounters`). Anything added here must go in one group or the
        // other, never floating between them.
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
        trace("capture stopped (\(reason)); frames=\(frames) \(levelTrace(rms)) "
            + "partials=\(thisCapture.partialsSeen) coalesced=\(thisCapture.partialsCoalesced) "
            + "finals=\(thisCapture.finalsSeen) injectedChars=\(thisCapture.injectedChars) "
            + "divergencesRepaired=\(thisCapture.divergencesRepaired) "
            + "divergencesRefused=\(thisCapture.divergencesRefused) "
            + "injectFailures=\(thisCapture.injectFailures) "
            + "secureInputRefusals=\(thisCapture.secureInputRefusals) "
            + "finalChunks=\(thisCapture.finalChunks) cloudSent=\(thisCapture.cloudSent) "
            + "cloudApplied=\(thisCapture.cloudApplied) "
            + "cloudUnapplied=\(thisCapture.cloudUnapplied) "
            + "cloudErrors=\(thisCapture.cloudErrors) cloudSkipped=\(thisCapture.cloudSkipped)"
            + "  [lifetime: sessions=\(sessions) partials=\(lifetime.partialsSeen) "
            + "coalesced=\(lifetime.partialsCoalesced) finals=\(lifetime.finalsSeen) "
            + "injectedChars=\(lifetime.injectedChars) "
            + "divergencesRepaired=\(lifetime.divergencesRepaired) "
            + "divergencesRefused=\(lifetime.divergencesRefused) "
            + "injectFailures=\(lifetime.injectFailures) "
            + "secureInputRefusals=\(lifetime.secureInputRefusals) "
            + "finalChunks=\(lifetime.finalChunks) cloudSent=\(lifetime.cloudSent) "
            + "cloudApplied=\(lifetime.cloudApplied) "
            + "cloudUnapplied=\(lifetime.cloudUnapplied) "
            + "cloudErrors=\(lifetime.cloudErrors) cloudSkipped=\(lifetime.cloudSkipped)]")

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
    /// `AudioPipeline` and `LiveRecognizer` are both `@unchecked Sendable` and carry no actor
    /// isolation of their own, so `append` is safe to call from here — and `LiveRecognizer`
    /// documents this as the intended caller. Do NOT reach for `nonisolated(unsafe)` or
    /// `MainActor.assumeIsolated` to get anything else in here; either one reintroduces the
    /// crash above.
    ///
    /// Keep this boring. Realtime thread rules: no `trace()` (it does file I/O), no UI, no
    /// networking, no lock that could be held long. Hand off, compute, store, return.
    nonisolated static func processTap(_ buffer: AVAudioPCMBuffer,
                                       into box: LevelBox,
                                       pipeline: AudioPipeline,
                                       recognizer: LiveRecognizer) {
        // Recogniser first: it is what the user is watching appear, word by word.
        recognizer.append(buffer)
        pipeline.append(buffer)

        guard let channels = buffer.floatChannelData, buffer.format.channelCount > 0 else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let samples = channels[0]
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let v = samples[i]
            sumSquares += v * v
        }
        let rms = (sumSquares / Float(frameCount)).squareRoot()
        box.store(rms: rms, frameCount: frameCount)
    }

    // MARK: - Main-thread pump

    /// 30 Hz. Drains the recogniser event queue in order and feeds the HUD meter. This is the
    /// only place `LiveRecognizer`'s output reaches the main actor.
    @objc private func tickUI() {
        let (batch, dropped) = events.drain()
        if dropped > 0 {
            trace("EVENTS: dropped \(dropped) queued recogniser event(s) — main thread fell behind")
        }
        // Coalesce revision churn: each partial carries the WHOLE utterance so far, so a
        // partial immediately followed by another partial in the same drained batch is
        // already superseded — typing it would only be undone by the very next event on
        // this same tick. Skipping it keeps one injector round-trip per ~33 ms tick.
        // Only consecutive partials collapse; a final (or state change) between partials
        // is never skipped and still sees events in their original order.
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
                sessionSawPartial = true     // evidence of real recognition work: arms the escalation damper
                suppressedBouncesSinceRestart = 0   // recognition demonstrably works: stand tier 3 down
                handlePartial(text)
            case .final(let text):
                lastRecognizerEventAt = Date()
                recognizerStalledTicks = 0
                loudTicksSinceRecognizerEvent = 0
                handleFinal(text)
            case .state(let state):
                lastRecognizerEventAt = Date()
                loudTicksSinceRecognizerEvent = 0
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
        if !isCapturing && cloudTask == nil && injectionBlockedReason == nil && !utteranceDiverged {
            hud.set(.transcribing(idleBody()))
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
            if rms.isFinite, rms > speechThreshold { loudTicksSinceRecognizerEvent += 1 }
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
            // local and needs no answer from the Speech service, so the 20 s rotation, its
            // 6 s overlap fallback and the 2 s promote land events at +26/+28 and every 20 s
            // after. The largest event-free window the guard below can EVER observe is 26 s
            // straight after a restart and 18 s once the schedule settles. At 48 s the guard
            // is unsatisfiable forever — and it takes tiers 1 and 2 down with it, so turning
            // tier 3 off also disabled the cheap recovery that works and the evidence
            // gathering the toggle exists for. Measured, 30 runs x 4 environments: 1.7-2.0
            // `WOULD FIRE` lines and then total silence for the remaining ~1050 s.
            //
            // Simulated against that stamping model, 1200 s, user quiet 60 s in every 300 s
            // (one missed strike is all it takes to settle the schedule into its 18 s
            // cadence): ceilings of 18/20/24/26/48 s all go permanently silent — last ladder
            // line at 306/307/297/122/122 s. 16 s survives (60 bounces), 12 s survives (77),
            // 6 s survives (139). 12 s is chosen because it is the highest EXISTING rung of
            // the 6/12/24/48 ladder that clears the 18 s worst case with margin, and because
            // rung 6 is the one that produced the ~7 s bounce cadence that got this process
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
            // The ON path keeps 48 s exactly. There the ratchet is self-limiting — reaching
            // the armed state fires the kill, which resets the counter — so the pin is only
            // reachable inside the 120 s window after a kill, and this commit deliberately
            // does not perturb the path that `kill -9`s a system service. That residual pin
            // is real and is left standing knowingly; if the toggle is ever promoted to
            // default-ON, this ceiling has to come with it.
            let backoffCeiling: Double = daemonRestartEnabled ? 48 : 12
            let bounceBackoff: Double = min(backoffCeiling,
                                            6 * pow(2, Double(min(suppressedBouncesSinceRestart, 3))))
            if heardSpeechSinceSilence, Date().timeIntervalSince(lastRecognizerEventAt) > bounceBackoff {
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

    /// `onPartial` delivers the WHOLE growing transcription each time, not a delta. We inject
    /// only the part we have not injected yet.
    private func handlePartial(_ raw: String) {
        guard isCapturing || drainTimer != nil else { return }
        lifetime.partialsSeen += 1; thisCapture.partialsSeen += 1
        currentOnDeviceText = raw
        hud.set(.transcribing(raw.isEmpty ? "…" : raw))
        deliver(raw)
    }

    private func handleFinal(_ raw: String) {
        lifetime.finalsSeen += 1; thisCapture.finalsSeen += 1
        // isFinal: the utterance FINAL must attempt to reconcile even after a failed
        // partial repair — extending and/or replacing via the same LCP logic — rather
        // than silently dropping the tail of the utterance.
        deliver(raw, isFinal: true)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        currentOnDeviceText = text
        if !text.isEmpty { lastTranscript = text }
        if !utteranceDiverged && injectionBlockedReason == nil {
            hud.set(.transcribing(text.isEmpty ? hudIdleBody : text))
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
        switch state {
        case .idle:
            trace("recogniser state: idle")
        case .listening:
            // A new recognition request just stood up (initial start, pause auto-restart,
            // error restart, or the ~60 s rotation). Its partials start FROM SCRATCH, so
            // the typed-count high-water mark of the previous utterance must not survive
            // into it -- carrying it over silently ate the first N characters of every
            // sentence after the first pause (the "not continuous" bug). The error-restart
            // path never emits a final, so this is hooked to .listening, not to finals.
            if !injectedForUtterance.isEmpty {
                trace("utterance boundary: reset typed high-water mark (was \(injectedForUtterance.count) chars)")
            }
            injectedForUtterance = ""
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
            utteranceSeq &+= 1
            trace("recogniser state: listening")
        case .unavailable(let reason):
            trace("recogniser state: unavailable — \(reason)")
            // The ~60 s request rotation and its quick retries are routine plumbing, not
            // user-facing failures -- flashing the HUD red for them reads as "it broke".
            if reason.contains("rotating request") || reason.contains("retry")
                || reason.contains("promoting warm replacement") {
                return
            }
            let message = "On-device recogniser unavailable — \(reason)"
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
    /// exact range we own or does nothing and returns a reason. Only on a refusal does
    /// injection stop for the utterance — and even then the FINAL (isFinal: true, which
    /// bypasses the diverged guard) and the cloud pass each get one more reconciliation
    /// attempt. We never blind-backspace, and we never pretend text was delivered.
    private func deliver(_ text: String, isFinal: Bool = false) {
        // Final-only mode: the focused app refused AX replacement earlier this session,
        // so live partials would inevitably strand stale text. Type finals only.
        if finalOnlyInjection && !isFinal { return }
        // The cloud already corrected this utterance; its text is authoritative. An
        // on-device FINAL arriving afterwards must not rewrite it back.
        if isFinal && cloudOwnsUtterance {
            trace("FINAL: skipped — cloud correction already owns this utterance")
            return
        }
        guard !utteranceDiverged || isFinal else { return }
        guard injectionBlockedReason == nil else { return }
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

        if let reason = injector.inject(suffix) {
            lifetime.injectFailures += 1; thisCapture.injectFailures += 1
            // Latch — but only until the next `.listening` boundary clears it: a real
            // inject failure (no AX trust, event post refused) is worth silencing the
            // rest of THIS utterance for, and the next utterance re-probes.
            injectionBlockedReason = reason      // already names the pane to open
            trace("INJECT FAILED: \(suffix.count) chars — \(reason)")
            lastOutcome = "Injection failed"
            hud.set(.error(reason))
            hud.show()
            refreshMenu()
            return
        }

        injectedForUtterance = text
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
    private func repairDivergence(to text: String, isFinal: Bool) {
        let lcp = commonPrefixLength(injectedForUtterance, text)
        let staleCount = injectedForUtterance.count - lcp
        let replacement = String(text.dropFirst(lcp))

        let expected = String(injectedForUtterance.suffix(staleCount))
        if let reason = injector.replaceLastInserted(count: staleCount, with: replacement,
                                                     expecting: expected) {
            lifetime.divergencesRefused += 1; thisCapture.divergencesRefused += 1
            utteranceDiverged = true
            lastTranscript = text
            lastOutcome = "Typed text is stale — in-place repair failed"
            // This app cannot host live revision. Stop typing partials for the rest of
            // the session; finals (which need no repair) still land in full.
            if !finalOnlyInjection {
                finalOnlyInjection = true
                trace("FINAL-ONLY MODE: focused app refused in-place repair; typing utterance finals only for the rest of this session")
            }
            trace("DIVERGENCE: repair FAILED\(isFinal ? " (final reconciliation)" : "") — "
                + "kept \(lcp) common chars, could not replace \(staleCount) stale chars "
                + "with \(replacement.count) chars — \(reason)")
            let message = "The recogniser revised earlier words and MicTest could not rewrite "
                + "the text it already typed (\(reason)), so it stopped typing rather than "
                + "guess. Correct text: \(text)"
            hud.set(.error(message))
            hud.show()
            refreshMenu()
            return
        }

        lifetime.divergencesRepaired += 1; thisCapture.divergencesRepaired += 1
        injectedForUtterance = text
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
        trace("DIVERGENCE: repaired in place\(isFinal ? " (final reconciliation)" : "") — "
            + "kept \(lcp) common chars, replaced \(staleCount) stale chars with "
            + "\(replacement.count) chars"
            + (replacement.isEmpty ? " (RETRACTION: pure delete)" : ""))
    }

    // MARK: - Chunk loop (cloud accuracy pass)

    /// Poll the pipeline for finalized utterances and hand each one to the cloud pass.
    ///
    /// `nonisolated` and driven from `Task.detached`, so it runs on the generic executor:
    /// this is neither the main actor nor — emphatically — the realtime audio thread.
    /// `takeChunk()` is documented as "call from a background Task", and this is that Task.
    nonisolated private func chunkLoop(pipeline: AudioPipeline,
                                       cloud: FalClient?,
                                       generation: Int,
                                       flushRequest: FlushRequestBox) async {
        trace("LOOP[\(generation)]: chunk loop started (cloud client \(cloud == nil ? "absent" : "present"))")
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
                                                cloud: FalClient?,
                                                generation: Int) async -> Bool {
        let wav = chunk.wav
        return await MainActor.run { [weak self] () -> Bool in
            guard let self else { return false }
            // Gate (generation stale-guard included) — unchanged semantics, now simply
            // called in the same job that will register the task it approves.
            guard let handle = self.noteFinalChunk(generation: generation),
                  handle.runCloud, let cloud else { return false }
            // Immutable copies of the MainActor-taken snapshot; String is Sendable, so
            // this is the whole cross-isolation story for the typed span.
            let typedSpan = handle.typedSpan
            let typedSpanSeq = handle.typedSpanSeq
            let utteranceID = handle.id
            let task = Task.detached { [weak self] in
                guard let self else { return }
                await self.cloudPass(wav: wav, utteranceID: utteranceID, typedSpan: typedSpan,
                                     typedSpanSeq: typedSpanSeq,
                                     generation: generation, client: cloud)
            }
            self.registerCloudTask(task, utteranceID: utteranceID, generation: generation)
            return true
        }
    }

    /// Decide, on the main actor, whether this finalized utterance may reach fal.
    ///
    /// ── Why there is a gate at all ────────────────────────────────────────────────────
    /// Routing hallucinated text through the cloud pass *launders* it. A speech model fed
    /// silence or room tone does not return nothing — it invents fluent, plausible Thai. If
    /// that chunk were forwarded to fal, fal would transcribe the same silence and return
    /// something similar, the two would appear to agree, and the UI would then present
    /// invented text as cloud-confirmed. The user's own ears would be the only thing left to
    /// catch it. A confident wrong answer is strictly worse than no answer.
    ///
    /// So an utterance only reaches fal when two independent witnesses agree there was
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
        guard cloudEnabled, cloudAvailable else {
            trace("CLOUD GATE: pass is \(cloudAvailable ? "off" : "unavailable"); not sent")
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

    private func registerCloudTask(_ task: Task<Void, Never>, utteranceID: Int, generation: Int) {
        guard generation == captureGeneration, utteranceID == lastCloudUtteranceID else {
            task.cancel()
            trace("registerCloudTask: superseded before it started; cancelled")
            return
        }
        cloudTask = task
        cloudTaskStartedAt = Date()   // drives the supersede rule in noteFinalChunk
        lifetime.cloudSent += 1; thisCapture.cloudSent += 1
    }

    /// One cloud round trip for one finalized utterance.
    ///
    /// `nonisolated` and only ever entered from `Task.detached` — a ~3 s HTTP request has no
    /// business on the main actor, and `FalClient` is `Sendable` precisely so it can be used
    /// this way. Every UI touch hops explicitly and the generation is checked on the far side
    /// of that hop.
    ///
    /// A failure here is never allowed to disturb anything: the on-device text is already
    /// typed and stays exactly as it is.
    nonisolated private func cloudPass(wav: Data, utteranceID: Int, typedSpan: String,
                                       typedSpanSeq: UInt64,
                                       generation: Int, client: FalClient) async {
        trace("FAL[\(generation)]: sending utterance #\(utteranceID) — \(wav.count) wav bytes, "
            + "\(cloudKeyterms.count) keyterms")
        do {
            let result = try await client.transcribe(wav: wav, keyterms: cloudKeyterms)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            trace(String(format: "FAL[%d]: utterance #%d OK — %.0f ms, %d chars, langProb %.2f",
                         generation, utteranceID, result.elapsedMS, text.count,
                         result.languageProbability))
            await MainActor.run { [weak self] in
                self?.applyCloudResult(text: text, utteranceID: utteranceID,
                                       typedSpan: typedSpan,
                                       typedSpanSeq: typedSpanSeq,
                                       elapsedMS: result.elapsedMS, generation: generation)
            }
        } catch {
            let ns = error as NSError
            let wasCancelled = error is CancellationError
                || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
            let d = describeFalError(error)
            trace("FAL[\(generation)]: utterance #\(utteranceID) FAILED "
                + "(cancelled=\(wasCancelled)) — \(d.summary)")
            await MainActor.run { [weak self] in
                self?.applyCloudFailure(d.summary, utteranceID: utteranceID,
                                        generation: generation, cancelled: wasCancelled)
            }
        }
    }

    private func applyCloudResult(text: String, utteranceID: Int, typedSpan: String,
                                  typedSpanSeq: UInt64,
                                  elapsedMS: Double, generation: Int) {
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
        lastCloudLatencyMS = elapsedMS
        guard !text.isEmpty else {
            lifetime.cloudErrors += 1; thisCapture.cloudErrors += 1
            lastOutcome = "Cloud pass returned nothing; on-device text kept"
            trace("FAL: empty result; on-device text kept")
            settleAfterCloud()
            return
        }

        lastTranscript = text

        if text == injectedForUtterance {
            // Nothing to change: the cloud agrees with what is already in the target app.
            // This is the ONLY case in which "corrected" is a true statement, so it is the
            // only case that gets to say it.
            lifetime.cloudApplied += 1; thisCapture.cloudApplied += 1
            unappliedCloudText = ""
            lastOutcome = String(format: "Cloud confirmed the typed text (%.0f ms)", elapsedMS)
            trace(String(format: "FAL: result matches the typed text exactly (%d chars, %.0f ms)",
                         text.count, elapsedMS))
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
            repairFailure = "typed span too short to match safely (\(typedSpan.count) chars)"
        } else if injector.secureInputActive() {
            // Same policy as the live path: never touch a secure field. This is a quiet
            // refusal to auto-apply, not a broken session — no error flash.
            lifetime.secureInputRefusals += 1; thisCapture.secureInputRefusals += 1
            repairFailure = "secure input active; cloud text shown, not injected"
        } else if text.count * 2 < typedSpan.count || text.count > typedSpan.count * 3 {
            // Size sanity: fal's text should be the same utterance, give or take
            // punctuation and corrections. A wildly different length means the span and
            // the audio chunk drifted apart (the ledger lags the audio cut) -- replacing
            // would swap in text belonging to a different stretch of speech.
            repairFailure = "cloud text size mismatch (span \(typedSpan.count) vs cloud \(text.count) chars)"
        } else if text == typedSpan {
            // The cloud agrees with exactly what was typed for this chunk.
            lifetime.cloudApplied += 1; thisCapture.cloudApplied += 1
            unappliedCloudText = ""
            lastOutcome = String(format: "Cloud confirmed the typed text (%.0f ms)", elapsedMS)
            trace(String(format: "FAL: result matches the typed span exactly (%d chars, %.0f ms)",
                         text.count, elapsedMS))
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
            lastOutcome = String(format: "Cloud auto-corrected the typed text (%.0f ms)", elapsedMS)
            trace("FAL: auto-corrected span (\(typedSpan.count) -> \(text.count) chars)")

            // ── Bookkeeping: the recogniser-side mark is NOT touched here ───────────
            // `injectedForUtterance` is consumed by `deliver()` against RECOGNIZER text,
            // so the mark must stay in recognizer-text units at all times. The cloud text
            // is a document-side rewrite in fal's own units: fal adds spaces and
            // punctuation, so the strings differ. Folding it into the mark (as this block
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
        lastOutcome = "Cloud text ready but NOT typed — use “Copy cloud correction”"
        trace(String(format: "FAL: result differs from the typed text "
                   + "(cloud %d chars vs typed %d chars, %.0f ms); NOT applied — ",
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
                                   generation: Int, cancelled: Bool) {
        // Id-guarded for the same reason as applyCloudResult: a superseded request's
        // cancellation hop must not clear the NEW task registered after it.
        if utteranceID == lastCloudUtteranceID {
            cloudTask = nil
            cloudTaskStartedAt = nil
        }
        guard generation == captureGeneration, utteranceID == lastCloudUtteranceID else { return }
        if !cancelled { lifetime.cloudErrors += 1; thisCapture.cloudErrors += 1 }
        lastOutcome = cancelled
            ? "Cloud pass cancelled; on-device text kept"
            : "Cloud pass failed — \(summary). On-device text kept."
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

    @objc private func toggleCloud() {
        guard cloudAvailable else { return }
        cloudEnabled.toggle()
        UserDefaults.standard.set(cloudEnabled, forKey: Self.cloudPassDefaultsKey)
        trace("MENU: cloud accuracy pass -> \(cloudEnabled ? "on" : "off")")
        // The chunk loop is created (or skipped) once, at session start, from the state
        // read there. `isCapturing && chunkTask == nil` identifies exactly "this session
        // started realtime-only": say so, or the missing cloud activity looks like a bug.
        if cloudEnabled && isCapturing && chunkTask == nil {
            trace("MENU: cloud pass enabled mid-session — takes effect at the NEXT session "
                + "(tap \(defaultHotkeyName) to stop, then again to start)")
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
        autoCorrectEnabled.toggle()
        UserDefaults.standard.set(autoCorrectEnabled, forKey: Self.autoCorrectDefaultsKey)
        trace("MENU: auto-correct from cloud -> \(autoCorrectEnabled ? "on" : "off")")
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
    /// `open` does not forward environment variables, so drive the inner Mach-O directly:
    ///     MICTEST_AUTOSTART=1 ~/Desktop/MicTest.app/Contents/MacOS/MicTest
    /// Bundle identity and signature still resolve (Bundle.main is the .app), so TCC is
    /// unaffected.
    private func maybeArmAutostart() {
        guard ProcessInfo.processInfo.environment["MICTEST_AUTOSTART"] == "1" else { return }
        trace("MICTEST_AUTOSTART=1 — simulated hold at t+1.5s, release at t+10s, quit at t+16s")
        let schedule: [(TimeInterval, Selector)] = [
            (1.5, #selector(autostartBegin)),
            (10.0, #selector(autostartEnd)),
            (16.0, #selector(autostartQuit))
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
            + "secureInputRefusals=\(lifetime.secureInputRefusals)")
        trace("AUTOSTART CLOUD SUMMARY: available=\(cloudAvailable) enabled=\(cloudEnabled) "
            + "finalChunks=\(lifetime.finalChunks) sent=\(lifetime.cloudSent) "
            + "applied=\(lifetime.cloudApplied) unapplied=\(lifetime.cloudUnapplied) "
            + "errors=\(lifetime.cloudErrors) skipped=\(lifetime.cloudSkipped) "
            + "lastCloudLatency=\(cloudLatency) setupError=\(falSetup.error ?? "(none)") "
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
