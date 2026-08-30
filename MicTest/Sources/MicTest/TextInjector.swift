import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog

// =============================================================================
// MARK: - Why this file looks the way it does
// =============================================================================
//
// If you are here at 2am because a Thai paste came out as mojibake, read this
// header first. It records the decisions that are *deliberate* so you do not
// "fix" one of them and reintroduce a bug we already paid for.
//
// ── 1. We never synthesise per-character keystrokes ──────────────────────────
//
// The obvious implementation is `CGEventKeyboardSetUnicodeString`: build a key
// event, staple the transcript onto it, post it. It is wrong for Thai in two
// independent ways, either of which alone would sink it.
//
//   (a) Virtual-keycode re-translation. Apple's own documentation concedes that
//       frameworks "may ignore the Unicode string ... and do their own
//       translation based on the virtual keycode." With the Thai *Kedmanee*
//       layout active that is exactly what happens: the receiving app re-reads
//       the keycode through the Thai layout and prints whatever Kedmanee has on
//       that physical key instead of the string we attached. Measured on this
//       machine, virtual keycode 9 produces:
//
//           com.apple.keylayout.ABC              -> "v"
//           com.apple.keylayout.Thai             -> "อ"
//           com.apple.keylayout.Thai-PattaChote  -> "ห"
//           com.apple.keylayout.Thai-QWERTY      -> "ว"
//
//   (b) The undocumented ~20 UTF-16 unit delivery limit per event. Thai is a
//       combining script: one grapheme cluster is a base consonant plus zero or
//       more vowel signs and tone marks, so grapheme count and UTF-16 count
//       diverge badly. Measured:
//
//           "เดี๋ยว deploy ให้ก่อนนะ"  -> 19 grapheme clusters, 23 UTF-16 units
//           first 20 clusters of a longer Thai sentence -> 27 UTF-16 units
//
//       Any naive "chunk at 20 units" scheme therefore cuts *inside* a cluster,
//       orphaning a sara/tone mark from its base consonant. The user sees
//       floating diacritics and dotted circles. The exact ratio is
//       string-dependent (do not hardcode 26, or 27, or anything), but it is
//       reliably above 20 for real Thai text, which is what matters.
//
// So: clipboard-paste, like every serious dictation app. Cost: one Cmd+V in the
// target's undo stack, and a brief round trip through the user's pasteboard.
//
// ── 2. Two delivery paths, in order of preference ────────────────────────────
//
//   Path A — Accessibility direct insertion. If the focused element lets us set
//     kAXSelectedTextAttribute, we write the text straight into it. No
//     clipboard, no keystroke, no undo-stack pollution, no modifier races.
//     This works in AppKit text views (Notes, Mail, TextEdit, Safari fields,
//     Xcode, native IDEs).
//
//   Path B — clipboard + synthetic Cmd+V. The fallback, and the one that will
//     actually run in Electron apps (VS Code, Cursor, Slack, Notion, Discord),
//     because Chromium does not build an AX tree unless accessibility is
//     explicitly switched on. There is no point trying to make Path A work
//     there; it is a Chromium architecture decision, not a bug we can route
//     around.
//
//   Which path ran is logged. Check `log stream --predicate 'category ==
//   "TextInjector"'` when a paste goes wrong — the first thing you want to know
//   is whether you are debugging AX or the clipboard.
//
//   `replaceLastInserted` is layered the same way, and was not always: it was
//   AX-only until 2026-08-27, which meant the Thai-revision repair could only
//   land in the apps that never needed it. OSLog measured the AX write refused
//   158 of 158 times in the field, so the repair refused in Electron, Chromium
//   and Cursor every single time — and `commonPrefixLength` routes a Thai tone
//   mark to repair rather than append, which is 2 repairs in a 7-partial
//   `สวัสดีครับ` sequence. Its path B differs from the one above in one
//   important way: the SPAN is verified before the write and the EFFECT is
//   verified after it, and nothing is claimed in between. The span comes from
//   the same AX checks path A uses, including a selection the field itself
//   echoes back; the effect is a collapsed caret at an offset only a correct
//   replacement produces. Read that function's header before touching it.
//
// ── 3. Privacy note ──────────────────────────────────────────────────────────
//
// The transcript is the user's speech. It is NEVER logged, not even at debug
// level, not even truncated. We log its length and nothing else. Do not add a
// `\(text)` to any log line in this file.
//
// =============================================================================

/// Delivers transcribed text into whatever application currently has keyboard
/// focus.
///
/// Marked `@MainActor` in its entirety: `TextInjecting`'s members are
/// main-actor-isolated, CGEvent posting and the Accessibility APIs expect the
/// main thread, and the mutable clipboard-restore bookkeeping below needs a
/// single well-defined isolation domain under Swift 6 strict concurrency.
@MainActor
final class TextInjector: TextInjecting {

    // MARK: - Timing constants
    //
    // Every number here has a reason. If you change one, change the comment.

    /// Upper bound on any single synchronous Accessibility round trip.
    ///
    /// AX calls are synchronous IPC into the *target* application's run loop. A
    /// beachballing target would otherwise block our main thread for the system
    /// default (6 s), freezing the dictation HUD and making PhayaVoice look like
    /// the broken app. A healthy app answers in well under a millisecond, so
    /// 250 ms is ~1000x headroom while still being under the threshold where a
    /// user reads the HUD as hung.
    private static let axMessagingTimeout: Float = 0.25

    /// How long our text stays on the pasteboard before we put the user's
    /// clipboard back.
    ///
    /// This is the load-bearing constant of the whole clipboard path. The target
    /// app reads the pasteboard *asynchronously*, after our synthetic key event
    /// is delivered. Native AppKit apps read within a few milliseconds; Electron
    /// apps route the key event through the renderer process first, which
    /// routinely adds 100-300 ms. Restore too early and the app pastes the
    /// *restored* (old) clipboard — the classic "it pasted what I copied an hour
    /// ago" bug, which is far worse than a slightly long clipboard borrow.
    ///
    /// 700 ms sits comfortably past observed Electron latency while staying
    /// short enough that a user who hits Cmd+V manually right after dictating
    /// still gets their own clipboard back.
    private static let pasteSettleTimeout: TimeInterval = 0.7

    /// Granularity of the settle loop.
    ///
    /// Fine enough to notice another process claiming the pasteboard promptly
    /// and to react to a superseding injection; coarse enough that the polling
    /// itself costs nothing.
    private static let restorePollInterval: TimeInterval = 0.05

    /// How long we let an Accessibility *selection* write settle before
    /// concluding the field ignored it, and how often we look.
    ///
    /// The single 40 ms sleep this replaces was sized for an AppKit text view,
    /// which applies the write on the same runloop turn. Chromium — the case
    /// the repair fallback below exists for — is architecturally different:
    /// setting kAXSelectedTextRange there dispatches an action to the *renderer*
    /// process and returns before the renderer has acted. This file's own
    /// clipboard note measures Electron round trips at 100-300 ms, so a 40 ms
    /// read-back would declare "the field clamped the selection" on a field
    /// that was about to comply, and the fallback would never be reached in the
    /// only apps that need it.
    ///
    /// Polling rather than sleeping once means a native app matches on the
    /// FIRST read and pays nothing at all; only a field that is genuinely
    /// refusing burns the whole budget, and that happens at most twice per
    /// session because `main.swift` latches final-only mode on the first
    /// refusal. Honest cost note: each poll is an AX round trip bounded by
    /// `axMessagingTimeout`, so a wedged target can overshoot this by one
    /// message timeout.
    private static let axSelectionSettleTimeout: TimeInterval = 0.4
    private static let axSelectionPollInterval: TimeInterval = 0.025

    /// How long we wait for a synthesised repair keystroke (Cmd+V, or a bare
    /// Delete) to come back as a collapsed caret at exactly the offset a
    /// correct replacement would produce.
    ///
    /// This is the receipt that lets the repair fallback refuse honestly. The
    /// clipboard path proper cannot have one — `changeCount` is a write
    /// counter, there is no read receipt (see `scheduleReceiptSequencedRestore`)
    /// — but a *replacement* has a second, independent signature the paste
    /// itself cannot fake: the selection we established collapses to a caret at
    /// `selectionStart + replacement.utf16.count`. An insertion that failed to
    /// replace lands the caret one selection-length further along, so the two
    /// outcomes are distinguishable by a single cheap read.
    ///
    /// Sized past the same 100-300 ms Electron round trip as above. It costs
    /// nothing on the happy path in a native app and roughly one round trip in
    /// Electron; it is only paid on a repair, never on an ordinary partial.
    private static let repairEchoTimeout: TimeInterval = 0.4

    /// Hard ceiling on the total time `replaceLastInserted` may spend POLLING,
    /// summed across all three of the settle loops it can run.
    ///
    /// Why a ceiling, and why here rather than in the three budgets above.
    /// `HotkeyMonitor` attaches its event tap's run-loop source to
    /// `CFRunLoopGetMain()` (`HotkeyMonitor.swift:514`) and its mask now includes
    /// `.keyDown`, so that tap is serviced by the very run loop these polls
    /// block. A main thread that stops answering gets the tap disabled with
    /// `.tapDisabledByTimeout`; `HotkeyMonitor:576` re-enables it, but every
    /// event delivered during the disable is gone — and if one of them was the
    /// toggle-OFF tap, the microphone stays live with no off-switch. That is the
    /// exact failure that file exists to prevent, so it outranks a good repair.
    ///
    /// The three budgets are each individually right and NONE of them has safe
    /// slack to give back:
    ///
    ///   • `becomes: target` — burning it in full means we return WITHOUT
    ///     posting, so shortening it saves nothing in the case that matters and
    ///     costs repairs in Chromium, which is the case it was sized for.
    ///   • `movesOff: target` — load-bearing for CORRECTNESS, not for speed.
    ///     Inside the budget, an AX write that complies late is seen and no
    ///     keystroke is posted; outside it we post, and if the write then lands
    ///     the document gets the replacement twice. Shortening it trades
    ///     document integrity for latency, which is the wrong direction.
    ///   • `repairEchoTimeout` — shortening this only converts a success into an
    ///     honest refusal with the selection left standing, which is the one
    ///     failure mode this design has already proved safe (see the closing
    ///     comment of `replaceLastInserted`, and the harness control arm that
    ///     produces a hybrid document when that decision is reversed).
    ///
    /// So the ceiling clips the SUM instead, and the last settle absorbs the
    /// clipping — the only one whose degraded outcome is already safe. In the
    /// case that fires routinely (Electron: AX reads sub-millisecond, AX writes
    /// inert) the serial cost is one 100-300 ms renderer round trip for the
    /// range write, the full 400 ms `movesOff` burn because the write is inert,
    /// and one more 100-300 ms round trip for the paste receipt — this file's
    /// own Electron figures put that at ~1.1 s, twice per Thai utterance. At
    /// 0.9 s the first two are untouched and the receipt still keeps ~200 ms,
    /// which covers the middle of that band.
    ///
    /// HONEST INPUT: the threshold at which the window server disables an
    /// unresponsive tap is NOT published by Apple and was NOT measured here —
    /// measuring it needs a probe binary holding assistive access, which this
    /// machine does not grant and granting is a security-settings change. So
    /// this constant is not "provably under threshold T". What it is: the
    /// routinely-incurred block drops ~200 ms and the pathological one ~900 ms,
    /// with no correctness traded for either.
    private static let repairPollBudget: TimeInterval = 0.9

