import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Hardware constants (verified against this machine's SDK headers)
//
// Carbon HIToolbox Events.h — keycodes independent of keyboard layout:
//     kVK_Option      = 0x3A = 58   (Left Option)
//     kVK_RightOption = 0x3D = 61   (Right Option)
// IOKit hidsystem IOLLEvent.h — device-dependent modifier bits carried in
// CGEventFlags.rawValue, the only way to tell left from right:
//     NX_DEVICELALTKEYMASK = 0x20
//     NX_DEVICERALTKEYMASK = 0x40
//
// NSEvent.modifierFlags / CGEventFlags.maskAlternate collapse both Options into
// one bit, so a bare-modifier gesture MUST read either the keyCode on the
// .flagsChanged event or these device bits. We use both: the keyCode identifies
// which physical key moved, the device bit reports whether that key is
// *currently* down. Relying on keyCode alone breaks the moment the user presses
// Shift while holding Right-Option — that emits a .flagsChanged with a different
// keyCode while Right-Option is still physically held, and a "keyCode != mine,
// therefore released" rule would fire a spurious release.
//
// This is why audit finding 1 hit Right-Option and left Left-Option alone: the
// 0x40 read genuinely distinguishes them, and the bug was never in this part.
// The same bits are reused as the chord witness on .keyDown events — see
// `heldWitnessMask`.

enum ModifierKey {
    static let leftOption: UInt16 = 58      // kVK_Option
    static let rightOption: UInt16 = 61     // kVK_RightOption
    static let leftShift: UInt16 = 56       // kVK_Shift        = 0x38
    static let rightShift: UInt16 = 60      // kVK_RightShift   = 0x3C
    static let leftCommand: UInt16 = 55     // kVK_Command      = 0x37
    static let rightCommand: UInt16 = 54    // kVK_RightCommand = 0x36
    static let leftControl: UInt16 = 59     // kVK_Control      = 0x3B
    static let rightControl: UInt16 = 62    // kVK_RightControl = 0x3E
    static let function: UInt16 = 63        // kVK_Function     = 0x3F

    /// Device-dependent bit in `CGEventFlags.rawValue` that is set while this
    /// specific physical key is held. Values from IOLLEvent.h. Returns nil for
    /// keys that have no device-dependent bit (then we fall back to keyCode
    /// transition tracking plus the coarse flag).
    static func deviceBit(for keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case leftControl:   return 0x00000001   // NX_DEVICELCTLKEYMASK
        case leftShift:     return 0x00000002   // NX_DEVICELSHIFTKEYMASK
        case rightShift:    return 0x00000004   // NX_DEVICERSHIFTKEYMASK
        case leftCommand:   return 0x00000008   // NX_DEVICELCMDKEYMASK
        case rightCommand:  return 0x00000010   // NX_DEVICERCMDKEYMASK
        case leftOption:    return 0x00000020   // NX_DEVICELALTKEYMASK
        case rightOption:   return 0x00000040   // NX_DEVICERALTKEYMASK
        case rightControl:  return 0x00002000   // NX_DEVICERCTLKEYMASK
        case function:      return CGEventFlags.maskSecondaryFn.rawValue
        default:            return nil
        }
    }

    /// Coarse (left-or-right) mask for the same key. Used in the event-callback
    /// fallback for keys that have no device-dependent bit. Historical note:
    /// this mask once also drove the health-poll stuck-detector through
    /// `CGEventSource.flagsState` (device bits are not guaranteed to survive
    /// that API, hence the coarse mask) — but flagsState reflects the session's
    /// combined *event* state, which our own TextInjector's synthetic posts
    /// perturb while injecting mid-hold, so the poll now reads the HID hardware
    /// key state instead. See `pollHealth`.
    static func coarseMask(for keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case leftControl, rightControl: return .maskControl
        case leftShift, rightShift:     return .maskShift
        case leftCommand, rightCommand: return .maskCommand
        case leftOption, rightOption:   return .maskAlternate
        case function:                  return .maskSecondaryFn
        default:                        return nil
        }
    }
}

