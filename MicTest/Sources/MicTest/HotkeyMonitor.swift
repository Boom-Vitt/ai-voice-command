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
// one bit, so a bare-modifier push-to-talk gesture MUST read either the keyCode
// on the .flagsChanged event or these device bits. We use both: the keyCode
// identifies which physical key moved, the device bit reports whether that key
// is *currently* down. Relying on keyCode alone breaks the moment the user
// presses Shift while holding Right-Option — that emits a .flagsChanged with a
// different keyCode while Right-Option is still physically held, and a
// "keyCode != mine, therefore released" rule would fire a spurious release.

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

/// Hold-to-talk hotkey watcher.
///
/// Default gesture: **hold Right-Option**. A bare modifier is the standard
/// push-to-talk gesture, it never produces a character, and nothing in stock
/// macOS claims Right-Option on a US layout.
///
/// Everything here is `@MainActor` because the tap's run-loop source is attached
/// to `CFRunLoopGetMain()`, so the C callback already executes on the main
/// thread. That is deliberate: press and release must stay strictly ordered, and
/// any `Task { @MainActor in … }` hop out of the callback can reorder them and
/// leave a recording that never stops.
@MainActor
final class HotkeyMonitor {

    // MARK: Callbacks

    /// Fired the instant the key goes down.
    ///
    /// LATENCY CONTRACT: this runs *synchronously inside the CGEventTap
    /// callback*, so it spends the tap's own time budget. A callback that takes
    /// too long is exactly what makes the system post `.tapDisabledByTimeout`
    /// and kill the tap. Keep this to single-digit milliseconds — flip a flag,
    /// call `AudioRecorder.startCapture()` (which is designed to be ~free) — and
    /// defer anything heavier, including the first HUD layout, to a
    /// `DispatchQueue.main.async`.
    var onPressStart: () -> Void = {}

    /// Fired when the key has been up for `releaseGrace`, or immediately on a
    /// synthesized release. Unlike `onPressStart` this runs from a deferred main-
    /// queue block rather than inside the tap callback, so it is not on the
    /// tap's latency budget.
    var onPressEnd: () -> Void = {}

    // MARK: Timing constants
    //
    // Every value below is a deliberate choice, not a magic number.

    /// Minimum quiet time between a completed release and the next accepted
    /// press. TOGGLE MODE changed what this window is allowed to eat: every
    /// accepted down-edge now inverts dictation on/off, so a swallowed edge is
    /// not a delayed retry — it leaves the user in the opposite state they
    /// believe they are in (mic hot, typing into whatever has focus). The
    /// canonical victim is the fast undo: an accidental tap turns dictation
    /// ON, the instinctive second tap to undo lands ~50–100 ms later, and a
    /// hold-to-talk-sized window silently eats it. So this window must absorb
    /// ONLY electrical contact bounce — a mechanical switch settles in well
    /// under 10 ms — never a human double-tap, however fast.
    private let debounceInterval: TimeInterval = 0.010

    /// Grace window after the key appears to lift. If it comes back down inside
    /// this window we treat the gesture as one continuous hold rather than
    /// stop → start — which means the returning down-edge is swallowed: it
    /// rejoins the old hold and never fires `onPressStart`. In TOGGLE MODE a
    /// swallowed down-edge is an inverted privacy state (the undo-tap that was
    /// supposed to turn the mic off instead vanishes, and the mic stays hot),
    /// so like `debounceInterval` this window may only absorb electrical
    /// contact bounce, not a deliberate re-press. 10 ms still outlasts any
    /// switch bounce or momentary flags glitch; no human tap can physically
    /// come back down this fast.
    private let releaseGrace: TimeInterval = 0.010

    /// How often we poll tap liveness. Secure Event Input kills every event tap
    /// machine-wide and delivers *no* callback while doing so, so the callback
    /// branch alone cannot notice. 1 Hz recovers within a second of the password
    /// field losing focus while costing nothing measurable.
    private let healthPollInterval: TimeInterval = 1.0

    /// Hard ceiling on a single hold. Dictation turns are seconds, not minutes;
    /// anything past two minutes means we missed a release (tap died mid-hold,
    /// key event lost to a system modal) and are burning disk on a stuck
    /// recording. Force a synthesized release at this point.
    private let maxHoldDuration: TimeInterval = 120.0

    /// Consecutive health polls on which the HID hardware state must report our
    /// key "up" — while we still believe we are holding — before we synthesize
    /// a release. At `healthPollInterval` (1 Hz) this is ~3 s: enough to absorb
    /// a transient bad read, while a genuinely stuck hold (tap died mid-hold)
    /// still clears long before `maxHoldDuration`. The old flagsState detector
    /// used 2; we keep extra margin because a false positive here cuts a real
    /// dictation off mid-sentence — the worst possible failure.
    private let keyStateMissThreshold = 3