    /// Per-message timeout for the repair's OWN Accessibility traffic — i.e.
    /// everything after the prologue, which keeps `axMessagingTimeout`.
    ///
    /// `axMessagingTimeout` deliberately stays at 250 ms: `inject()` uses it on
    /// every partial, so lowering it there would change the AX-vs-clipboard
    /// routing decision for every injection in the app. That is a far larger
    /// behavioural change than this one and it is not measurable from here. This
    /// tighter value is set on the already-captured focused element, so its
    /// blast radius is exactly one `replaceLastInserted` call.
    ///
    /// What it buys: each settle poll is an AX round trip, so a wedged target
    /// overshoots a settle budget by one message timeout — 100 ms rather than
    /// 250 ms, three times over. It does nothing for the case that actually
    /// kills the tap (in Electron these reads are sub-millisecond); it clips the
    /// pathological tail only. 100 ms is still ~100x the reads measured in the
    /// apps this path exists for.
    private static let repairMessagingTimeout: Float = 0.1

    /// Wall-clock ceiling on `snapshotPasteboard`.
    ///
    /// The byte budget below bounds how much we COPY; it never bounded how long
    /// we WAIT. `data(forType:)` forces a lazy promise, which is a synchronous
    /// IPC into whichever app owns the pasteboard, and AppKit exposes no timeout
    /// for it. So — stated plainly rather than papered over — this CANNOT bound
    /// one fetch, only the decision to start another: a single beachballing
    /// provider can still overrun it by exactly one fetch.
    ///
    /// It needs a bound because it runs on the main actor inside the same window
    /// as the polls above, and it also tightens the ordinary `injectViaClipboard`
    /// path, which snapshots on every partial.
    private static let snapshotTimeBudget: TimeInterval = 0.15

    /// Cumulative byte budget for snapshotting the user's existing clipboard.
    ///
    /// Reading a pasteboard type *forces* any lazy promise behind it, which can
    /// mean a multi-hundred-megabyte image materialising on the main thread. We
    /// check the running total before fetching each subsequent representation
    /// and stop once we are over budget, so at worst we pay for one oversized
    /// item rather than all of them. Types are fetched most-important-first
    /// (see `prioritizedTypes`) so what we drop is the least valuable.
    private static let maxSnapshotBytes = 8 * 1024 * 1024

    /// Fallback virtual keycode for "v" — the position it occupies on ANSI /
    /// QWERTY and the overwhelming majority of layouts. Only used if layout
    /// resolution fails outright.
    private static let fallbackVKeyCode: CGKeyCode = 9