/// Toggle hotkey watcher.
///
/// ── THE APP IS IN TOGGLE MODE. READ THIS BEFORE CHANGING ANYTHING HERE ──────
/// `main.swift`'s `wireHotkey()` wires `onPressStart` to `wantsDictation.toggle()`
/// and `onPressEnd` to an explicit no-op. One completed gesture inverts dictation;
/// there is no "hold". Every hold-to-talk assumption this file used to carry was
/// wrong in a way that cost the user real damage — see AUDIT-2026-08-27 findings
/// 1 and 2 — so the words "hold" and "release" survive below only where they
/// describe the *physical key*, never the recording.
///
/// Default gesture: **tap Right-Option**. A bare modifier never produces a
/// character, and nothing in stock macOS claims Right-Option on a US layout.
///
/// The gesture is delivered on the key's **up**-edge, not its down-edge, and only
/// if no other key went down while it was held. That is the whole fix for audit
/// finding 1: Right-Option sits beside the arrow cluster on a MacBook, and on the
/// down-edge design every Option+Left/Right word-navigation chord started the
/// microphone and injected partial transcripts into the document the user was
/// editing. Down-edge delivery cannot be rescued by cancelling afterwards — by
/// then the engine is running and text has been typed — so the decision has to
/// wait for the up-edge, which is the first moment the chord is knowable. The
/// price is that dictation flips when the user lifts the key rather than when
/// they press it (~100 ms of tap plus `releaseGrace`); that was judged cheap
/// against injecting speech into someone's document.
///
/// Everything here is `@MainActor` because the tap's run-loop source is attached
/// to `CFRunLoopGetMain()`, so the C callback already executes on the main
/// thread. That is deliberate: the gesture edges must stay strictly ordered, and
/// any `Task { @MainActor in … }` hop out of the callback can reorder them.
@MainActor
final class HotkeyMonitor {

    // MARK: Callbacks

    /// Fired once per **completed, chord-free** gesture: the key went down, no
    /// other key went down while it was held, and it came back up and stayed up
    /// for `releaseGrace`. In toggle mode this is the single "the user asked to
    /// flip dictation" event; there is no second edge (see `onPressEnd`).
    ///
    /// The name is a fossil of hold-to-talk and is kept only because
    /// `main.swift`'s `wireHotkey()` binds it; renaming it is a two-file change.
    ///
    /// TIMING: this no longer runs inside the CGEventTap callback. Delivery moved
    /// to the up-edge, and the up-edge is itself deferred through
    /// `DispatchQueue.main.asyncAfter(releaseGrace)`, so this body is off the
    /// tap's latency budget entirely — the old `.tapDisabledByTimeout` exposure
    /// from a slow consumer is gone. It still runs on the main thread with the
    /// user waiting on it, so keep it to a flag flip plus a deferred hop; that is
    /// exactly what `wireHotkey()` does today. NOTE: `wireHotkey()`'s own comment
    /// still claims it "runs synchronously inside the CGEventTap callback" — that
    /// is now stale, and correcting it belongs to whoever owns `main.swift`.
    var onPressStart: () -> Void = {}

    /// **NEVER FIRED.** Toggle mode deleted the concept it reported.
    ///
    /// Audit finding 2 counted this among four stuck-microphone defences that
    /// were all gated on `isHolding` and therefore all inert: `onPressEnd` used
    /// to mean "the key came up, stop recording", but in toggle mode recording
    /// is not tied to the key being down, so there is nothing for a second edge
    /// to end. `main.swift` already assigns it an explicit `{ }`. The property
    /// survives only because that assignment exists and `main.swift` is not
    /// ours to edit; delete both together.
    ///
    /// Do not "restore" a firing site to make it look symmetric. The real
    /// off-switch for a microphone this monitor can no longer reach is
    /// `onHotkeyUnusable` below.
    var onPressEnd: () -> Void = {}

    /// Fires when the tap dies and the hotkey can no longer reach the user.
    /// Main-actor. Fires once per transition into the unusable state, not per poll.
    ///
    /// ── WHY THIS EXISTS (audit finding 2) ──────────────────────────────────────
    /// Secure Event Input — screen lock, or focus landing in any password field —
    /// kills every session event tap machine-wide. In toggle mode that is a trap
    /// with no exit: dictation is ON, the only off-switch is this hotkey, and the
    /// hotkey has just gone deaf. Capture keeps running and keeps injecting. Every
    /// defence the file had was gated on `isHolding`, which toggle mode made true
    /// for ~100 ms per tap, so all of them returned immediately.
    ///
    /// This monitor reports the fact; the policy (stopping capture) belongs to
    /// `main.swift`. Safe to leave unset, and safe to fire with nothing
    /// recording — the consumer is expected to no-op.
    ///
    /// EDGE-TRIGGERED. `pollHealth` runs at 1 Hz and would otherwise re-report
    /// the same dead tap every second; `unusableReported` latches, and any
    /// successful (re-)enable clears the latch so a later death fires again.
    /// `isHealthy` is deliberately NOT edge-triggered — it blips false on every
    /// recovered hiccup and the menu wants that live reading. The two answer
    /// different questions: `isHealthy` is "is the tap up right now",
    /// `onHotkeyUnusable` is "recovery was attempted and refused".
    var onHotkeyUnusable: (() -> Void)?

    // MARK: Timing constants
    //
    // Every value below is a deliberate choice, not a magic number.