    // MARK: Configuration

    /// Which physical key to watch. `Settings.hotkeyKeyCode` reads through
    /// `UserDefaults.integer(forKey:)`, which returns 0 when the key was never
    /// written — and 0 is a *valid* keyCode (kVK_ANSI_A). So 0 means "unset",
    /// and we fall back to Right-Option rather than binding the letter A.
    let keyCode: UInt16

    private let deviceBit: UInt64?
    private let coarseMask: CGEventFlags?

    // MARK: Tap state

    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: DispatchSourceTimer?

    /// False whenever the tap does not exist or the system has disabled it —
    /// no Accessibility permission yet, timed out, overloaded, or suppressed by
    /// Secure Event Input. The app should surface this; a silently dead tap is
    /// the classic cause of "dictation randomly stopped working".
    private(set) var isHealthy: Bool = false

    // MARK: Gesture state

    /// True between a delivered `onPressStart` and its matching `onPressEnd`.
    /// This is the only source of truth for "are we recording"; it is never
    /// derived twice from the same event.
    private(set) var isHolding: Bool = false

    private var holdStartedAt: Date?
    private var lastReleaseAt: Date?
    /// Bumped on every gesture state change so a deferred release that has been
    /// superseded can identify itself as stale and do nothing.
    private var releaseGeneration: UInt64 = 0
    private var releasePending: Bool = false
    /// Consecutive health polls in which `CGEventSource.keyState(.hidSystemState)`
    /// claimed our key was not physically down while we believed it was. See
    /// `pollHealth`.
    private var keyStateMisses: Int = 0

    // MARK: Init

    init(keyCode: UInt16? = nil) {
        // PhayaVoice's Settings struct was not ported; it read exactly this one
        // default. Inlined rather than dragging a whole settings layer across.
        let configured = keyCode ?? UInt16(UserDefaults.standard.integer(forKey: "hotkeyKeyCode"))
        let resolved = configured == 0 ? ModifierKey.rightOption : configured
        self.keyCode = resolved
        self.deviceBit = ModifierKey.deviceBit(for: resolved)
        self.coarseMask = ModifierKey.coarseMask(for: resolved)
    }

    // MARK: Permission

