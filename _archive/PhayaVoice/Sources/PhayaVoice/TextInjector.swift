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
    func inject(_ text: String) -> String? {
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
                Self.log.notice("AX reported kAXSelectedText settable but the caret did not move; treating as a no-op.")
                return false
            }
        }
        return true
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

    // MARK: - Path B: clipboard + synthetic Cmd+V

    private func injectViaClipboard(_ text: String, targetID: String) -> String? {
        let pasteboard = NSPasteboard.general

        // Resolve the keycode BEFORE touching the pasteboard, so a resolution
        // failure cannot leave the user's clipboard clobbered. (It cannot fail
        // in practice — there is a hardcoded fallback — but ordering the fragile
        // step first is free.)
        let vKeyCode = resolveVKeyCodeForPaste()

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
            return "Could not write the transcript to the clipboard."
        }
        ourChangeCount = pasteboard.changeCount

        guard postCommandV(keyCode: vKeyCode) else {
            completeRestore(generation: generation, restoring: true)
            return "Could not post the paste keystroke. Check Accessibility permission in System Settings."
        }

        Self.log.info(
            "Pasted \(text.count, privacy: .public) chars into \(targetID, privacy: .public) via keycode \(vKeyCode, privacy: .public)"
        )

        // Hand the restore off to a non-blocking watcher and return. `inject` is
        // synchronous and main-actor-isolated, so *waiting* here would freeze the
        // UI for the full settle timeout. Returning `nil` now is honest: we have
        // successfully delivered the keystroke, which is the most any injector
        // can actually observe (see the receipt discussion below).
        scheduleReceiptSequencedRestore(generation: generation)
        return nil
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
    private func scheduleReceiptSequencedRestore(generation: Int) {
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.pasteSettleTimeout)
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

        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in prioritize(item.types) {
                // Check the budget *before* fetching, so one oversized
                // representation cannot drag the rest in behind it.
                guard budget > 0 else { break }
                guard let data = item.data(forType: type) else { continue }
                representations[type] = data
                budget -= data.count
            }
            if !representations.isEmpty { snapshot.append(representations) }
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