    /// Minimum quiet time between a completed gesture and the next accepted
    /// down-edge. TOGGLE MODE changed what this window is allowed to eat: every
    /// accepted gesture now inverts dictation on/off, so a swallowed one is
    /// not a delayed retry — it leaves the user in the opposite state they
    /// believe they are in (mic hot, typing into whatever has focus). The
    /// canonical victim is the fast undo: an accidental tap turns dictation
    /// ON, the instinctive second tap to undo lands ~50–100 ms later, and a
    /// hold-to-talk-sized window silently eats it. So this window must absorb
    /// ONLY electrical contact bounce — a mechanical switch settles in well
    /// under 10 ms — never a human double-tap, however fast.
    private let debounceInterval: TimeInterval = 0.010

    /// Grace window after the key appears to lift. If it comes back down inside
    /// this window we treat it as one continuous gesture rather than two.
    ///
    /// Up-edge delivery made this window strictly benign, which it was not
    /// before. Under the old down-edge design a bounce swallowed the returning
    /// down-edge and therefore *lost* a toggle — an inverted privacy state. Now
    /// the toggle rides the up-edge, and a bounce (up, then down inside the
    /// window) simply defers delivery to the real up-edge: still exactly one
    /// `onPressStart` for one physical tap, none lost. 10 ms outlasts any switch
    /// bounce or momentary flags glitch, and no human tap can come back down
    /// this fast, so a deliberate double-tap is never merged.
    private let releaseGrace: TimeInterval = 0.010

    /// How often we poll tap liveness. Secure Event Input kills every event tap
    /// machine-wide and delivers *no* callback while doing so, so the callback
    /// branch alone cannot notice. 1 Hz recovers within a second of the password
    /// field losing focus while costing nothing measurable.
    private let healthPollInterval: TimeInterval = 1.0

    /// Hard ceiling on how long one gesture may stay open.
    ///
    /// HONEST SCOPE, and it is narrower than the old name `maxHoldDuration`
    /// implied. This is NOT a stuck-microphone defence — audit finding 2 listed
    /// the old version among four that only looked like one. Nothing about
    /// capture is tied to the key being down any more, so a key held for an hour
    /// records nothing extra and this timer stops nothing.
    ///
    /// What it does protect is the hotkey's own reachability. If the up-edge is
    /// ever lost (tap died mid-gesture, event eaten by a system modal),
    /// `isHolding` stays true and `updateGesture`'s `guard !isHolding` swallows
    /// every subsequent down-edge — the hotkey goes permanently deaf with
    /// `isHealthy` still reporting true. Abandoning the gesture restores it. The
    /// user-visible off-switch when the tap itself is dead is `onHotkeyUnusable`.
    ///
    /// 120 s is kept from the hold-to-talk era; the exact value stopped mattering
    /// once nothing is recording, and any number far above a tap works.
    private let maxGestureDuration: TimeInterval = 120.0

    // MARK: Configuration

    /// Which physical key to watch. `Settings.hotkeyKeyCode` reads through
    /// `UserDefaults.integer(forKey:)`, which returns 0 when the key was never
    /// written — and 0 is a *valid* keyCode (kVK_ANSI_A). So 0 means "unset",
    /// and we fall back to Right-Option rather than binding the letter A.
    let keyCode: UInt16

    private let deviceBit: UInt64?
    private let coarseMask: CGEventFlags?

    /// Raw-flag mask that says "our key was physically down when this event was
    /// generated". Precomputed in `init` because it is read on the `.keyDown`
    /// path, which now sees every keystroke — see `installTap` and `handle`.
    ///
    /// Both bits are OR'd deliberately. The device bit (`0x40` for Right-Option)
    /// is the precise answer; the coarse bit (`.maskAlternate`) is the certain
    /// one. Certain by argument, not by measurement — say so plainly, because
    /// the whole chord fix rests on it: `CGEventFlags` on a keyboard event is
    /// the modifier state at the moment the event was generated, and if
    /// `maskAlternate` were absent from a Left-arrow keyDown pressed while
    /// Option is held, the focused app could not tell Option+Left from Left, so
    /// word-navigation could not work at all. It demonstrably does. Relying on
    /// the *device* bit alone would instead stake the fix on that finer bit
    /// being replicated onto keyDown events as well as onto flagsChanged
    /// events, which is not documented anywhere and which cannot be tested
    /// without a second live tap; if that finer assumption is wrong the coarse
    /// bit still catches the chord and finding 1 stays fixed. If BOTH are
    /// somehow wrong, finding 1 is live again and silent — that is the one
    /// failure mode worth re-checking on real hardware.
    private let heldWitnessMask: UInt64

    // MARK: Tap state

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: DispatchSourceTimer?

    /// False whenever the tap does not exist or the system has disabled it —
    /// no Accessibility permission yet, timed out, overloaded, or suppressed by
    /// Secure Event Input. The app should surface this; a silently dead tap is
    /// the classic cause of "dictation randomly stopped working".
    private(set) var isHealthy: Bool = false