    /// Order in which we snapshot pasteboard representations, most valuable
    /// first, so that the byte budget above truncates the least useful ones.
    private static let prioritizedTypes: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .rtfd, .html, .fileURL, .URL, .tabularText, .pdf, .png, .tiff,
    ]

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.boombignose.PhayaVoice",
        category: "TextInjector"
    )

    /// The one refusal reason that means "we were about to type into somebody
    /// else's window". Hoisted to a constant so both repair shapes return the
    /// SAME string: this is the reason a field report most needs to be able to
    /// grep for, and two near-identical hand-written variants would defeat that.
    /// The distinguishing detail (which branch we were in) goes to OSLog, where
    /// it belongs, rather than into the HUD.
    private static let focusMovedRefusal =
        "keyboard focus moved after the selection was verified; the repair keystroke was NOT "
        + "posted and nothing was changed"

    /// The refusal returned when a selection is standing in the target field
    /// and the field would not collapse it. Hoisted next to `focusMovedRefusal`
    /// for the same reason: `main.swift` classifies refusals by matching on
    /// their text, so there must be exactly ONE spelling of each of them.
    private static let standingSelectionRefusal =
        "a selection is standing in the field and could not be collapsed; not typing over it"

    // MARK: - Clipboard restore bookkeeping

    /// A flattened copy of every representation of every item that was on the
    /// pasteboard before we borrowed it. `nil` when we are not holding one.
    private var savedClipboard: [[NSPasteboard.PasteboardType: Data]]?

    /// Monotonic token identifying the current borrow. Bumped on every
    /// injection so that an in-flight restore from a previous injection can tell
    /// it has been superseded and bow out.
    private var restoreGeneration: Int = 0

    /// True between "we wrote our text to the pasteboard" and "we put the user's
    /// clipboard back (or deliberately decided not to)".
    ///
    /// This flag exists to prevent a genuinely destructive bug: if a second
    /// dictation starts while the first restore is still pending, snapshotting
    /// again would capture *our own injected text* as "the user's clipboard" and
    /// then faithfully restore that, permanently destroying whatever the user
    /// had actually copied.
    private var restorePending = false

    /// The `changeCount` the pasteboard had immediately after we wrote our text.
    /// Anything else means somebody else has since taken ownership.
    private var ourChangeCount: Int = 0

    init() {}

    // MARK: - TextInjecting

    /// True while *any* process on the system holds Secure Event Input.
    ///
    /// Secure Event Input is process-global, not per-window: while it is held,
    /// machine-wide event taps are dead and synthetic keyboard events are
    /// swallowed. The obvious holders are password fields, Terminal's "Secure
    /// Keyboard Entry" menu item, and 1Password's unlock sheet — but in practice
    /// the most common cause on a developer's machine is Cursor, which leaks the
    /// flag several times a day and does not release it until the app is
    /// refocused or restarted.
    ///
    /// If a user reports "dictation silently stopped working", this is the first
    /// thing to check. From a shell:
    ///
    ///     ioreg -l -w 0 | grep SecureInput
    ///
    /// shows which PID is holding it.
    func secureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// Deliver `text` into the focused application.
    ///
    /// - Returns: `nil` on success, otherwise a short human-readable reason
    ///   suitable for showing in the HUD. Never throws; every runtime failure
    ///   comes back as a string.
    ///
    /// WHY THIS IS TWO METHODS AND NOT ONE WITH A DEFAULT ARGUMENT. The obvious
    /// spelling is `inject(_ text: String, collapseStandingSelection: Bool =
    /// false)` — one method, existing call sites untouched. It does not
    /// compile: Swift matches protocol witnesses by FULL name, that method's
    /// name is `inject(_:collapseStandingSelection:)`, and `TextInjecting`
    /// requires `inject(_:)`. swiftc says "type 'TextInjector' does not conform
    /// to protocol 'TextInjecting'" and offers to add a stub. So the
    /// one-argument overload below IS the conformance, and it is also the
    /// documented default — which is why no default value is spelled on the
    /// parameter of the two-argument form: with the forwarder present, a
    /// default there would make `inject(x)` resolvable two ways for no gain.
    func inject(_ text: String) -> String? {
        inject(text, collapseStandingSelection: false)
    }

    /// - Parameter collapseStandingSelection: when `true`, a selection standing
    ///   in the focused field is collapsed to its END before anything is
    ///   written, and the injection is REFUSED if it cannot be. Read
    ///   `collapseStandingSelectionToEnd` before changing anything about it:
    ///   the direction is load-bearing and the caller — not this file — is the
    ///   one that knows whether a standing selection is the user's or a mess
    ///   left by a refused repair.
    func inject(_ text: String, collapseStandingSelection: Bool) -> String? {
        guard !text.isEmpty else {
            // Nothing to deliver is not a failure — an empty transcript just
            // means the user held the hotkey and said nothing.
            return nil
        }

        // Refuse under Secure Event Input BEFORE anything else, and in
        // particular before trying the Accessibility path. If focus is in a
        // password field, reaching it by a different API is a security
        // regression, not a clever fallback.
        if secureInputActive() {
            Self.log.notice("Refusing injection: Secure Event Input is held.")
            return "Secure input is active (password field, Terminal secure entry, "
                + "or a Cursor/Electron leak). Click into a normal text field and try again."
        }

        // Both delivery paths need Accessibility: the AX path obviously, and
        // CGEvent.post to the HID tap is gated on it too. One check covers both.
        guard AXIsProcessTrusted() else {
            Self.log.notice("Refusing injection: Accessibility permission not granted.")
            return "PhayaVoice needs Accessibility permission. Grant it in System Settings > "
                + "Privacy & Security > Accessibility, then try again."
        }

        // A standing selection is a hazard BOTH paths below would silently
        // consume, and neither of them could tell you afterwards. Path A writes
        // `kAXSelectedText`, whose documented semantics are "replace the
        // selection, or insert at the caret when there is none" — the second
        // half is what makes it an append, the first half eats the selection.
        // Path B's Cmd+V replaces a selection for the same reason. Both replace
        // functions in this file refuse outright on `caret.length != 0`
        // ("a selection is active; not replacing"); this one never had that
        // guard because until the re-anchor change no caller could reach it
        // with a selection standing.
        //
        // One can now. Path B of a refused repair DELIBERATELY leaves the stale
        // tail selected rather than collapsing the caret (see the closing
        // comment of `replaceLastInserted` — a late paste must still land over
        // it), and that was safe under its old contract, in which the caller
        // stopped typing for the rest of the utterance. The caller re-anchors
        // and keeps typing now, so the very next append would arrive with the
        // selection still standing and swallow the whole selected span.
        //
        // The CALLER decides, because refusing is not always right: the first
        // injection of an utterance should keep replace-the-selection
        // semantics, since dictating over text the user selected by hand is a
        // feature, not an accident.
        //
        // COST, since this runs on every partial the caller asks it for: a
        // second systemwide focused-element copy (`insertViaAccessibility`
        // takes its own) plus one selection read — two AX round trips, which
        // this file's own measurements put in the sub-millisecond band even in
        // Electron. The 40 ms settle inside the helper is only ever paid when a
        // selection is ACTUALLY standing, which is once per refused repair.
        if collapseStandingSelection {
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, Self.axMessagingTimeout)
            if let focused = copyElement(systemWide, attribute: kAXFocusedUIElementAttribute) {
                AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)
                if let reason = collapseStandingSelectionToEnd(focused) {
                    // Return HERE. Falling through would reach the clipboard
                    // path, which pastes over exactly the selection we just
                    // failed to clear — the outcome this guard exists for.
                    Self.log.notice(
                        "Refusing injection: a selection is standing in the focused field and the field would not collapse it."
                    )
                    return reason
                }
            }
            // No focused element to ask. Proceed: that is unchanged behaviour
            // (the clipboard path needs no AX element and often still works),
            // and refusing on an AX tree we cannot copy would turn one
            // unreadable attribute into "dictation does not work in this app".
        }

        let target = frontmostAppInfo()
        let targetID = target?.bundleID ?? "unknown"

        // Path A: direct Accessibility insertion.
        if insertViaAccessibility(text) {
            Self.log.info(
                "Injected \(text.count, privacy: .public) chars via AX direct insertion into \(targetID, privacy: .public)"
            )
            return nil
        }

        // Path B: clipboard + synthetic Cmd+V.
        Self.log.info(
            "AX direct insertion unavailable for \(targetID, privacy: .public) (expected for Electron apps); falling back to clipboard paste"
        )
        return injectViaClipboard(text, targetID: targetID)
    }

    /// Collapse a selection standing in `focused` to its END, so an append
    /// cannot eat it.
    ///
    /// - Returns: `nil` when there was nothing to collapse, when the collapse
    ///   is confirmed, or when the field's selection could not be read at all;
    ///   the refusal reason when a selection IS standing and the field would
    ///   not clear it.
    ///
    /// ── Why END, and why it is not a preference ─────────────────────────────
    ///
    /// The selection this exists for is the stale tail that a refused repair
    /// targeted and left selected. That text is STILL IN THE DOCUMENT, and the
    /// caller's re-anchored ledger is built on exactly that assumption: it
    /// treats the stale tail as part of what precedes the new text. Collapsing
    /// to the selection's START would put every subsequent append BEFORE the
    /// stale text, producing a document the ledger cannot describe — and the
    /// next repair's content check would then compare `expecting` against a
    /// tail that has the stale span sitting after it. Collapsing to the END
    /// keeps document order and ledger order the same. So a field that
    /// collapses somewhere else of its own accord (several collapse to the
    /// selection start on a caret write) must be REFUSED rather than accepted,
    /// which is why the read-back below demands the exact offset instead of
    /// merely "no selection any more".
    ///
    /// ── What this does NOT protect against (accepted, and bounded) ──────────
    ///
    /// The selection was left standing precisely because a repair keystroke —
    /// a Cmd+V or a Delete — was posted and never confirmed within the echo
    /// budget. "Late" has no hard bound, so that keystroke can still land AFTER
    /// this collapse: the paste then inserts at the collapsed caret instead of
    /// over the selection (document gains the replacement text an extra time),
    /// or the Delete removes one unit at the caret instead of the selection.
    /// Either way the document and the ledger diverge by a BOUNDED amount, and
    /// the divergence is detected — not silently carried — by the very next
    /// repair's `expecting` check, which refuses and lets the caller re-anchor
    /// on a bounded stale count. That is strictly better than the behaviour
    /// this replaces, where the same late keystroke was possible AND the
    /// ordinary case silently ate the entire selected span with nothing
    /// detecting it afterwards.
    ///
    /// It also cannot help a field whose selection we cannot read; see the
    /// first guard for why proceeding is the right answer there.
    private func collapseStandingSelectionToEnd(_ focused: AXUIElement) -> String? {
        guard let standing = selectedTextRange(of: focused) else {
            // Cannot guard what cannot be read. This is today's behaviour for
            // every field whose range read fails — `inject` has never asked —
            // and refusing instead would break dictation into every app whose
            // selection attribute is unreadable, to protect against a hazard we
            // have no evidence is present.
            Self.log.debug(
                "Standing-selection check: kAXSelectedTextRange was unreadable; proceeding without it."
            )
            return nil
        }
        // `length == 0` is the ordinary caret: nothing to do. A NEGATIVE length
        // is a malformed read rather than a selection, and `location + length`
        // would move the caret BACKWARD — a document change made on garbage
        // input — so it is treated exactly like the unreadable case above.
        guard standing.length > 0 else {
            if standing.length < 0 {
                Self.log.debug(
                    "Standing-selection check: field reported a negative selection length; proceeding without it."
                )
            }
            return nil
        }

        var collapsed = CFRange(location: standing.location + standing.length, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &collapsed) else {
            return Self.standingSelectionRefusal
        }
        guard AXUIElementSetAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, rangeValue
        ) == .success else {
            return Self.standingSelectionRefusal
        }

        // Read back, with the one-beat settle both replace paths already use:
        // an AX set is synchronous IPC but the application can apply it a
        // runloop turn late, and concluding "the field refused" from the
        // immediate read alone is the mistake `insertViaAccessibility`'s
        // comment block documents at length.
        var applied = selectedTextRange(of: focused)
        if !(applied?.location == collapsed.location && applied?.length == 0) {
            usleep(40_000)   // 40 ms settle; AX set is IPC, application can lag a runloop turn
            applied = selectedTextRange(of: focused)
        }
        guard let applied, applied.location == collapsed.location, applied.length == 0 else {
            return Self.standingSelectionRefusal
        }

        Self.log.notice(
            "collapsed a standing \(standing.length, privacy: .public)-unit selection to its end before appending (left by a refused repair)"
        )
        return nil
    }

    // MARK: - Frontmost application

    /// Name and bundle identifier of the app that currently owns focus.
    ///
    /// Exposed for the glossary engine, which will use per-app context to bias
    /// transcription (English identifiers in an IDE, prose in Mail, and so on).
    /// Returns `nil` when there is no frontmost app or it has no bundle ID
    /// (some helper and command-line processes).
    public func frontmostAppInfo() -> (name: String, bundleID: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else { return nil }
        return (app.localizedName ?? bundleID, bundleID)
    }

    // MARK: - Path A: Accessibility direct insertion

    /// Try to write `text` directly into the focused UI element by setting
    /// `kAXSelectedTextAttribute`.
    ///
    /// Semantics of that attribute: it *replaces the current selection*, or
    /// inserts at the caret when the selection is empty — which is exactly the
    /// behaviour we want from a paste, minus the clipboard and the undo entry.
    ///
    /// Modifier hygiene: this path posts no events at all — AX attribute writes
    /// are synchronous IPC, not keystrokes — so the physically-held Right-Option
    /// hotkey cannot leak into it. Only the clipboard path below needs explicit
    /// event flags.
    ///
    /// - Returns: `true` only when we have positive evidence the text landed.
    ///   Anything ambiguous returns `false` so the caller falls back to the
    ///   clipboard path.
    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axMessagingTimeout)

        guard let focused = copyElement(systemWide, attribute: kAXFocusedUIElementAttribute) else {
            return false
        }
        AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)

        // Ask permission before acting. Elements that are not text (buttons,
        // whole windows, the Electron root element) say no here, which is the
        // cheap and correct way to detect "this app has no usable AX text".
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            focused, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else {
            return false
        }

        // Snapshot the insertion point so we can tell a real insertion from a
        // polite lie (see the verification note below).
        let rangeBefore = selectedTextRange(of: focused)

        guard AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success else {
            return false
        }

        // Verification, deliberately conservative.
        //
        // Some elements report kAXSelectedText as settable and then silently do
        // nothing. If we trusted the .success return there, the user's speech
        // would vanish with no fallback — the worst outcome this file has.
        //
        // But the opposite mistake is also bad: a false negative here means we
        // fall through to the clipboard path and paste the text a SECOND time.
        // So we only declare failure on solid evidence of a no-op: we could read
        // a valid range both before and after, and they are identical. Any
        // insertion of non-empty text necessarily moves the caret (an empty
        // `text` was rejected by the caller), so an unchanged range is proof
        // nothing happened. If either read failed, we trust the .success.
        if let before = rangeBefore, let after = selectedTextRange(of: focused) {
            if before.location == after.location && before.length == after.length {
                // Some fields apply the AX write ASYNCHRONOUSLY: the set
                // returns .success but an immediate re-read still shows the
                // old caret. Seen in production — the same runloop-turn lag
                // both replace paths below already absorb with a settle and
                // one re-read. Declaring the no-op on the immediate read alone
                // is worse than either mistake this comment block weighs: in
                // an async-applying field the text HAS landed via AX, and the
                // clipboard fallback then pastes the SAME text a second time.
                // So wait one beat and re-read once; only a caret that is
                // STILL unchanged is solid evidence of a no-op.
                usleep(40_000)   // 40 ms settle; AX set is IPC, application can lag a runloop turn
                guard let settled = selectedTextRange(of: focused) else {
                    // The re-read failed: no solid evidence of a no-op, so per
                    // the rule above we trust the .success.
                    return true
                }
                if before.location == settled.location && before.length == settled.length {
                    Self.log.notice("AX reported kAXSelectedText settable but the caret did not move (even after a 40 ms settle); treating as a no-op.")
                    return false
                }
            }
        }
        return true
    }

    /// Replace the last `count` grapheme clusters before the caret with `text`.
    ///
    /// Guarantee: this either replaces exactly the intended range or does
    /// nothing and returns a reason. `count` is a HARD CEILING — no path in
    /// here can remove more than the `count` clusters the caller says this app
    /// itself typed — and on ANY ambiguity we leave the document alone and let
    /// the caller surface the reason instead.
    ///
    /// ── Two paths, mirroring `inject()` ─────────────────────────────────────
    ///
    /// This was AX-only until 2026-08-27, and that turned out to be a delivery
    /// bug wearing a safety property's clothes. Field measurement (OSLog,
    /// `TextInjector.swift:341` at baseline `9bba5c9`): the Accessibility
    /// *write* was refused **158 of 158 times**, so every real injection in the
    /// sampled sessions went through the clipboard. An AX-only repair therefore
    /// succeeded exactly where `inject`'s path A already worked — TextEdit,
    /// Mail, Notes, Xcode — and refused exactly where path B was needed:
    /// Electron, Chromium, Slack, Cursor, VS Code, i.e. the apps this user
    /// actually works in.
    ///
    /// And the repair is not a rare event. `main.swift`'s `commonPrefixLength`
    /// compares Characters, so adding a Thai tone mark to the trailing cluster
    /// yields a *different* Character ("ก" vs "ก่") and routes to repair rather
    /// than to the cheap append: **2 repairs in a 7-partial `สวัสดีครับ`
    /// sequence, and at least one repair in all six measured test sequences.**
    /// So in those apps the FIRST revision of an utterance refused, `main.swift`
    /// latched `finalOnlyInjection`, the remaining partials were skipped, and
    /// the FINAL reconciled through the same refusing path — the document kept
    /// "ก" and "ก่อน" never arrived.
    ///
    ///   Path A — set kAXSelectedText over the selection. Preferred, tried
    ///     first, and unchanged. One synchronous IPC: no clipboard, no
    ///     keystroke, no undo entry.
    ///
    ///   Path B — Cmd+V (or, for a pure retraction, a single Delete) over the
    ///     SAME selection, which by then the field has echoed back to us.
    ///     Reached only on solid evidence that path A was a silent no-op.
    ///
    /// ── Why path B is not a blind edit ──────────────────────────────────────
    ///
    /// It posts a keystroke, but every guard below has already run and passed
    /// before it fires, and the span being removed is an AX *range the field
    /// itself confirmed by read-back* — never a count of backspaces.
    ///
    /// Every guard EXCEPT one runs against `focused`, captured at entry, and a
    /// keystroke does not go to `focused` — it goes to whatever holds keyboard
    /// focus when it is delivered. That gap is closed by `focusIsStill`,
    /// re-asked immediately before each of the two posts; read its comment,
    /// because it is the difference between "verified" and "verified something
    /// else". And `expecting` must be at least 3 grapheme clusters here even
    /// though path A accepts one, because a one-character content check is not
    /// an identification.
    ///
    /// That is what the 158/158 measurement actually licenses. Those refusals
    /// are all from the caret-did-not-move detector in `insertViaAccessibility`,
    /// which is only reachable after the systemwide focused-element copy
    /// succeeds, `AXUIElementIsAttributeSettable` returns settable, the AX set
    /// returns .success, and THREE separate kAXSelectedTextRange reads succeed.
    /// In other words: in these apps AX *reads* work and only AX *writes* are
    /// inert. (Re-measured 2026-08-27: 59 such notices persisted in the last
    /// 36 h of OSLog, 59 of 59 from that same detector, zero from the settable
    /// gate.) So we verify by reading and only then write by keystroke, which
    /// is strictly stronger than writing blind.
    ///
    /// This also DISSOLVES the unit problem rather than solving it. A
    /// synthesised backspace count would have to be expressed in the unit the
    /// target app consumes, and that unit is not ours: AppKit and Blink delete
    /// by extended grapheme cluster, readline in a terminal deletes by code
    /// point — so "ก่" is one backspace in one and two in the other, and a ZWJ
    /// emoji is one or three. We never compute such a count. The only keystroke
    /// here that can delete anything is a single Delete against a selection the
    /// field has confirmed is non-empty and exactly `count` clusters wide,
    /// which removes the selection and nothing else in all of them.
    ///
    /// Honest limits. A read-only AX text surface (Terminal.app's scrollback)
    /// still refuses at the settable gate, as it should — nothing here helps
    /// there. And whether Chromium's kAXSelectedTextRange *write* moves the
    /// real selection was not measurable from this machine (a probe binary and
    /// System Events both lack assistive access, and granting it is a security
    /// settings change). If it does not, the clamped-range read-back below
    /// refuses exactly as it does today and path B is simply never entered —
    /// the change is inert there, not unsafe.
    ///
    /// Units: `count` is in grapheme clusters (Swift `Character`), matching the
    /// caller's bookkeeping. AX ranges are UTF-16 code units, so we convert by
    /// slicing the element's actual text — with Thai combining marks the two
    /// counts differ routinely, and doing this arithmetic in the wrong unit is
    /// an off-by-N that eats neighbouring characters.
    /// `expecting`: the exact text we believe sits immediately before the caret
    /// (the stale tail being replaced). When non-nil, the replace happens ONLY
    /// if the document's actual trailing text matches it — the content check
    /// that makes the delayed cloud path safe: between typing and the cloud
    /// result (~4 s) the user can focus a different field, whose caret would
    /// otherwise pass every positional check while holding someone else's text.
    /// Path B REQUIRES it: a position that merely looks right is not enough to
    /// justify posting a destructive keystroke, so a nil `expecting` refuses
    /// there even though path A would have proceeded.
    func replaceLastInserted(count: Int, with text: String,
                             expecting: String? = nil) -> String? {
        guard count >= 0 else { return "internal error: negative count" }
        if count == 0 && text.isEmpty { return nil }
        guard AXIsProcessTrusted() else { return "Accessibility permission not granted" }
        if secureInputActive() { return "secure input is active" }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axMessagingTimeout)
        guard let focused = copyElement(systemWide, attribute: kAXFocusedUIElementAttribute) else {
            return "no focused element"
        }
        AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            focused, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else {
            return "focused element does not accept AX text replacement"
        }

        // The caret must be a caret. A non-empty selection means the user (or
        // another app) moved focus or selected text since we typed — replacing
        // would clobber something we did not write.
        guard let caret = selectedTextRange(of: focused) else {
            return "could not read the caret position"
        }
        guard caret.length == 0 else { return "a selection is active; not replacing" }

        // Convert the caller's grapheme `count` into the UTF-16 span sitting
        // immediately before the caret. Two reads can answer that, and which
        // one runs first is a correctness decision, not an optimisation.
        //
        // ── PRIMARY: kAXStringForRange, a PARAMETERIZED attribute ───────────
        //
        // It takes a range and returns that range's text, and — this is the
        // entire point — parameterized text attributes are indexed in the SAME
        // coordinate space as `kAXSelectedTextRange`. `kAXValue` is not always
        // in that space: web and Electron text controls routinely report a
        // value string whose offsets differ from selection offsets by a base
        // amount (surrounding content the accessibility tree folds into the
        // value). Slicing `kAXValue` at `caret.location` there reads a tail
        // from the WRONG PLACE, `expecting` therefore does not match it, and
        // the repair refuses systematically — in exactly the apps whose repairs
        // have to go through path B, which is where this function's whole
        // 158/158 story comes from.
        //
        // Anchoring on the caret cancels the offset by construction: the same
        // unknown base is present in the range we read and in the range we
        // write, so it never appears in the arithmetic. `replaceRecentText`
        // reached the same conclusion from the other end (see its "Target is
        // expressed CARET-RELATIVE" note, which converts a value-space hit into
        // a caret-relative range); this does it one step earlier by never
        // leaving selection space at all.
        //
        // ── FALLBACK: the original kAXValue block, kept verbatim ─────────────
        //
        // Native AppKit fields are proven correct on it — the two spaces
        // coincide there — and not every element implements the parameterized
        // attribute at all. A negative `caret.location` also lands here, and
        // the guard inside it owns that refusal.
        //
        // ── Window size ─────────────────────────────────────────────────────
        //
        // Thai grapheme clusters run 1-4 UTF-16 units, so `4 * count` bounds
        // the units the `count` clusters we want can occupy. The +64 slack
        // keeps `suffix(count)` clear of the window's LEADING edge, which can
        // and does cut a cluster in half; a truncated first cluster changes the
        // window's Character sequence at its start, never at its end.
        //
        // ── One check that could not come across, stated plainly ────────────
        //
        // The `kAXValue` path refuses when `caret.location` does not land on a
        // Character boundary of the value string ("caret is mid-cluster"). That
        // question cannot be ASKED of a windowed read: the caret is always at
        // the window's end, and a string's end index is always a valid boundary
        // of that string. Probing the unit AFTER the caret was considered and
        // rejected — it fails at end-of-text, which is the normal dictation
        // case, and a field that clamps rather than fails would make the probe
        // silently always-pass, i.e. protection that is not there. The residual
        // is a grapheme extender sitting immediately after the caret that
        // MicTest did not type, which needs an external writer mid-dictation;
        // when it happens, the range read-back below refuses in any field that
        // normalises selections to cluster boundaries. `tail` is still sliced
        // on the window's own grapheme boundaries, so nothing here can split a
        // cluster it can see.
        let len16: Int
        let windowLen16 = min(caret.location, 4 * count + 64)
        // The read is hoisted out of the condition on purpose: the fallback
        // below has to be able to say WHICH of the two ways it got here, and
        // they mean opposite things. "Attribute unavailable" is the expected,
        // permanent shape of a field that never implements it. "Window returned
        // a different length" means the field DOES implement it and answered
        // something we cannot do arithmetic on — which would make this whole
        // fix a silent no-op in exactly the apps it exists for, and that must
        // be visible in the trace rather than inferred from repairs that keep
        // refusing.
        let window = windowLen16 > 0
            ? axString(of: focused,
                       location: caret.location - windowLen16,
                       length: windowLen16)
            : nil
        if let window, window.utf16.count == windowLen16 {
            // The exact-length check is not pedantry: everything below assumes
            // the window ENDS at the caret. A field that returned a different
            // number of units than it was asked for has not answered that
            // question, so we ask `kAXValue` instead of guessing.
            guard window.count >= count else {
                return "fewer characters before the caret than expected (field changed?)"
            }
            let tail = window.suffix(count)
            if let expecting, String(tail) != expecting {
                return "text before the caret is not what MicTest typed (focus moved?)"
            }
            len16 = tail.utf16.count
            Self.log.debug(
                "Repair content check: parameterized caret-relative read (\(windowLen16, privacy: .public) UTF-16 units before the caret)."
            )
        } else {
            // Read the element's text to convert grapheme count -> UTF-16 range.
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                focused, kAXValueAttribute as CFString, &valueRef
            ) == .success, let valueRef, CFGetTypeID(valueRef) == CFStringGetTypeID() else {
                return "could not read the field's text to verify the range"
            }
            let full = (valueRef as! CFString) as String
            let utf16 = full.utf16
            guard caret.location >= 0, caret.location <= utf16.count else {
                return "caret position is outside the field's text"
            }
            guard let caretIdx = String.Index(String.Index(utf16Offset: caret.location, in: full),
                                              within: full) else {
                // Caret sits inside a surrogate pair / combining sequence -- the
                // field changed under us. Do nothing.
                return "caret is mid-cluster; field changed underneath us"
            }
            let prefix = full[full.startIndex..<caretIdx]
            guard prefix.count >= count else {
                return "fewer characters before the caret than expected (field changed?)"
            }
            let tail = prefix.suffix(count)
            if let expecting, String(tail) != expecting {
                return "text before the caret is not what MicTest typed (focus moved?)"
            }
            len16 = tail.utf16.count
            let why: String
            if windowLen16 <= 0 {
                why = "nothing before the caret to window"
            } else if let window {
                why = "kAXStringForRange returned \(window.utf16.count) units, asked for \(windowLen16)"
            } else {
                why = "kAXStringForRange unavailable"
            }
            Self.log.debug("Repair content check: kAXValue fallback (\(why, privacy: .public)).")
        }

        var target = CFRange(location: caret.location - len16, length: len16)
        guard let rangeValue = AXValueCreate(.cfRange, &target) else {
            return "internal error: could not build the AX range"
        }
        guard AXUIElementSetAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, rangeValue
        ) == .success else {
            return "the field refused to select the range to replace"
        }
        // Re-read: some elements silently clamp the range they were given.
        // Replacing a clamped range would eat the wrong characters.
        //
        // Some fields apply the selection ASYNCHRONOUSLY: the set returns
        // .success but an immediate re-read still shows the old caret. Seen in
        // production ("the field clamped the selection" on a field that had
        // accepted the very same insertions) — so we poll for it rather than
        // concluding on one read. This step is SHARED infrastructure now: it is
        // what establishes the span for both paths below, and its budget is
        // sized for a Chromium renderer round trip rather than an AppKit
        // runloop turn (see `axSelectionSettleTimeout`). A native field still
        // matches on the very first read.
        //
        // BUDGET. Everything from here to the end of this function polls the
        // target app, and every poll blocks the main run loop — the same run
        // loop that services `HotkeyMonitor`'s now-`.keyDown`-masked event tap
        // (`HotkeyMonitor.swift:514`). `repairPollBudget` is the ceiling on the
        // SUM of the settle loops below: each asks for its own budget and gets
        // whatever is left, so no combination of them can stack past it. A zero
        // remainder degrades a settle to a single read, which is still an honest
        // answer rather than a guess. Read that constant's comment before
        // changing any of the three budgets — which one absorbs the clipping is
        // a safety decision, not an ordering accident.
        //
        // The messaging timeout tightens here for the same reason: from this
        // point the AX traffic is this repair's own, so a wedged target
        // overshoots a budget by 100 ms rather than 250 ms. The prologue above
        // keeps `axMessagingTimeout` untouched — it is byte-identical to
        // `fc6c49b` and its 5 round trips are pre-existing cost that this path
        // did not introduce.
        AXUIElementSetMessagingTimeout(focused, Self.repairMessagingTimeout)
        let pollDeadline = Date().addingTimeInterval(Self.repairPollBudget)
        func remainingPoll(_ cap: TimeInterval) -> TimeInterval {
            min(cap, max(0, pollDeadline.timeIntervalSinceNow))
        }
        let applied = selection(of: focused, becomes: target,
                                within: remainingPoll(Self.axSelectionSettleTimeout))
        guard let applied,
              applied.location == target.location, applied.length == target.length else {
            // Nothing has been posted yet, so collapsing the caret back is safe
            // and leaves no surprise selection behind.
            collapseSelection(of: focused, to: caret.location)
            let got = applied.map { "(\($0.location),\($0.length))" } ?? "unreadable"
            return "the field clamped the selection (wanted (\(target.location),\(target.length)), got \(got)); not replacing"
        }

        // The selection is now established AND confirmed by the field itself.
        // Everything from here on replaces exactly `applied` and nothing wider.
        //
        // A correct replacement — by any mechanism — collapses that selection to
        // a caret immediately after the text that replaced it. An insertion that
        // failed to consume the selection lands `len16` further along instead,
        // so this one number tells the two apart.
        let collapsed = CFRange(location: target.location + text.utf16.count, length: 0)

        // ── Path A: the AX attribute write. Preferred, and unchanged. ────────
        if AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success {
            // Verify it to the SAME standard `insertViaAccessibility` uses, and
            // for the same reason. Before today this path trusted .success, and
            // against 158/158 field evidence that these apps return .success and
            // do nothing that was a live "the ledger claims text that did not
            // land" bug: `main.swift` would set `injectedForUtterance = text`
            // while the document still held the stale tail, with the stale tail
            // left SELECTED.
            //
            // The asymmetry is deliberate and matches that function's comment:
            // only a selection that is STILL exactly the span we asked to have
            // replaced is solid evidence of a no-op. An unreadable range, or a
            // range that moved anywhere else, is not — and treating it as one
            // would deliver the replacement TWICE. So the question asked here
            // is "did it move at all", which a field that complied answers on
            // the first read; only a field that is genuinely inert pays the
            // settle budget.
            let echo = selection(of: focused, movesOff: target,
                                 within: remainingPoll(Self.axSelectionSettleTimeout))
            if let echo, echo.location == collapsed.location, echo.length == 0 {
                // Positively confirmed: the selection collapsed to exactly
                // where a correct replacement of this length leaves it.
                return nil
            }
            if let echo, echo.location == target.location, echo.length == target.length {
                Self.log.notice(
                    "AX accepted a \(text.utf16.count, privacy: .public)-unit replacement over a \(target.length, privacy: .public)-unit selection but the selection did not collapse; falling back to the clipboard repair path."
                )
            } else {
                // AMBIGUOUS, and deliberately NOT treated as confirmation.
                // `movesOff` fires on any movement, and something other than
                // our write can move a selection inside a 400 ms window — an
                // autocomplete popup, a focus change, the user clicking. Only
                // the exact collapsed offset above is positive evidence; only
                // an unmoved selection is positive evidence of a no-op. This is
                // neither, so we fall back on `insertViaAccessibility`'s
                // standing rule — trust the .success, because a false negative
                // here delivers the replacement TWICE — and record the range so
                // a future reader can see how often this actually happens.
                let got = echo.map { "(\($0.location),\($0.length))" } ?? "unreadable"
                Self.log.notice(
                    "AX replacement accepted; selection settled at \(got, privacy: .public) rather than the expected collapse — ambiguous, trusting the write."
                )
                return nil
            }
        }

        // ── Path B: repair the AX-verified selection with a keystroke. ───────
        //
        // Reached only when path A is proven inert. The selection is still
        // standing and still verified, so the mechanism below replaces exactly
        // it. Two shapes, and only one of them touches the pasteboard.

        // A position that merely looks right is not enough to post a
        // destructive keystroke on. `repairDivergence` always supplies this;
        // the parameter is optional only for path A's benefit.
        guard let expecting else {
            collapseSelection(of: focused, to: caret.location)
            return "the field ignored the AX replacement and no content check was supplied; not repairing"
        }

        // ...and the content check has to be SPECIFIC enough to identify the
        // span, which a single character is not. `staleCount == 1` is the
        // commonest Thai repair shape there is — "ก" -> "ก่" adds a tone mark to
        // the trailing cluster and `main.swift`'s `commonPrefixLength` compares
        // Characters, so `expecting` is routinely ONE grapheme cluster. If focus
        // has moved to another editable field whose text merely happens to end
        // in that same character, every check above passes and path B rewrites
        // text the user typed by hand.
        //
        // `replaceRecentText` has refused anything under 3 clusters since it was
        // written, for exactly this reason ("ครับ" found in the wrong place is
        // how an unrelated word gets eaten) — and this path is strictly more
        // destructive than that one, because it posts a keystroke at whatever
        // has focus rather than writing to a captured element reference. The
        // weaker check on the more dangerous path was an oversight.
        //
        // PATH B ONLY, deliberately. Path A writes through `focused`, an element
        // reference captured at entry, so a positional-plus-content match there
        // cannot land in a different app no matter how short `expecting` is;
        // applying this gate to path A would refuse repairs that are perfectly
        // safe and lose them for no gain. The cost here is a truncated utterance
        // the user can recover from the HUD; the cost of not doing it is text
        // they wrote themselves.
        guard expecting.count >= 3 else {
            collapseSelection(of: focused, to: caret.location)
            return "the stale text is too short to identify safely (under 3 characters) "
                + "for a keystroke repair; not repairing"
        }

        // Secure Event Input, re-checked at the moment it matters. The entry
        // check above is several AX round trips and up to two settles old by
        // now, and the rule is that the transcript must never reach the
        // pasteboard while SEI is held — that is a property of the write, not
        // of function entry. Nothing has been posted yet, so we can back out
        // cleanly.
        if secureInputActive() {
            collapseSelection(of: focused, to: caret.location)
            return "secure input became active mid-repair; nothing was written to the clipboard"
        }

        var borrowedGeneration: Int?
        let postedAt: Date
        if text.isEmpty {
            // PURE RETRACTION. The recogniser took characters back, so there is
            // nothing to paste — and therefore no reason to borrow the user's
            // clipboard at all. One Delete against a non-empty selection deletes
            // the selection, exactly, in every app: no count, no unit, no script
            // dependence. Retractions are one of the two repair shapes, so this
            // is a real reduction in pasteboard exposure rather than a rounding
            // error.
            //
            // The guard is not paranoia. A bare Delete against an EMPTY
            // selection deletes one unit of whatever precedes the caret — text
            // this app may not have typed. That is the single most destructive
            // thing this file could do, so it is checked explicitly here rather
            // than inferred from `count > 0` several screens above.
            guard target.length > 0 else {
                collapseSelection(of: focused, to: caret.location)
                return "internal error: refusing to post Delete with an empty selection"
            }
            guard focusIsStill(focused) else {
                collapseSelection(of: focused, to: caret.location)
                Self.log.notice(
                    "Repair refused: FOCUS MOVED between the verified selection and the repair keystroke (delete branch); nothing was posted."
                )
                return Self.focusMovedRefusal
            }
            guard postDeleteKey() else {
                collapseSelection(of: focused, to: caret.location)
                return "could not post the delete keystroke. Check Accessibility permission in System Settings."
            }
            postedAt = Date()
            Self.log.notice(
                "Repair fallback: deleted a \(target.length, privacy: .public)-unit selection with one Delete (no clipboard borrow)."
            )
        } else {
            guard focusIsStill(focused) else {
                collapseSelection(of: focused, to: caret.location)
                Self.log.notice(
                    "Repair refused: FOCUS MOVED between the verified selection and the repair keystroke (paste branch); the transcript never reached the clipboard."
                )
                return Self.focusMovedRefusal
            }
            switch borrowPasteboardAndPasteV(text) {
            case .failed(let reason):
                // The borrow released itself and nothing was posted.
                collapseSelection(of: focused, to: caret.location)
                return reason
            case .posted(let generation, let at, _):
                borrowedGeneration = generation
                postedAt = at
                Self.log.notice(
                    "Repair fallback: pasted \(text.count, privacy: .public) chars over a \(target.length, privacy: .public)-unit selection."
                )
            }
        }
        // Hand the borrow back on EVERY exit from here, anchored at the instant
        // the keystroke went out. Anchoring on `postedAt` rather than on "when
        // the restore task happens to start" is what keeps the verification
        // below from lengthening the pasteboard window: the user's clipboard is
        // still returned `pasteSettleTimeout` after the paste, not after the
        // paste plus however long we spent watching for the receipt.
        defer {
            if let borrowedGeneration {
                scheduleReceiptSequencedRestore(generation: borrowedGeneration, since: postedAt)
            }
        }

        // The receipt. Without it this function would return `nil` on nothing
        // more than "we posted a key event", and the caller would write `text`
        // into its ledger whether or not the document ever changed.
        let echoBudget = remainingPoll(Self.repairEchoTimeout)
        let echo = selection(of: focused, becomes: collapsed, within: echoBudget)
        if let echo, echo.location == collapsed.location, echo.length == 0 {
            return nil
        }

        // No receipt. DELIBERATELY leave the selection standing rather than
        // collapsing the caret, which is the opposite of what every refusal
        // above does — and the reason is the one outcome worse than refusing.
        //
        // A synthetic Cmd+V can be delivered late; this file's own note puts
        // Electron round trips at 100-300 ms and the budget above at 400 ms,
        // but "late" has no hard bound. If we collapsed the caret and the paste
        // then landed, it would insert AFTER the stale tail instead of over it,
        // leaving the document as a hybrid of two different partials —
        // `prefix + stale + replacement`. Leaving the selection standing makes
        // the late paste land correctly instead, and the two possible outcomes
        // are then both safe: either the document still reads exactly as it did
        // (nothing landed), or it reads exactly as the caller intended (it
        // landed late). In neither case does the ledger claim text that is not
        // there, because we are returning a refusal for both.
        //
        // The caller interpolates this reason straight into the HUD, so it says
        // that a selection was left behind: the FINAL reconciliation will hit
        // the "a selection is active" guard at the top of this function, and
        // the user should learn why from the first message.
        Self.log.notice(
            "Repair fallback posted but was not echoed back within \(Int(echoBudget * 1000), privacy: .public) ms (of a \(Int(Self.repairEchoTimeout * 1000), privacy: .public) ms budget, clipped by the poll ceiling); refusing and leaving the selection standing."
        )
        return "the repair keystroke was not confirmed by the field; the stale text is left "
            + "SELECTED rather than deleted (so a late paste still lands correctly) and "
            + "nothing was recorded as typed"
    }
    /// Replace the LAST occurrence of `find` located strictly BEFORE the caret
    /// with `replacement`, then restore the caret to where it was (adjusted by
    /// the length delta so it stays at the same logical spot in the text that
    /// follows).
    ///
    /// Guarantee: this either replaces exactly the verified span or does
    /// nothing and returns a reason. Every check that could locate the wrong
    /// span refuses instead of guessing — no fuzzy matching, and never a
    /// fallback to synthesized keystrokes, because the span being replaced sits
    /// BEHIND newer text and a blind edit there eats words the user typed.
    ///
    /// This exists for the delayed cloud-transcription pass: by the time the
    /// more accurate text arrives (~1-2 s), the on-device text it corrects is
    /// no longer the tail before the caret — newer dictation has been typed
    /// after it — so `replaceLastInserted` cannot reach it. We instead search
    /// the text before the caret (bounded to the last ~1000 UTF-16 units, so a
    /// huge document is never scanned) for the last literal occurrence.
    ///
    /// Units discipline: AX ranges are UTF-16 code units; the search and all
    /// range arithmetic run on `utf16Offset` conversions, never on grapheme
    /// counts — with Thai combining marks the two diverge routinely. Grapheme
    /// clusters are used for exactly one thing: the minimum-length gate on
    /// `find`, which is about *human* text ("ครับ" is 4 UTF-16 units but one
    /// short common word). All index construction is checked; a caret or
    /// window edge that lands mid-cluster is refused or snapped forward, never
    /// split.
    ///
    /// - Returns: `nil` on success, or a human-readable reason and the
    ///   document untouched.
    @MainActor func replaceRecentText(find: String, with replacement: String) -> String? {
        guard !find.isEmpty else { return "internal error: empty search text" }
        // Identical text is a no-op success: the document already reads the
        // way the caller wants it to.
        if find == replacement { return nil }
        // Refuse tiny targets. Replacing a short common string ("ครับ") found
        // in the wrong place is exactly how an unrelated word gets eaten, so
        // anything under 3 grapheme clusters is not specific enough to trust.
        guard find.count >= 3 else {
            return "search text is too short to locate safely (under 3 characters); not replacing"
        }
        guard AXIsProcessTrusted() else { return "Accessibility permission not granted" }
        if secureInputActive() { return "secure input is active" }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.axMessagingTimeout)
        guard let focused = copyElement(systemWide, attribute: kAXFocusedUIElementAttribute) else {
            return "no focused element"
        }
        AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            focused, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else {
            return "focused element does not accept AX text replacement"
        }

        // The caret must be a caret. A non-empty selection means the user (or
        // another app) moved focus or selected text since we typed — replacing
        // would clobber something we did not write.
        guard let caret = selectedTextRange(of: focused) else {
            return "could not read the caret position"
        }
        guard caret.length == 0 else { return "a selection is active; not replacing" }

        // Read the element's text so the search runs against what is actually
        // in the field, and so every UTF-16 offset below is checked against it.
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef
        ) == .success, let valueRef, CFGetTypeID(valueRef) == CFStringGetTypeID() else {
            return "could not read the field's text to verify the range"
        }
        let full = (valueRef as! CFString) as String
        let utf16 = full.utf16
        guard caret.location >= 0, caret.location <= utf16.count else {
            return "caret position is outside the field's text"
        }
        guard let caretIdx = String.Index(String.Index(utf16Offset: caret.location, in: full),
                                          within: full) else {
            // Caret sits inside a surrogate pair / combining sequence -- the
            // field changed under us. Do nothing.
            return "caret is mid-cluster; field changed underneath us"
        }

        // Bound the search to the last ~1000 UTF-16 units before the caret so
        // we never scan a whole huge document. If the window edge lands
        // mid-cluster, shrink the window forward to the next cluster boundary
        // rather than splitting a cluster.
        let searchWindowUTF16 = 1000
        let windowStartIdx: String.Index
        if caret.location > searchWindowUTF16 {
            var off = caret.location - searchWindowUTF16
            var aligned = String.Index(String.Index(utf16Offset: off, in: full), within: full)
            while aligned == nil && off < caret.location {
                off += 1
                aligned = String.Index(String.Index(utf16Offset: off, in: full), within: full)
            }
            windowStartIdx = aligned ?? caretIdx
        } else {
            windowStartIdx = full.startIndex
        }

        // Last literal occurrence only. `.literal` keeps the matched span's
        // UTF-16 length identical to `find`'s (canonical-equivalence matching
        // could select a differently-composed span of a different length,
        // wrecking the offset arithmetic). Not found means the field changed;
        // we refuse rather than guess.
        guard let hit = full[windowStartIdx..<caretIdx]
            .range(of: find, options: [.backwards, .literal]) else {
            return "typed text not found before the caret — field changed or was edited"
        }

        // AMBIGUITY GUARD: if `find` occurs more than once in the window, we cannot
        // know which occurrence is the span we typed for this audio chunk. Thai speech
        // is repetitive ("ครับ...ครับ"); picking the last occurrence blind can correct
        // the WRONG utterance's text and desynchronise the caller's bookkeeping. Refuse
        // and let the caller fall back to the copyable offer.
        if full[windowStartIdx..<hit.lowerBound]
            .range(of: find, options: [.literal]) != nil {
            return "typed text appears more than once before the caret; not replacing"
        }

        // DRIFT ABSORPTION: text for this audio span can keep landing AFTER the
        // snapshot was taken (the recogniser's FINAL routinely arrives later than the
        // audio silence cut). That typed tail sits between the span and the caret, and
        // fal's replacement usually CONTAINS it — replacing only the span would then
        // duplicate the tail ("...บูม" -> "...บูมบูม"). If everything between the span
        // and the caret is a suffix of the replacement, widen the target to the caret
        // so the tail is absorbed; if it is anything else (the user kept dictating a
        // new utterance), refuse rather than guess.
        let tail = String(full[hit.upperBound..<caretIdx])
        var effectiveUpper = hit.upperBound
        if !tail.isEmpty {
            if replacement.hasSuffix(tail) {
                effectiveUpper = caretIdx
            } else {
                return "text was typed after this span; not replacing"
            }
        }

        let loc16 = hit.lowerBound.utf16Offset(in: full)
        let end16 = effectiveUpper.utf16Offset(in: full)

        // Target is expressed CARET-RELATIVE, not value-absolute: some fields (notably
        // web/Electron text controls) report kAXValue and kAXSelectedTextRange in
        // coordinate spaces that differ by a base offset. Anchoring on the caret the
        // field itself reported cancels any such offset; a value-absolute location
        // would silently select unrelated text there, and the clamp read-back could
        // not catch it (the range we hand over IS valid — just wrong).
        let caret16 = caretIdx.utf16Offset(in: full)
        var target = CFRange(location: caret.location - (caret16 - loc16),
                             length: end16 - loc16)
        guard let rangeValue = AXValueCreate(.cfRange, &target) else {
            return "internal error: could not build the AX range"
        }
        guard AXUIElementSetAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, rangeValue
        ) == .success else {
            return "the field refused to select the range to replace"
        }
        // Re-read: some elements silently clamp the range they were given.
        // Replacing a clamped range would eat the wrong characters.
        //
        // Some fields apply the selection ASYNCHRONOUSLY: the set returns
        // .success but an immediate re-read still shows the old caret. Seen in
        // production ("the field clamped the selection" on a field that had
        // accepted the very same insertions) — so on mismatch, wait one beat
        // and re-read once before concluding the field really clamped it.
        func readBack() -> CFRange? { selectedTextRange(of: focused) }
        var applied = readBack()
        if !(applied?.location == target.location && applied?.length == target.length) {
            usleep(40_000)   // 40 ms settle; AX set is IPC, application can lag a runloop turn
            applied = readBack()
        }
        guard let applied,
              applied.location == target.location, applied.length == target.length else {
            // Restore the caret so we do not leave a surprise selection behind.
            var restore = CFRange(location: caret.location, length: 0)
            if let restoreValue = AXValueCreate(.cfRange, &restore) {
                AXUIElementSetAttributeValue(
                    focused, kAXSelectedTextRangeAttribute as CFString, restoreValue)
            }
            let got = applied.map { "(\($0.location),\($0.length))" } ?? "unreadable"
            return "the field clamped the selection (wanted (\(target.location),\(target.length)), got \(got)); not replacing"
        }

        guard AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, replacement as CFString
        ) == .success else {
            var restore = CFRange(location: caret.location, length: 0)
            if let restoreValue = AXValueCreate(.cfRange, &restore) {
                AXUIElementSetAttributeValue(
                    focused, kAXSelectedTextRangeAttribute as CFString, restoreValue)
            }
            return "the field refused the replacement text"
        }

        // The replacement DID happen; from here on we return nil no matter
        // what. Put the caret back where it was, shifted by the length delta
        // so it stays at the same logical spot in the text that follows the
        // replaced span, and clamped into the new document bounds defensively.
        let delta = replacement.utf16.count - (end16 - loc16)
        let newLength = utf16.count + delta
        var restored = CFRange(
            location: min(max(0, caret.location + delta), max(0, newLength)),
            length: 0
        )
        if let restoredValue = AXValueCreate(.cfRange, &restored) {
            AXUIElementSetAttributeValue(
                focused, kAXSelectedTextRangeAttribute as CFString, restoredValue)
        }
        return nil
    }

    /// Copy an `AXUIElement`-valued attribute, with the CFTypeRef dance and a
    /// type check so a malformed reply cannot crash us on a force-cast.
    private func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// Read `kAXSelectedTextRangeAttribute` as a `CFRange`.
    ///
    /// Note the units: AppKit reports these ranges in NSString indices, i.e.
    /// UTF-16 code units, not grapheme clusters. We only ever compare a range to
    /// itself here so it does not matter, but if you ever do arithmetic on it
    /// with Thai text, use `text.utf16.count`, never `text.count`.
    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        let axValue = (value as! AXValue)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard withUnsafeMutablePointer(to: &range, { AXValueGetValue(axValue, .cfRange, $0) })
        else { return nil }
        return range
    }

    /// Read the text of `element` over `[location, location + length)` via the
    /// `kAXStringForRange` PARAMETERIZED attribute.
    ///
    /// Units are UTF-16 code units, in the same coordinate space as
    /// `kAXSelectedTextRange` — which is the whole reason this sits next to
    /// that reader rather than being folded into the `kAXValue` read it
    /// competes with. Those two spaces are not always the same space; see the
    /// long comment in `replaceLastInserted`.
    ///
    /// Returns `nil` for every answer that is not a non-empty string: attribute
    /// unsupported, range rejected, non-string reply, or an empty reply where
    /// we asked for at least one unit. Each of those means "ask `kAXValue`
    /// instead", never "there is no text there" — this function deliberately
    /// cannot report an empty window, because it is only ever called with a
    /// positive length.
    private func axString(of element: AXUIElement, location: Int, length: Int) -> String? {
        guard location >= 0, length > 0 else { return nil }
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &result
        ) == .success, let result, CFGetTypeID(result) == CFStringGetTypeID() else { return nil }
        let string = (result as! CFString) as String
        return string.isEmpty ? nil : string
    }

    /// Block until `kAXSelectedTextRange` reads back as `expected`, or until
    /// `timeout` elapses; return the last value we managed to read (`nil` if we
    /// never could read one at all).
    ///
    /// Yes, this blocks the main actor. It is deliberate and it is bounded. The
    /// two callers are both mid-way through an edit that must not be
    /// interleaved with another injection, and `replaceLastInserted` is
    /// synchronous by contract — making it async would let a second partial
    /// arrive while a selection is standing, which is a far worse problem than
    /// a stalled HUD. The cost is only paid on a repair, never on an ordinary
    /// partial, and a native field satisfies the very first read.
    ///
    /// Two honest side effects of the blocking. A pending clipboard restore
    /// from a PREVIOUS injection cannot run while we are here, so that borrow
    /// can stretch from 700 ms to roughly 1.1 s in the worst case — and a
    /// restore task that resumes past its own deadline is exactly the case the
    /// final `changeCount` check in `scheduleReceiptSequencedRestore` exists
    /// for; without it, this blocking would let us write a stale snapshot over
    /// a clipboard the user had claimed in the meantime. And each poll is an AX
    /// round trip capped by the element's messaging timeout, so a wedged target
    /// can overshoot `timeout` by one of those.
    ///
    /// The total is now bounded rather than merely per-call: `replaceLastInserted`
    /// passes each of its three settles whatever is left of `repairPollBudget`,
    /// so they cannot stack. See that constant for why the ceiling lives there
    /// and not in the individual budgets.
    private func settledSelection(of element: AXUIElement, within timeout: TimeInterval,
                                  until satisfied: (CFRange) -> Bool) -> CFRange? {
        let deadline = Date().addingTimeInterval(timeout)
        var last = selectedTextRange(of: element)
        while true {
            if let seen = last, satisfied(seen) { return seen }
            if Date() >= deadline { return last }
            usleep(useconds_t(Self.axSelectionPollInterval * 1_000_000))
            last = selectedTextRange(of: element)
        }
    }

    /// `settledSelection`'s two shapes, named so the call sites read as the
    /// question they are actually asking.
    ///
    /// The distinction is not cosmetic, it is what the budget gets spent on.
    /// "Has it become X" must be answered positively — nothing but the exact
    /// value will do, because a paste that INSERTED instead of replacing also
    /// lands a plausible-looking caret. "Has it moved at all" can be answered
    /// by the first read in a healthy field, so the budget is only ever burned
    /// in the case we actually want to pay for: a field that is sitting there
    /// doing nothing.
    private func selection(of element: AXUIElement, becomes expected: CFRange,
                           within timeout: TimeInterval) -> CFRange? {
        settledSelection(of: element, within: timeout) {
            $0.location == expected.location && $0.length == expected.length
        }
    }
    private func selection(of element: AXUIElement, movesOff anchor: CFRange,
                           within timeout: TimeInterval) -> CFRange? {
        settledSelection(of: element, within: timeout) {
            !($0.location == anchor.location && $0.length == anchor.length)
        }
    }

    /// Is `expected` STILL the element holding keyboard focus?
    ///
    /// This is the guard that separates path A from path B, and it exists
    /// because the two write mechanisms have completely different targeting.
    /// Every check in `replaceLastInserted` — settable, caret, kAXValue,
    /// `expecting`, the clamped read-back — runs against `focused`, an
    /// `AXUIElement` captured once at entry. Writing through that reference is
    /// focus-INDEPENDENT by construction: it lands in the element we verified,
    /// or it fails. Before the repair fallback existed that was the only write
    /// this function could perform, and the whole class of bug below could not
    /// occur.
    ///
    /// A synthesised keystroke has no such property. `postDeleteKey` and
    /// `postCommandV` post to `.cghidEventTap`, which delivers to whatever has
    /// keyboard focus AT THE MOMENT THE EVENT IS DELIVERED. And the window
    /// between the last check and the post is not small: reaching path B at all
    /// requires the `movesOff` poll to have burned its full budget, because that
    /// is what "the AX write is inert" means — so in the target apps the window
    /// is 400 ms GUARANTEED, and 500-800 ms typical once the range settle is
    /// counted. A Cmd+Tab, a Spotlight invocation, or a dialog stealing focus
    /// inside that window leaves our captured element still reading `target`
    /// unchanged — the poll concludes "inert" from a perfectly honest read —
    /// and the bare Delete then lands in the OTHER app at a collapsed caret,
    /// deleting one cluster of text the user typed by hand. That breaks the
    /// first invariant of this file ("never delete more than this app typed")
    /// in the worst available way: in a document we never even looked at.
    ///
    /// One AX round trip, at `repairMessagingTimeout`. An UNREADABLE answer is
    /// treated as a mismatch, not as a pass: a systemwide focused-element read
    /// that fails means the target is wedged or gone, which is the more
    /// dangerous case, and defaulting to "post anyway" there would aim the
    /// keystroke at exactly the situation we cannot see.
    private func focusIsStill(_ expected: AXUIElement) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.repairMessagingTimeout)
        guard let current = copyElement(systemWide, attribute: kAXFocusedUIElementAttribute)
        else { return false }
        // AX elements are CFTypes and compare by CFEqual, not by pointer: the
        // same underlying UI element can come back as a different CFTypeRef.
        return CFEqual(current, expected)
    }

    /// Put the caret back where we found it, collapsed, after deciding not to
    /// replace.
    ///
    /// Only ever call this when NOTHING has been posted yet. Once a keystroke
    /// is in flight, collapsing the caret is the one move that can turn a
    /// refusal into a corrupted document — see the closing comment of
    /// `replaceLastInserted`.
    private func collapseSelection(of element: AXUIElement, to location: Int) {
        var restore = CFRange(location: location, length: 0)
        if let restoreValue = AXValueCreate(.cfRange, &restore) {
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, restoreValue)
        }
    }

    // MARK: - Path B: clipboard + synthetic Cmd+V

    /// Outcome of borrowing the user's pasteboard and posting Cmd+V.
    private enum PasteHandoff {
        /// The keystroke went out. `postedAt` is when the clipboard-exposure
        /// clock started; the caller owns scheduling the restore and MUST pass
        /// `postedAt` as `since:` so the borrow is never longer than
        /// `pasteSettleTimeout`, no matter what the caller does in between.
        case posted(generation: Int, postedAt: Date, keyCode: CGKeyCode)
        /// Nothing was pasted and the user's clipboard is already back.
        case failed(String)
    }

    /// Borrow the pasteboard, put `text` on it, and post Cmd+V — the mechanism
    /// half of the clipboard path, with no policy about when to restore.
    ///
    /// Split out of `injectViaClipboard` so `replaceLastInserted`'s repair
    /// fallback can reuse the *same* borrow bookkeeping
    /// (`restorePending` / `restoreGeneration` / `ourChangeCount`) instead of
    /// growing a second, parallel one. There is exactly one borrow mechanism in
    /// this file and this is it.
    private func borrowPasteboardAndPasteV(_ text: String) -> PasteHandoff {
        let pasteboard = NSPasteboard.general

        // Resolve the keycode BEFORE touching the pasteboard, so a resolution
        // failure cannot leave the user's clipboard clobbered. (It cannot fail
        // in practice — there is a hardcoded fallback — but ordering the fragile
        // step first is free.)
        let vKeyCode = resolveVKeyCodeForPaste()

        // Secure Event Input, checked at the WRITE rather than only at the
        // caller's entry. `inject` checks on the way in, but the AX path and its
        // settle run in between, and a password field or a Cursor leak can claim
        // SEI inside that window. Putting the transcript on the general
        // pasteboard at that moment is precisely what must never happen, so the
        // check belongs here where the bytes actually land.
        if secureInputActive() {
            Self.log.notice("Secure Event Input became active before the pasteboard write; nothing was copied.")
            return .failed("Secure input is active (password field, Terminal secure entry, "
                + "or a Cursor/Electron leak). Nothing was put on the clipboard.")
        }

        // Only snapshot when we are not already holding one. See `restorePending`.
        if !restorePending {
            savedClipboard = snapshotPasteboard(pasteboard)
        }
        restorePending = true
        restoreGeneration &+= 1
        let generation = restoreGeneration

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            // Put things back immediately; we never got as far as pasting.
            completeRestore(generation: generation, restoring: true)
            return .failed("Could not write the transcript to the clipboard.")
        }
        ourChangeCount = pasteboard.changeCount

        guard postCommandV(keyCode: vKeyCode) else {
            completeRestore(generation: generation, restoring: true)
            return .failed("Could not post the paste keystroke. Check Accessibility permission in System Settings.")
        }
        return .posted(generation: generation, postedAt: Date(), keyCode: vKeyCode)
    }

    private func injectViaClipboard(_ text: String, targetID: String) -> String? {
        switch borrowPasteboardAndPasteV(text) {
        case .failed(let reason):
            return reason

        case .posted(let generation, let postedAt, let vKeyCode):
            Self.log.info(
                "Pasted \(text.count, privacy: .public) chars into \(targetID, privacy: .public) via keycode \(vKeyCode, privacy: .public)"
            )

            // Hand the restore off to a non-blocking watcher and return.
            // `inject` is synchronous and main-actor-isolated, so *waiting* here
            // would freeze the UI for the full settle timeout. Returning `nil`
            // now is honest: we have successfully delivered the keystroke, which
            // is the most any injector can actually observe (see the receipt
            // discussion below).
            scheduleReceiptSequencedRestore(generation: generation, since: postedAt)
            return nil
        }
    }

    /// Watch the pasteboard and put the user's clipboard back at the right time.
    ///
    /// ── Honest note on "receipt sequencing" ──────────────────────────────────
    ///
    /// The tempting design is "restore as soon as a consumer has read our text".
    /// You cannot do that with `changeCount`. `NSPasteboard.changeCount` is a
    /// *write* counter — it increments on `clearContents()` / `declareTypes()`
    /// and does NOT move when somebody reads. There is no read receipt in the
    /// AppKit pasteboard API.
    ///
    /// (The one real read-receipt mechanism is a lazy `NSPasteboardItemDataProvider`,
    /// whose callback fires exactly when a consumer requests the data. We
    /// deliberately do not use it: if the promise is never fulfilled — an app
    /// that enumerates types without fetching, or fetches a richer type we did
    /// not offer — the paste produces *nothing* and the user's dictation is
    /// silently lost. Writing the string eagerly guarantees something pasteable
    /// is there. Guaranteed delivery beats a tidier restore.)
    ///
    /// So what `changeCount` actually buys us is the *other* half, and it is the
    /// half that prevents real data loss: if it has moved off ours, another
    /// process now owns the pasteboard, and restoring our snapshot would clobber
    /// something the user copied more recently. In that case we drop the
    /// snapshot and restore nothing.
    ///
    /// Which means `pasteSettleTimeout` is not a "fallback" — on the happy path
    /// it is the mechanism. Size it accordingly.
    ///
    /// `since` is the instant the Cmd+V went out. It is a parameter rather than
    /// `Date()` inside the task because the repair fallback in
    /// `replaceLastInserted` blocks for its receipt before scheduling: without
    /// the anchor, that wait would be ADDED to the pasteboard window instead of
    /// counted inside it. It also slightly tightens the ordinary path, whose
    /// window previously started whenever the task first got to run rather than
    /// at the paste itself.
    private func scheduleReceiptSequencedRestore(generation: Int, since postedAt: Date) {
        Task { @MainActor [weak self] in
            let deadline = postedAt.addingTimeInterval(Self.pasteSettleTimeout)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(Int(Self.restorePollInterval * 1000)))
                guard let self, generation == self.restoreGeneration else {
                    return  // Superseded by a newer injection, or we are gone.
                }
                if NSPasteboard.general.changeCount != self.ourChangeCount {
                    Self.log.info("Pasteboard was claimed by another process; skipping restore.")
                    self.completeRestore(generation: generation, restoring: false)
                    return
                }
            }
            guard let self, generation == self.restoreGeneration else { return }
            // FINAL anti-clobber check. The loop above already checks
            // `changeCount` every 50 ms, but falling out of it is NOT proof that
            // the last check was recent — and the restore is the destructive
            // half, so it must be gated by a check of its own rather than by the
            // loop's history.
            //
            // Two ways the loop's checks go stale, both real here:
            //
            //   • The task is a `@MainActor` task, so its `Task.sleep`
            //     continuation cannot resume while the main actor is blocked.
            //     `replaceLastInserted`'s settle loops block it for up to
            //     `repairPollBudget` plus the prologue's AX round trips, so a
            //     PREVIOUS injection's restore can sit mid-loop for ~1 s. On
            //     resume `Date() < deadline` is already false, the loop exits
            //     immediately, and without this check we would write our
            //     snapshot back having verified nothing for the whole stall.
            //   • `since: postedAt` anchors the deadline at the keystroke, not
            //     at the task's first run — deliberately, so the borrow is never
            //     longer than `pasteSettleTimeout`. But it means a task that is
            //     scheduled behind a blocking poll can have its FIRST evaluation
            //     of `Date() < deadline` already be false, in which case the
            //     loop body never executes and the guard inside it never runs at
            //     all. That variant has no other check anywhere.
            //
            // Either way the user's Cmd+C in that window would be silently
            // overwritten by a pre-dictation snapshot. `restoring: false` still
            // releases the borrow and drops the snapshot, so the bookkeeping is
            // unchanged — only the write is skipped.
            if NSPasteboard.general.changeCount != self.ourChangeCount {
                Self.log.info(
                    "Pasteboard changed while the restore task was stalled past its deadline; skipping restore (no clobber)."
                )
                self.completeRestore(generation: generation, restoring: false)
                return
            }
            self.completeRestore(generation: generation, restoring: true)
        }
    }

    /// Policy half of the restore: decide whether to put the snapshot back, then
    /// release the borrow either way.
    private func completeRestore(generation: Int, restoring: Bool) {
        guard generation == restoreGeneration else { return }
        defer {
            savedClipboard = nil
            restorePending = false
        }
        guard restoring, let snapshot = savedClipboard else { return }
        restorePasteboard(snapshot, to: .general)
        ourChangeCount = NSPasteboard.general.changeCount
    }

    /// Mechanism half of the restore: write a snapshot produced by
    /// `snapshotPasteboard` back onto a pasteboard, rebuilding every item with
    /// every representation we captured.
    ///
    /// Internal rather than private so the snapshot/restore round trip can be
    /// exercised directly — it is the one part of the clipboard path that needs
    /// no keystroke and no Accessibility permission, and therefore the one part
    /// that can be tested honestly.
    func restorePasteboard(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }  // Clipboard was empty to begin with.
        let items = snapshot.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// Flatten every item on the pasteboard into plain `Data` per type.
    ///
    /// ── What this preserves, and what it cannot ──────────────────────────────
    ///
    /// Preserved: all items, and every representation of each one that we can
    /// materialise within the byte budget — so a copy that carried both RTF and
    /// plain text comes back with both, and pasting into a rich-text editor
    /// after a dictation still gets the formatting. This is the whole reason we
    /// do not simply stash `pasteboard.string(forType: .string)`.
    ///
    /// NOT preserved, honestly:
    ///
    ///   • Lazy promises. Calling `data(forType:)` *forces* them, so what we
    ///     restore is a materialised snapshot rather than a live promise. For
    ///     ordinary data this is invisible. For file promises
    ///     (`com.apple.pasteboard.promised-file-url` and friends) the bytes we
    ///     restore reference a provider that may no longer be listening, so a
    ///     promised drag copied from Finder or Mail can come back dead.
    ///   • Pasteboard *ownership*. After restore, PhayaVoice owns the pasteboard,
    ///     not the original app. An app that re-derives its own clipboard state
    ///     from ownership will not recognise it.
    ///   • Anything beyond `maxSnapshotBytes`. Be precise about what this drops:
    ///     types are fetched highest-priority first, so within an item the
    ///     low-value representations go first — but once the budget is spent,
    ///     every *subsequent item* is skipped entirely rather than partially
    ///     captured. In practice this only bites on a pasteboard carrying both a
    ///     huge image and further items, which is rare; if you ever see a
    ///     multi-file copy come back short, this is why.
    /// Internal rather than private: exercised directly by the injection harness.
    func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
        var budget = Self.maxSnapshotBytes
        // TIME budget as well as a byte budget. The byte budget bounds how much
        // we copy; it does not bound how long we wait, and forcing a promise is
        // a synchronous IPC into the providing app. This runs on the main actor
        // in the same window as the repair's settle loops, and that window now
        // has a ceiling (`repairPollBudget`), so an unbounded wait here would
        // simply move the main-thread stall to a place nobody was measuring.
        //
        // Precise about what this does NOT do: AppKit exposes no timeout on
        // `data(forType:)`, so one hostile or beachballing provider can still
        // overrun the deadline by exactly one fetch. All that is bounded is the
        // decision to START another fetch — same shape as the byte budget above
        // it, and the same honest limit.
        let deadline = Date().addingTimeInterval(Self.snapshotTimeBudget)
        var ranOutOfTime = false

        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in prioritize(item.types) {
                // Check both budgets *before* fetching, so one oversized or one
                // slow representation cannot drag the rest in behind it.
                guard budget > 0 else { break }
                guard Date() < deadline else { ranOutOfTime = true; break }
                guard let data = item.data(forType: type) else { continue }
                representations[type] = data
                budget -= data.count
            }
            if !representations.isEmpty { snapshot.append(representations) }
            if ranOutOfTime { break }
        }
        if ranOutOfTime {
            // Worth a line: it means the user's clipboard is coming back short,
            // and the cause is a slow provider rather than a big one.
            Self.log.notice(
                "Clipboard snapshot hit its \(Int(Self.snapshotTimeBudget * 1000), privacy: .public) ms budget; some representations were not captured and will not be restored."
            )
        }
        return snapshot
    }

    /// Sort types so the ones worth preserving most are fetched first.
    private func prioritize(_ types: [NSPasteboard.PasteboardType]) -> [NSPasteboard.PasteboardType] {
        types.sorted { lhs, rhs in
            let l = Self.prioritizedTypes.firstIndex(of: lhs) ?? Int.max
            let r = Self.prioritizedTypes.firstIndex(of: rhs) ?? Int.max
            return l == r ? lhs.rawValue < rhs.rawValue : l < r
        }
    }

    // MARK: - Synthetic Cmd+V

    /// Post a Cmd+V key pair to the HID tap.
    private func postCommandV(keyCode: CGKeyCode) -> Bool {
        // `.combinedSessionState` is the mainstream choice: the event
        // participates in the session's normal modifier bookkeeping, which is
        // what apps expect. If you ever find a target that still sees stray
        // hardware modifiers despite the explicit flags below, the next knob is
        // `CGEventSource(stateID: .privateState)`, which starts with clean state
        // — at the cost of some older apps ignoring private-state events
        // entirely. Try the flags first.
        //
        // Whatever you do, do NOT "simplify" this to
        // `CGEventSource(stateID: .hidSystemState)`. HotkeyMonitor's
        // hold-detection reads the HID state table
        // (`CGEventSource.keyState(.hidSystemState, ...)`) precisely because
        // that table is meant to reflect physical hardware, immune to our own
        // synthetic events — and per the CGEventSourceStateID docs, events
        // created from an `.hidSystemState` source update exactly that table.
        // Creating our events there would make the injector write into the
        // state the hotkey polls. Honest caveat: Apple does not document
        // whether posting at `.cghidEventTap` folds an event into the HID
        // table regardless of its source's stateID; we conservatively keep the
        // source out of `.hidSystemState` anyway, and note that the events
        // posted here are the "v" key with ⌘ — not Right-Option — so even in
        // the worst case they cannot register as the held hotkey key itself.
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }

        // Assign the flags EXPLICITLY on both events, and assign rather than
        // OR-in. `CGEvent.flags` is absolute, not additive, so a bare assignment
        // wipes any inherited hardware modifier state.
        //
        // This matters more than it looks: the hotkey is hold-to-talk on
        // Right-Option, so at the instant `inject` runs the user may still be
        // physically holding Option, or the OS may not have settled the release
        // yet. A Cmd+V that arrives as Cmd+Opt+V is "Paste and Match Style" in
        // several apps and a no-op in others — a maddening intermittent bug that
        // only reproduces when the user releases the hotkey slowly.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // `.cghidEventTap` injects at the lowest point in the event stream, so
        // the event passes through the same path as real hardware input and is
        // seen by every tap and by the target app's normal key handling.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Post a bare Delete (backspace) keypress to the HID tap.
    ///
    /// This is the ONLY synthesised deletion in the project, and it is safe for
    /// exactly one reason: its caller has already established and read back a
    /// NON-EMPTY selection, and a Delete against a non-empty selection removes
    /// the selection and nothing else. No count is computed, so there is no
    /// unit to get wrong — which is the whole point, because the unit is not
    /// ours to choose. AppKit and Blink delete by extended grapheme cluster,
    /// readline in a terminal by code point; "ก่" is one backspace in one and
    /// two in the other, and a ZWJ emoji sequence is one or three. A count in
    /// the wrong unit is the exact class of bug that started this
    /// investigation, so we never produce one.
    ///
    /// Flags are assigned ABSOLUTELY and empty, for the same reason
    /// `postCommandV` assigns `.maskCommand` absolutely: at repair time the
    /// user may still be physically holding the Right-Option hotkey, or the OS
    /// may not have settled its release. `CGEvent.flags` is absolute rather
    /// than additive, so a bare assignment wipes inherited hardware modifier
    /// state. It matters more here than there — Cmd+Delete is "delete to
    /// beginning of line" and Option+Delete is "delete word backward", either
    /// of which would blow straight through the `count` ceiling this function
    /// exists to respect.
    ///
    /// Source and tap choices mirror `postCommandV`; read its comment before
    /// changing either. Note that the key posted here is Delete, not
    /// Right-Option, so it cannot register as the held hotkey key itself.
    private func postDeleteKey() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKey = CGKeyCode(kVK_Delete)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false)
        else { return false }

        keyDown.flags = []
        keyUp.flags = []

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Layout-aware keycode resolution

    /// Resolve the physical virtual keycode that means "v" for the purposes of a
    /// Command-key shortcut on the user's current keyboard layout.
    ///
    /// ── Why not just hardcode 9, and why not the *current* layout ────────────
    ///
    /// Hardcoding 9 (or scripting `keystroke "v"`) breaks on any layout that
    /// moves the key. Measured on this machine:
    ///
    ///     com.apple.keylayout.Dvorak        "v" is keycode 47
    ///     com.apple.keylayout.Dvorak-Right  "v" is keycode 43
    ///
    /// But the obvious fix — resolve against `TISCopyCurrentKeyboardLayoutInputSource()`
    /// — fails outright for this app's primary audience. Non-Latin layouts have
    /// no "v" at all, so the search returns nil. Measured:
    ///
    ///     com.apple.keylayout.Thai             "v" -> nil
    ///     com.apple.keylayout.Thai-PattaChote  "v" -> nil
    ///     com.apple.keylayout.Thai-QWERTY      "v" -> nil
    ///     com.apple.keylayout.Russian          "v" -> nil
    ///
    /// So we resolve against `TISCopyCurrentASCIICapableKeyboardLayoutInputSource()`
    /// instead. That is not a workaround — it is the same source macOS itself
    /// uses to route Command-key equivalents. For a Thai or Cyrillic layout it
    /// returns the paired ASCII-capable layout (ABC, keycode 9, correct: Cmd+V
    /// keeps working while typing Thai). For Dvorak it returns Dvorak itself
    /// (keycode 47, also correct).
    ///
    /// We also translate with the Command modifier bit set. For almost every
    /// layout this changes nothing, but it is exactly right for
    /// `com.apple.keylayout.DVORAK-QWERTYCMD`, the "Dvorak - Qwerty ⌘" variant
    /// that deliberately reverts to QWERTY while Command is held. Measured:
    ///
    ///     DVORAK-QWERTYCMD  "v" -> 47 without the modifier, 9 with it
    ///
    /// and 9 is the one that actually pastes.
    ///
    /// Order: ASCII-capable layout, then the current layout (in case the former
    /// is unavailable), then `fallbackVKeyCode`.
    /// Internal rather than private: exercised directly by the injection harness.
    func resolveVKeyCodeForPaste() -> CGKeyCode {
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let keyCode = keyCode(for: "v", in: source) {
            return keyCode
        }
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let keyCode = keyCode(for: "v", in: source) {
            return keyCode
        }
        Self.log.notice("Keyboard layout resolution failed; falling back to virtual keycode 9 for \"v\".")
        return Self.fallbackVKeyCode
    }

    /// Brute-force the keycode that produces `character` under `source`, with
    /// the Command modifier applied.
    ///
    /// There is no reverse-lookup API — `UCKeyTranslate` only goes keycode ->
    /// character — so we walk the 128 possible keycodes. That is a handful of
    /// microseconds and happens once per injection, which is cheap enough that
    /// caching it would only add a stale-cache bug when the user switches
    /// layouts mid-session.
    private func keyCode(for character: Character, in source: TISInputSource) -> CGKeyCode? {
        // Some input sources (legacy 'KCHR' ones, and some IME sources) carry no
        // Unicode layout data at all. Nothing to search; let the caller fall
        // through to the next source.
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        // UCKeyTranslate wants modifiers in the *old Carbon* packing: the
        // classic modifier bits shifted right by 8. Not CGEventFlags.
        let commandModifier = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())

        var found: CGKeyCode?
        layoutData.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return }
            for candidate in UInt16(0)..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    candidate,
                    UInt16(kUCKeyActionDisplay),
                    commandModifier,
                    keyboardType,
                    UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                guard status == noErr, length == 1, let scalar = UnicodeScalar(chars[0]) else {
                    continue
                }
                if Character(scalar) == character {
                    found = CGKeyCode(candidate)
                    return
                }
            }
        }
        return found
    }
}