    /// A CGEventTap on `.flagsChanged` requires Accessibility (TCC
    /// kTCCServiceAccessibility). Without it `CGEvent.tapCreate` simply returns
    /// nil, with no error and no prompt.
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
        // A tap that dies while the key is held would otherwise leave the
        // recorder running forever.
        synthesizeReleaseIfHolding(reason: "monitor stopped")
        teardownTap()
        isHealthy = false
    }

    // MARK: Tap installation

    private func installTap() {
        // .flagsChanged only. The two disable notifications
        // (.tapDisabledByTimeout / .tapDisabledByUserInput) are NOT maskable —
        // they are delivered to the callback whatever the mask says, and are
        // handled by branching on `type` inside the callback. Trying to OR them
        // into eventsOfInterest is a common and silent mistake.
        let mask: CGEventMask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)

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

        // .listenOnly is essential. With .defaultTap we could swallow or delay
        // the Right-Option event, breaking it as a real modifier for every other
        // app — and a listen-only tap is also cheaper for the window server.
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
            // relaunch.
            isHealthy = false
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tapPort = port
        runLoopSource = source
        isHealthy = CGEvent.tapIsEnabled(tap: port)
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
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables a tap whose callback took too long, or when
            // the user floods input. Re-enabling on the same port is the
            // documented recovery; skipping it is why "the hotkey works for an
            // hour and then silently dies".
            isHealthy = false
            synthesizeReleaseIfHolding(reason: "tap disabled by system")
            if let port = tapPort {
                CGEvent.tapEnable(tap: port, enable: true)
                isHealthy = CGEvent.tapIsEnabled(tap: port)
            }

        case .flagsChanged:
            let movedKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let down = keyIsDown(flags: event.flags, movedKey: movedKey)
            updateGesture(down: down)

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

    private func updateGesture(down: Bool) {
        if down {
            if releasePending {
                // Key came back inside the grace window: at contact-bounce
                // scale (see `releaseGrace`) this can only be electrical
                // bounce, not a real re-press. Rejoin the one hold — note this
                // swallows the down-edge (no `onPressStart`), which is exactly
                // why the window must stay at bounce scale in toggle mode.
                releasePending = false
                releaseGeneration &+= 1
                return
            }
            guard !isHolding else { return }
            if let last = lastReleaseAt,
               Date().timeIntervalSince(last) < debounceInterval {
                return  // debounced: contact bounce only — see `debounceInterval`
            }
            beginHold()
        } else {
            guard isHolding, !releasePending else { return }
            scheduleRelease()
        }
    }

    private func beginHold() {
        isHolding = true
        keyStateMisses = 0
        holdStartedAt = Date()
        releasePending = false
        releaseGeneration &+= 1
        onPressStart()
    }

    private func scheduleRelease() {
        releasePending = true
        releaseGeneration &+= 1
        let generation = releaseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseGrace) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.releasePending, self.releaseGeneration == generation else { return }
                self.finishHold()
            }
        }
    }

    private func finishHold() {
        guard isHolding else { return }
        isHolding = false
        keyStateMisses = 0
        releasePending = false
        holdStartedAt = nil
        lastReleaseAt = Date()
        releaseGeneration &+= 1
        onPressEnd()
    }

    /// Deliver `onPressEnd` immediately, bypassing the grace window. Used
    /// whenever we lose the ability to observe the real release — otherwise the
    /// recorder runs until the disk fills.
    private func synthesizeReleaseIfHolding(reason: String) {
        guard isHolding else { return }
        let heldMS = holdStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        let message = "synthesized hotkey release: \(reason) "
            + "(keyStateMisses=\(keyStateMisses), heldMs=\(heldMS))"
        FileHandle.standardError.write(Data("PhayaVoice: \(message)\n".utf8))
        // trace() does synchronous file I/O, and one caller of this method (the
        // .tapDisabledBy* branch of `handle`) runs inside the tap callback's
        // latency budget. Hop the file write off that budget, same pattern as
        // main.swift's press handlers; the stderr line above is cheap enough to
        // stay inline. No transcript text goes anywhere near this line.
        Task { @MainActor in trace(message) }
        finishHold()
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
            if permissionGranted() { installTap() }
            return
        }

        // Case 2: Secure Event Input. While any app holds SEI, every event tap
        // in the session goes dead — with no callback to tell us. Polling
        // CGEvent.tapIsEnabled is the only way to notice, and re-enabling once
        // SEI clears is the only way back.
        let enabled = CGEvent.tapIsEnabled(tap: port)
        if !enabled {
            isHealthy = false
            synthesizeReleaseIfHolding(reason: "tap dead (Secure Event Input?)")
            CGEvent.tapEnable(tap: port, enable: true)
            isHealthy = CGEvent.tapIsEnabled(tap: port)
            return
        }
        isHealthy = true

        // Case 3: stuck hold. Two independent detectors.
        guard isHolding, let started = holdStartedAt else { return }

        if Date().timeIntervalSince(started) > maxHoldDuration {
            synthesizeReleaseIfHolding(reason: "exceeded max hold duration")
            return
        }

        // State-poll release synthesis is DISABLED — measured on this machine,
        // both available state APIs lie during a real hold:
        //
        //   flagsState(.combinedSessionState) is perturbed by our own injected
        //   events (the original mid-sentence cut-off bug), and
        //   keyState(.hidSystemState, key: 61) reported "up" from the FIRST
        //   poll of every real hold (trace 1:58:57-1:59:19: miss 1/3 within a
        //   second of press, synthesized release at heldMs=2768 and 2087 while
        //   the user was still holding — a remapper or TCC gating leaves the
        //   HID table blind to this key). Any state-based detector here cuts
        //   off every real hold, which is the worst possible failure.
        //
        // So: trust the tap. It is .listenOnly on the session tap and
        // demonstrably delivers every real press/release (that is how holds
        // begin at all). A real release always produces a .flagsChanged event;
        // the only way to LOSE one is a dead tap, and Case 2 above already
        // synthesizes a release the moment the tap goes dead. The remaining
        // backstop is maxHoldDuration. The poll below is DIAGNOSTIC ONLY — it
        // logs the first disagreement per hold so future reports remain
        // debuggable from /tmp/mictest_trace.txt, and resets on agreement.
        if CGEventSource.keyState(.hidSystemState, key: keyCode) {
            keyStateMisses = 0
            return
        }
        keyStateMisses += 1
        if keyStateMisses == 1 {
            // pollHealth runs from the main-queue timer, never inside the tap
            // callback, so calling trace() inline is fine here.
            trace("hotkey health: HID claims key up while holding (diagnostic only; "
                + "state-poll release synthesis disabled on this machine)")
        }
    }
}