    /// Latch behind `onHotkeyUnusable`, so a 1 Hz poll over a permanently dead
    /// tap reports the death once rather than once a second. Cleared by
    /// `noteTapUsable()` on any successful (re-)enable.
    private var unusableReported: Bool = false

    // MARK: Gesture state

    /// True while our physical key is down — nothing more.
    ///
    /// It used to be documented as "the only source of truth for 'are we
    /// recording'". In toggle mode that sentence was false and was the proximate
    /// cause of audit finding 2: recording outlives the key by design, so every
    /// defence written as `guard isHolding` silently became a no-op. Do not
    /// reintroduce that reading. Whether the microphone is live is
    /// `main.swift`'s `wantsDictation` / `isCapturing`, and this class cannot
    /// see it.
    private(set) var isHolding: Bool = false

    private var holdStartedAt: Date?
    private var lastReleaseAt: Date?
    /// Bumped on every gesture state change so a deferred release that has been
    /// superseded can identify itself as stale and do nothing.
    private var releaseGeneration: UInt64 = 0
    private var releasePending: Bool = false

    /// ── THE ENTIRE MEMORY THIS TAP KEEPS OF THE USER'S TYPING ──────────────────
    /// One bit: "some other key went down while our key was held". No keycode is
    /// stored, logged, branched on, or compared — see `handle`'s `.keyDown` case,
    /// which reads the event's modifier flags and nothing else. This file must
    /// stay auditable at a glance as not retaining what the user types, because
    /// adding `.keyDown` to the tap mask is what makes it capable of that.
    ///
    /// Cleared at the down-edge that opens a gesture, NOT at the end of one.
    /// Clearing it at the end would leave it set by the last thing the user ever
    /// typed, and the next tap — and every tap after it — would be cancelled: a
    /// hotkey that dies for good the first time anyone touches the keyboard.
    private var sawChordKeyDown: Bool = false

    /// Snapshot of `!sawChordKeyDown` taken at the up-edge, because the interval
    /// that defines a chord ends there. Deciding later, inside the deferred
    /// `finishGesture`, would let a keystroke landing in the `releaseGrace`
    /// window cancel a gesture that was already chord-free.
    private var pendingGestureIsHotkey: Bool = false

    /// Consecutive health polls in which `CGEventSource.keyState(.hidSystemState)`
    /// claimed our key was not physically down while we believed it was. See
    /// `pollHealth`.
    private var keyStateMisses: Int = 0

    // MARK: Init

    init(keyCode: UInt16? = nil) {
        // PhayaVoice's Settings struct was not ported; it read exactly this one
        // default. Inlined rather than dragging a whole settings layer across.
        //
        // Two ways this used to go wrong, both silent, both now traced.
        var rejection: String?
        var candidate: UInt16?

        if let explicit = keyCode {
            candidate = explicit
        } else {
            // (a) `UInt16(UserDefaults.standard.integer(forKey:))` is the
            // TRAPPING initializer. `defaults write … hotkeyKeyCode -1` killed
            // the app during AppDelegate construction — before
            // applicationDidFinishLaunching, so before any of the launch
            // diagnostics ran — with no message a user could act on.
            // `UInt16(exactly:)` turns that crash into a rejection we can
            // explain. 0 keeps its existing meaning of "never written": it is a
            // valid keyCode (kVK_ANSI_A) but binding dictation to the letter A
            // is never what an unset default meant.
            let stored = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
            if stored != 0 {
                if let narrowed = UInt16(exactly: stored) {
                    candidate = narrowed
                } else {
                    rejection = "hotkeyKeyCode=\(stored) is outside UInt16"
                }
            }
        }

        // (b) An in-range but non-modifier keycode (49 = Space, say) installed a
        // tap that could never fire: this monitor observes `.flagsChanged`, and
        // an ordinary key does not emit one. The hotkey was silently dead while
        // `isHealthy` cheerfully reported true. `coarseMask(for:)` is the exact
        // discriminator — its table and `deviceBit(for:)`'s cover the same nine
        // keys, so a key with a coarse mask is precisely a key we can observe.
        if let c = candidate, ModifierKey.coarseMask(for: c) == nil {
            rejection = "hotkeyKeyCode=\(c) is not a modifier this .flagsChanged tap can observe"
            candidate = nil
        }

        let resolved = candidate ?? ModifierKey.rightOption
        self.keyCode = resolved
        let bit = ModifierKey.deviceBit(for: resolved)
        let coarse = ModifierKey.coarseMask(for: resolved)
        self.deviceBit = bit
        self.coarseMask = coarse
        self.heldWitnessMask = (bit ?? 0) | (coarse?.rawValue ?? 0)

        if let rejection {
            // Both sinks on purpose. This runs during AppDelegate construction,
            // so the trace file may be the only record if the app is launched
            // from Finder, and stderr may be the only record if /tmp is
            // unwritable — the exact combination that made the old trap
            // undiagnosable. `trace()` opens its own fd per call, so it is safe
            // this early; there is nothing to initialise first.
            let message = "hotkey config rejected: \(rejection) — "
                + "falling back to Right-Option (\(ModifierKey.rightOption))"
            FileHandle.standardError.write(Data("PhayaVoice: \(message)\n".utf8))
            trace(message)
        }
    }

