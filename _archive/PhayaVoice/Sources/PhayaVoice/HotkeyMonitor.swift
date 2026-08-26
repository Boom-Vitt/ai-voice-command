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

    /// Coarse (left-or-right) mask for the same key. Used only as a
    /// conservative "definitely not held" stuck-detector, because
    /// `CGEventSource.flagsState` is not guaranteed to carry device bits.
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
    /// press. Human double-taps of a modifier bottom out around 80–120 ms, and
    /// a mechanical switch settles in well under 10 ms, so 30 ms sits clear of
    /// both: it swallows contact bounce and any key-auto-repeat storm that would
    /// otherwise machine-gun start/stop, without blocking a genuine fast retry.
    private let debounceInterval: TimeInterval = 0.030

    /// Grace window after the key appears to lift. If it comes back down inside
    /// this window we treat the gesture as one continuous hold rather than
    /// stop → start. 50 ms is longer than any switch bounce or momentary
    /// flags glitch, and short enough that a real release still feels instant
    /// (the user has already stopped speaking by then).
    private let releaseGrace: TimeInterval = 0.050

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
    /// Consecutive health polls in which `CGEventSource.flagsState` claimed our
    /// modifier was not down while we believed it was. See `pollHealth`.
    private var flagsStateMisses: Int = 0

    // MARK: Init

    init(keyCode: UInt16? = nil) {
        let configured = keyCode ?? Settings.shared.hotkeyKeyCode
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
                // Key came back inside the grace window: this was bounce, not a
                // real release. Cancel the pending stop and stay in one hold.
                releasePending = false
                releaseGeneration &+= 1
                return
            }
            guard !isHolding else { return }
            if let last = lastReleaseAt,
               Date().timeIntervalSince(last) < debounceInterval {
                return  // debounced: too soon after the previous release
            }
            beginHold()
        } else {
            guard isHolding, !releasePending else { return }
            scheduleRelease()
        }
    }

    private func beginHold() {
        isHolding = true
        flagsStateMisses = 0
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
        flagsStateMisses = 0
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
        FileHandle.standardError.write(
            Data("PhayaVoice: synthesizing hotkey release (\(reason))\n".utf8))
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

        // CGEventSource.flagsState reads the hardware modifier state without a
        // tap, so it still answers when individual events were lost. Two layers
        // of caution, because a false positive here would cut off *every* real
        // hold — the worst possible failure:
        //   1. Only the coarse mask is consulted. If it is clear then neither
        //      Option is down, so we cannot be mid-hold. Device-dependent bits
        //      are not guaranteed to survive this API, so they are not trusted.
        //   2. Two consecutive polls must disagree with us before we act. A
        //      single stale or unavailable read (process not front, session
        //      state momentarily unreadable) is absorbed; a genuinely stuck hold
        //      still clears in ~2 s, long before the user notices.
        guard let coarse = coarseMask else { return }
        let live = CGEventSource.flagsState(.combinedSessionState)
        if live.contains(coarse) {
            flagsStateMisses = 0
            return
        }
        flagsStateMisses += 1
        if flagsStateMisses >= 2 {
            synthesizeReleaseIfHolding(reason: "key not down for 2 consecutive flagsState polls")
        }
    }
}