    // MARK: Permission

    /// A CGEventTap on `.flagsChanged` + `.keyDown` requires Accessibility (TCC
    /// kTCCServiceAccessibility). Without it `CGEvent.tapCreate` simply returns
    /// nil, with no error and no prompt. Adding `.keyDown` to the mask did not
    /// change the permission required — the same grant already allowed it.
    nonisolated func permissionGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt if the user has not decided yet.
    /// Separate from `permissionGranted()` so callers can check silently.
    nonisolated func requestPermission() -> Bool {
        // The literal spells out `kAXTrustedCheckOptionPrompt`, which AXUIElement.h
        // declares as a plain mutable `extern CFStringRef` — Swift 6 strict
        // concurrency rejects reading it as shared mutable state. Its value was
        // read back from the framework on this machine and is "AXTrustedCheckOptionPrompt".
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Lifecycle

    func start() {
        guard tapPort == nil else { return }
        installTap()
        startHealthTimer()
    }

    func stop() {
        stopHealthTimer()
        // Leaves `isHolding` false so a later `start()` is not deafened by a
        // gesture nobody will ever close.
        abandonGestureIfOpen(reason: "monitor stopped")
        teardownTap()
        isHealthy = false
        // Deliberately does NOT fire `onHotkeyUnusable`. This is the app taking
        // the tap down on purpose (applicationWillTerminate); the consumer is
        // already shutting capture down through its own path, and a "the hotkey
        // died" report during teardown is noise that would teach the next reader
        // to distrust the signal. The latch is left alone so that if `start()`
        // is called again and fails, that genuine failure still reports.
    }

    // MARK: Tap installation

    private func installTap() {
        // ── .keyDown IS IN THIS MASK BY AN EXPLICIT, INFORMED USER DECISION ────────
        // A `.flagsChanged`-only tap cannot see a keyDown, and therefore cannot
        // tell "Right-Option tapped alone" from "Right-Option held as a chord
        // modifier". That is audit finding 1, and it is not a cosmetic one: every
        // Option+Left/Right word-navigation chord started the microphone and
        // injected partial transcripts into whatever the user was editing, with
        // an odd number of chords leaving the mic live indefinitely.
        //
        // The cost was weighed and accepted: this tap now observes every
        // keystroke typed outside Secure Event Input. What the process retains
        // from that stream is ONE BOOLEAN (`sawChordKeyDown`) — the `.keyDown`
        // case in `handle` reads the event's modifier flags, sets a flag, and
        // returns. It never reads `.keyboardEventKeycode`, never stores, logs,
        // traces or branches on which key it was, and `trace()`'s standing rule
        // against writing user text applies here more sharply than anywhere else
        // in the app. Keep it that way; this file should be auditable as
        // non-retaining by reading one short case statement.
        //
        // (Secure Event Input, which is what hides password fields from taps,
        // disables this tap wholesale — see `pollHealth` — so those keystrokes
        // never reach us at all.)
        //
        // KNOWN REMAINING HOLE, stated rather than papered over: mouse events
        // are not masked, so Option+click and Option+drag — duplicate-drag in
        // Finder, open-in-background in a browser, expand-all on a disclosure
        // triangle — are still read as a bare Option tap and still toggle. Fixing
        // it means masking `.leftMouseDown` and friends, i.e. widening this tap
        // past the keyboard, which was not the trade the user agreed to. It is a
        // smaller hole than the arrow-key one (finding 1's measured trigger) but
        // it is the same hole, and it is the next thing to fix here.
        //
        // The two disable notifications (.tapDisabledByTimeout /
        // .tapDisabledByUserInput) are NOT maskable — they are delivered to the
        // callback whatever the mask says, and are handled by branching on
        // `type` inside the callback. Trying to OR them into eventsOfInterest is
        // a common and silent mistake.
        let mask: CGEventMask =
            (CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue))
            | (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // The run-loop source lives on the main run loop, so we are already
            // on the main thread and can enter main-actor context without a hop.
            MainActor.assumeIsolated {
                monitor.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        // .listenOnly is essential, and doubly so now that the mask includes
        // .keyDown. With .defaultTap we could swallow or delay the user's own
        // typing as well as the Right-Option event, breaking both for every
        // other app — and a listen-only tap is also cheaper for the window
        // server. The chord is therefore *cancelled*, never consumed.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Almost always "Accessibility not granted yet". The health timer
            // keeps retrying, so granting permission takes effect without a
            // relaunch — but until it does the hotkey cannot reach the user, and
            // in toggle mode that may be the only way to stop a live microphone.
            isHealthy = false
            reportUnusable("tap could not be created (Accessibility not granted?)")
            return
        }

        // Previously unchecked. `CFMachPortCreateRunLoopSource` is declared
        // implicitly-unwrapped, so a nil here would have crashed on the next
        // line rather than degrading — and a port with no run-loop source is a
        // tap that exists, reports `tapIsEnabled == true`, and delivers nothing.
        // That is precisely the "silently dead tap" shape finding 2 is about.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            isHealthy = false
            reportUnusable("run-loop source could not be created for the tap")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tapPort = port
        runLoopSource = source
        isHealthy = CGEvent.tapIsEnabled(tap: port)
        if isHealthy {
            noteTapUsable()
        } else {
            reportUnusable("tap created but refused to enable")
        }
    }

    private func teardownTap() {
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tapPort = nil
        runLoopSource = nil
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        // FIRST CASE ON PURPOSE: this is now the hot one. Every keystroke the
        // user types routes through here, and a CGEventTap callback the system
        // considers slow gets the tap disabled out from under us
        // (.tapDisabledByTimeout), which presents as "dictation randomly stopped
        // working". So the whole body is: read one field, mask, store. No
        // allocation, no lock, no trace(), no main-queue hop, and deliberately
        // no read of `.keyboardEventKeycode` — see `sawChordKeyDown`.
        //
        // The flags test is not an optimisation, it is a correctness guard.
        // `TextInjector.postCommandV` posts synthetic Cmd-V keyDowns at
        // `.cghidEventTap` — its own comment says they are "seen by every tap",
        // and that includes this one — once per injected partial. Counting those
        // as a chord would let our own typing eat the user's toggle-OFF tap and
        // strand the microphone on: exactly the failure this file exists to
        // prevent. Those events carry `flags = .maskCommand` and nothing else,
        // so requiring our key's own modifier bit excludes them, while a genuine
        // Option+Left keyDown carries it by construction.
        case .keyDown:
            if (event.flags.rawValue & heldWitnessMask) != 0 { sawChordKeyDown = true }

        case .flagsChanged:
            let movedKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let down = keyIsDown(flags: event.flags, movedKey: movedKey)
            updateGesture(down: down)

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables a tap whose callback took too long, or when
            // the user floods input. Re-enabling on the same port is the
            // documented recovery; skipping it is why "the hotkey works for an
            // hour and then silently dies".
            isHealthy = false
            abandonGestureIfOpen(reason: "tap disabled by system")
            if let port = tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
                isHealthy = CGEvent.tapIsEnabled(tap: port)
            }
            // A re-enable that TOOK is a recovery, not a death, and must not
            // fire `onHotkeyUnusable`: by the time this callback returns the
            // hotkey is reachable again, having missed only the events in flight
            // during the disable. Firing here would ask `main.swift` to stop
            // capture on every routine timeout hiccup — a self-inflicted
            // mid-sentence cut-off, worse for the user than the bug. Only a
            // refused re-enable means the user has lost the off-switch.
            if isHealthy {
                noteTapUsable()
            } else {
                reportUnusable("tap disabled by system and the re-enable was refused")
            }

        default:
            break
        }
    }

    /// Current physical state of *our* key, given one `.flagsChanged` event.
    private func keyIsDown(flags: CGEventFlags, movedKey: UInt16) -> Bool {
        if let bit = deviceBit {
            // Preferred path: the device-dependent bit is present on every
            // flagsChanged event regardless of which key moved, so holding
            // Right-Option and then tapping Shift keeps reporting `true`.
            return (flags.rawValue & bit) != 0
        }
        // Fallback for a key with no device bit: only trust events for that key,
        // and use the coarse mask to tell down from up.
        guard movedKey == keyCode else { return isHolding }
        guard let coarse = coarseMask else { return isHolding }
        return flags.contains(coarse)
    }

    // MARK: Gesture state machine

    // ── THE STATE MACHINE, IN WORDS ────────────────────────────────────────────
    //   down-edge   → open a gesture; CLEAR `sawChordKeyDown` (see its comment
    //                 for why clearing here and nowhere else is load-bearing)
    //   any keyDown → set `sawChordKeyDown` (in `handle`, not here)
    //   up-edge     → snapshot `pendingGestureIsHotkey = !sawChordKeyDown`, then
    //                 defer by `releaseGrace`
    //   grace ends  → close the gesture, and deliver `onPressStart` ONLY if the
    //                 snapshot says chord-free
    //   abandon     → close the gesture and deliver NOTHING
    // A gesture we could not watch to its end is not a gesture we may act on:
    // the tap that went dead is the same tap that would have shown us the chord
    // keyDowns, so `abandonGestureIfOpen` never toggles.

    private func updateGesture(down: Bool) {
        if down {
            if releasePending {
                // Key came back inside the grace window: at contact-bounce
                // scale (see `releaseGrace`) this can only be electrical
                // bounce, not a real re-press. Rejoin the one gesture. Note
                // `sawChordKeyDown` is deliberately NOT cleared here — a chord
                // key pressed before the bounce still cancels — and no toggle is
                // lost, because delivery rides the eventual real up-edge.
                releasePending = false
                releaseGeneration &+= 1
                return
            }
            guard !isHolding else { return }
            if let last = lastReleaseAt,
               Date().timeIntervalSince(last) < debounceInterval {
                return  // debounced: contact bounce only — see `debounceInterval`
            }
            beginGesture()
        } else {
            guard isHolding, !releasePending else { return }
            scheduleRelease()
        }
    }

    private func beginGesture() {
        isHolding = true
        keyStateMisses = 0
        holdStartedAt = Date()
        releasePending = false
        // Fresh gesture, fresh verdict. Everything the user typed before this
        // instant is irrelevant to it, and forgetting that is what would make
        // the hotkey die permanently after the first keystroke of the session.
        sawChordKeyDown = false
        pendingGestureIsHotkey = false
        releaseGeneration &+= 1
    }

    private func scheduleRelease() {
        releasePending = true
        // The chord window closes HERE, at the up-edge, not when the deferred
        // block runs `releaseGrace` later.
        pendingGestureIsHotkey = !sawChordKeyDown
        releaseGeneration &+= 1
        let generation = releaseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseGrace) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.releasePending, self.releaseGeneration == generation else { return }
                self.finishGesture()
            }
        }
    }

    private func finishGesture() {
        guard isHolding else { return }
        let deliver = pendingGestureIsHotkey
        isHolding = false
        keyStateMisses = 0
        releasePending = false
        pendingGestureIsHotkey = false
        holdStartedAt = nil
        lastReleaseAt = Date()
        releaseGeneration &+= 1
        // Nothing is fired for a chord. `.listenOnly` means the chord itself
        // reaches the focused app untouched, exactly as the user intended — we
        // simply decline to read it as a hotkey. And nothing fires `onPressEnd`,
        // here or anywhere: toggle mode deleted what it meant. See its doc.
        if deliver { onPressStart() }
    }

    /// Close an open gesture without delivering it. Used whenever we lose the
    /// ability to watch the gesture to its end.
    ///
    /// Was `synthesizeReleaseIfHolding` (audit finding 2 cites it under that
    /// name), and the rename is the point. It never was a microphone off-switch
    /// in toggle mode — `guard isHolding` made it a no-op for all but the ~100 ms
    /// a physical tap is down — and pretending otherwise is what let a live
    /// microphone survive Secure Event Input with nothing able to stop it. What
    /// it genuinely does is keep the hotkey reachable: without it a lost up-edge
    /// pins `isHolding` true and `updateGesture` swallows every later press.
    /// The off-switch is `onHotkeyUnusable`.
    ///
    /// It must NOT deliver `onPressStart`. The tap we just lost is the same tap
    /// that reports chord keyDowns, so a gesture interrupted this way has an
    /// unknowable verdict — and "unknowable" must mean "do not turn on the
    /// microphone", never the reverse.
    private func abandonGestureIfOpen(reason: String) {
        guard isHolding else { return }
        let heldMS = holdStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        let message = "abandoned in-flight hotkey gesture (no toggle delivered): \(reason) "
            + "(keyStateMisses=\(keyStateMisses), heldMs=\(heldMS))"
        FileHandle.standardError.write(Data("PhayaVoice: \(message)\n".utf8))
        // trace() does synchronous file I/O, and one caller of this method (the
        // .tapDisabledBy* branch of `handle`) runs inside the tap callback's
        // latency budget. Hop the file write off that budget, same pattern as
        // main.swift's press handlers; the stderr line above is cheap enough to
        // stay inline. No transcript text goes anywhere near this line.
        Task { @MainActor in trace(message) }

        isHolding = false
        keyStateMisses = 0
        releasePending = false
        pendingGestureIsHotkey = false
        holdStartedAt = nil
        lastReleaseAt = Date()
        releaseGeneration &+= 1
    }

    // MARK: Unusable-tap reporting

    /// Clear the `onHotkeyUnusable` latch. Called on every successful
    /// (re-)enable so a *later* death fires again.
    private func noteTapUsable() {
        unusableReported = false
    }

    /// Edge-trigger `onHotkeyUnusable`.
    ///
    /// The latch is taken synchronously and the consumer is called from a
    /// deferred main-queue block. Both halves matter: latching inline is what
    /// stops two 1 Hz polls, or a poll racing the tap callback, from
    /// double-firing; deferring the call is what keeps an arbitrarily expensive
    /// consumer (it is going to tear down an audio engine) off the tap's own
    /// latency budget when this is reached from `handle`'s `.tapDisabledBy*`
    /// branch. Same reasoning as the `Task { @MainActor in trace(…) }` hop in
    /// `abandonGestureIfOpen`.
    private func reportUnusable(_ reason: String) {
        guard !unusableReported else { return }
        unusableReported = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                trace("hotkey unusable: \(reason) — notifying consumer")
                self.onHotkeyUnusable?()
            }
        }
    }

    // MARK: Health polling / Secure Event Input recovery

    private func startHealthTimer() {
        stopHealthTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + healthPollInterval, repeating: healthPollInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.pollHealth()
            }
        }
        timer.resume()
        healthTimer = timer
    }

    private func stopHealthTimer() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    private func pollHealth() {
        // Case 1: the tap never got created (no Accessibility permission at
        // launch). Retry, so granting it in System Settings works live.
        guard let port = tapPort else {
            if permissionGranted() {
                installTap()   // reports its own failure
            } else {
                reportUnusable("no Accessibility permission; tap cannot be created")
            }
            return
        }

        // Case 2: Secure Event Input. While any app holds SEI — screen lock, or
        // focus in any password field — every event tap in the session goes dead
        // with no callback to tell us. Polling CGEvent.tapIsEnabled is the only
        // way to notice, and re-enabling once SEI clears is the only way back.
        //
        // This is the exact route of audit finding 2. The poll noticed correctly
        // and then called a defence that was gated on `isHolding` and returned
        // immediately; dictation stayed on, the hotkey was deaf for the same
        // reason the poll had just detected, and nothing else could stop the
        // microphone. `reportUnusable` is the missing half — and it is
        // deliberately after the re-enable attempt, so an SEI window that has
        // already closed by the time we poll costs the user nothing.
        let enabled = CGEvent.tapIsEnabled(tap: port)
        if !enabled {
            isHealthy = false
            abandonGestureIfOpen(reason: "tap dead (Secure Event Input?)")
            CGEvent.tapEnable(tap: port, enable: true)
            isHealthy = CGEvent.tapIsEnabled(tap: port)
            if isHealthy {
                noteTapUsable()
            } else {
                reportUnusable("tap dead and the re-enable was refused (Secure Event Input?)")
            }
            return
        }
        isHealthy = true
        noteTapUsable()

        // Case 3: a gesture that never closed. NOT a stuck-microphone detector —
        // see `maxGestureDuration` for what this is actually for, and finding 2
        // for why the difference is worth spelling out.
        guard isHolding, let started = holdStartedAt else { return }

        if Date().timeIntervalSince(started) > maxGestureDuration {
            abandonGestureIfOpen(reason: "gesture open past maxGestureDuration")
            return
        }

        // State-poll release synthesis is DISABLED — measured on this machine,
        // both available state APIs lie while the key is genuinely down:
        //
        //   flagsState(.combinedSessionState) is perturbed by our own injected
        //   events (the original mid-sentence cut-off bug), and
        //   keyState(.hidSystemState, key: 61) reported "up" from the FIRST
        //   poll of every real hold (trace 1:58:57-1:59:19: miss 1/3 within a
        //   second of press, synthesized release at heldMs=2768 and 2087 while
        //   the user was still holding — a remapper or TCC gating leaves the
        //   HID table blind to this key).
        //
        // Under hold-to-talk that made a state-based detector catastrophic: it
        // cut real dictation off mid-sentence. Toggle mode DEFUSED that specific
        // consequence — closing a gesture no longer stops anything — so the
        // measurement above is now evidence that the API is unreliable rather
        // than evidence of live damage. It stays disabled because an unreliable
        // input is still not something to build a detector on, not because the
        // old blast radius is still there.
        //
        // So: trust the tap. It is .listenOnly on the session tap and
        // demonstrably delivers every real press/release (that is how gestures
        // begin at all). A real release always produces a .flagsChanged event;
        // the only way to LOSE one is a dead tap, and Case 2 above both abandons
        // the gesture and reports the tap unusable the moment that happens. The
        // remaining backstop for a gesture that never closes is
        // maxGestureDuration.
        //
        // The poll below is DIAGNOSTIC ONLY, and toggle mode narrowed even that:
        // a gesture is now a ~100 ms tap rather than a multi-second hold, and
        // this runs at 1 Hz, so it samples inside a gesture maybe one time in
        // ten. Under hold-to-talk it saw nearly every hold. Do not read a silent
        // trace as "the HID table agrees now" — read it as "we mostly stopped
        // looking". Logs the first disagreement per gesture and resets on
        // agreement.
        if CGEventSource.keyState(.hidSystemState, key: keyCode) {
            keyStateMisses = 0
            return
        }
        keyStateMisses += 1
        if keyStateMisses == 1 {
            // pollHealth runs from the main-queue timer, never inside the tap
            // callback, so calling trace() inline is fine here.
            trace("hotkey health: HID claims key up while gesture open (diagnostic only; "
                + "state-poll release synthesis disabled on this machine)")
        }
    }
}
