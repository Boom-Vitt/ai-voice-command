import AppKit
import Foundation
import QuartzCore

// MARK: - Why this file exists
//
// The status-bar item is the *documented* control, but on a 14"/16" MacBook with
// a notch and 14+ menubar apps it is simply not on screen: macOS silently drops
// the overflow behind the notch and there is no scroll, no overflow menu, no
// indication that the item exists. For this user the menubar icon is a control
// they cannot reach. This button is therefore the primary control, not a
// convenience — a Grammarly-style floating action button that is always visible
// and always clickable.
//
// MARK: - Why it is configured the way it is
//
// Same non-negotiable as `HUDPanel`: PhayaVoice types into whatever app the user
// is already working in, so this window must never take keyboard focus. The user
// clicks this button *while their caret sits in a text field*, and that caret has
// to still be there when the transcript is injected. The focus-safety recipe is
// not re-derived here — `NonActivatingPanel` (declared in HUDPanel.swift) already
// encodes it and is reused verbatim:
//
//   NonActivatingPanel   – overrides canBecomeKey / canBecomeMain to false.
//                          They are get-only on NSWindow, so overriding is the
//                          ONLY way; `panel.canBecomeKey = false` does not
//                          compile. Reused rather than re-declared: two types
//                          with that name in one module would collide, and one
//                          shared definition means the invariant has one home.
//   .nonactivatingPanel  – showing or clicking the panel does not activate us.
//   orderFrontRegardless – shows without activating. makeKeyAndOrderFront is
//                          precisely the focus steal we must never perform, and
//                          appears nowhere in this file.
//   hidesOnDeactivate    – false, or the button would vanish the instant the
//                          user's app (correctly) stays frontmost.
//   collectionBehavior   – .canJoinAllSpaces + .fullScreenAuxiliary + .stationary
//                          so it follows the user across Spaces, shows over a
//                          full-screen editor, and does not slide in Mission
//                          Control.
//
// The ONE deliberate difference from `HUDPanel`: `ignoresMouseEvents = false`.
// The HUD is a read-only indicator and lets clicks pass through; this is a
// control and must receive them.
//
// MARK: - Why AppKit + CoreAnimation rather than SwiftUI
//
// `HUDPanel` uses SwiftUI, and for a display-only surface that is the right call.
// This one is interactive, and interaction in a never-key, non-activating panel
// is exactly where SwiftUI has no answer:
//
//   * `NSView.acceptsFirstMouse(for:)` decides whether the first click into an
//     inactive window is delivered as a real mouse-down or swallowed as an
//     activation click. It must be true here — every click is a "first" click,
//     because this app is never the active one. SwiftUI exposes no hook for it.
//   * Drag-vs-click needs raw mouseDown/mouseDragged/mouseUp with screen
//     coordinates and a movement threshold. SwiftUI's DragGesture reports values
//     relative to a view whose window is moving underneath it during the drag.
//   * The level ring is one `strokeEnd` assignment on a CAShapeLayer at 20 Hz.
//     Through SwiftUI that is a view-tree invalidation 20×/second for a shape
//     that Core Animation can update on the render server for free.

@MainActor
final class FloatingButton {

    // MARK: - Callbacks

    /// Fired on a click that starts dictation, or when a press-and-hold crosses
    /// `holdThreshold`. The owner is expected to respond by calling
    /// `setState(.recording(startedAt:))` — this class never invents state, it
    /// only reflects what the owner tells it (see `setState`).
    var onActivate: () -> Void = {}

    /// Fired on the click that stops dictation, or on mouse-up after a
    /// press-and-hold.
    var onDeactivate: () -> Void = {}

    // MARK: - Geometry constants

    /// Button diameter. 52 pt is the size at which a circular control is
    /// comfortably clickable without aiming (Apple's 44 pt minimum target plus
    /// margin) while still small enough to leave alone in a corner of the screen.
    static let diameter: CGFloat = 52

    /// Clear space between the button's edge and the level ring, so the ring
    /// reads as a separate element rather than a rim on the button.
    static let ringGap: CGFloat = 4

    /// Ring stroke. 3 pt survives being drawn on a busy desktop background;
    /// 1–2 pt disappears against light wallpaper at this radius.
    static let ringWidth: CGFloat = 3

    /// Extra transparent margin inside the panel for the drop shadow. The shadow
    /// is drawn by the layer, so it needs room *inside* the window's own bounds
    /// or it is clipped. 8 pt covers `shadowRadius` (8) plus the 2 pt offset.
    static let shadowSlack: CGFloat = 8

    /// Outermost drawn radius: button edge + gap + full ring width. Also the hit
    /// radius, so the ring is grabbable rather than being a dead 7 pt moat.
    static var outerRadius: CGFloat { diameter / 2 + ringGap + ringWidth }

    /// The panel is square and larger than the button so the ring and the shadow
    /// both fit. Everything outside `outerRadius` is fully transparent, and
    /// `FloatingButtonView.hitTest` declines it, so the corners are not a
    /// 30 × 30 pt invisible click trap over the user's document.
    static var panelSide: CGFloat { 2 * (outerRadius + shadowSlack) }

    /// Gap from the screen edge in the default position. 24 pt matches the
    /// margin `HUDPanel` uses, so the two surfaces look like one design.
    static let edgeMargin: CGFloat = 24

    /// Default height above the bottom of `visibleFrame`. Not 24: the HUD capsule
    /// lives at bottom-centre 24 pt up, and the Dock's right-hand stacks (Trash,
    /// Downloads) sit in the bottom-right corner. 120 pt clears both, and the
    /// user can drag it anywhere anyway.
    static let defaultBottomInset: CGFloat = 120

    // MARK: - Timing constants

    /// Pointer travel, in points, that turns a press into a drag. Chosen at 4 pt
    /// because a deliberate click on a trackpad routinely wanders 1–3 pt between
    /// down and up (finger roll), so anything smaller would turn ordinary clicks
    /// into 2 pt window nudges; anything much larger and the first few points of
    /// a real drag are swallowed, which reads as the button sticking.
    static let dragThreshold: CGFloat = 4

    /// How long the button must be held before the press becomes push-to-talk.
    /// 400 ms is comfortably longer than a deliberate click (a fast click is
    /// 60–120 ms down-to-up, a slow one ~250 ms) and short enough that a user
    /// who *means* to hold has not yet started speaking. It also matches the feel
    /// of the Right-Option hotkey, which is the gesture this imitates.
    static let holdThreshold: TimeInterval = 0.400

    /// How long a `.failed` message stays up before the button returns to
    /// `.idle`. 3 s is the usual floor for "long enough to read a short
    /// sentence"; the same value `HUDPanel` uses, so the two agree on screen.
    static let failureAutoDismiss: TimeInterval = 3.0

    /// Safety net for `.injecting`, which is a few milliseconds of real work. If
    /// the owner never sends a following state (crash, swallowed error) the
    /// button must not sit showing a checkmark forever. 1.2 s is far beyond any
    /// real injection and short enough to feel like a confirmation flash.
    static let injectingAutoDismiss: TimeInterval = 1.2

    /// Ring housekeeping tick. The ring shows tenths of a level, so 100 ms is the
    /// rate at which the drawn value can meaningfully change — same reasoning,
    /// and same value, as `HUDPanel.elapsedTickInterval`.
    static let ringTickInterval: TimeInterval = 0.1

    /// How long `setLevel` must stay silent before the ring starts draining.
    /// `AudioRecorder` publishes at 20 Hz (50 ms), so 150 ms is three missed
    /// updates: past normal scheduling jitter, and still fast enough that a
    /// stalled meter never reads as a hung app.
    static let levelStallThreshold: TimeInterval = 0.150

    /// Multiplier applied per stalled tick so the ring falls to nothing in about
    /// a second instead of freezing mid-arc. Matches `HUDPanel.meterDecay`.
    static let ringDecay: Float = 0.85

    /// Weight of each fresh sample in the exponential smoothing of the ring.
    /// At the 20 Hz publish rate 0.45 settles a step change in ~4 samples
    /// (200 ms): fast enough to look live, slow enough that consonant transients
    /// do not make the ring strobe.
    static let levelSmoothing: Float = 0.45

    /// Floor of the ring arc while recording. Even in silence the ring must show
    /// *something*, or "recording with nothing to hear" is indistinguishable from
    /// "the ring is broken". 6 % of the circumference is a visible tick at 12
    /// o'clock without reading as signal.
    static let minimumRingArc: Float = 0.06

    /// Hover crossfade. 0.15 s is AppKit's usual hover timing: immediate to the
    /// eye, but long enough that skimming the pointer past the edge does not
    /// strobe the button.
    static let hoverFade: TimeInterval = 0.15

    /// Resting opacity. Semi-transparent so a button parked over a document is
    /// not a hole in it; opaque the moment the pointer arrives or dictation is
    /// live, because at that point it is the thing being looked at.
    static let idleAlpha: CGFloat = 0.85

    // MARK: - Palette
    //
    // Explicit sRGB rather than system/dynamic colors: these are drawn into
    // CALayers, which resolve a `cgColor` once and would not follow an
    // appearance change, and the brand teal must be the brand teal on every
    // display profile.

    /// The app's brand teal.
    static let brandTeal = NSColor(srgbRed: 0.055, green: 0.545, blue: 0.522, alpha: 1)

    /// Recording. Warm red rather than pure #FF0000 — it has to sit next to the
    /// teal without vibrating, and it is the same family as the HUD's red dot.
    static let recordingRed = NSColor(srgbRed: 0.878, green: 0.239, blue: 0.220, alpha: 1)

    /// Failure. Deeper and less saturated than `recordingRed` so a failure is not
    /// mistaken at a glance for "still recording".
    static let failureRed = NSColor(srgbRed: 0.760, green: 0.161, blue: 0.161, alpha: 1)

    // MARK: - Persistence

    /// Where the user parked the button, as `NSStringFromPoint` output
    /// (`"{x, y}"`) so it is legible in `defaults read` and survives a plist
    /// round-trip without a custom coder. Absence of the key — not a sentinel
    /// value — means "never moved", which is why this is a String rather than
    /// two Doubles that would both default to a meaningful 0.
    static let originDefaultsKey = "floatingButtonOrigin"

    // MARK: - Visual description of one state

    /// Everything that distinguishes one dictation state from another on screen.
    /// Resolved by `appearance(for:)` (a pure function, so the mapping can be
    /// checked without a screen) and applied by the view.
    struct Appearance: Equatable {
        let fillColor: NSColor
        /// SF Symbol name. Every one of these ships in macOS 11+.
        let symbolName: String
        /// Show the level ring (track + progress arc).
        let showsRing: Bool
        /// Show the indeterminate spinner arc.
        let showsSpinner: Bool
    }

    static func appearance(for state: DictationState) -> Appearance {
        switch state {
        case .idle:
            return Appearance(fillColor: brandTeal, symbolName: "mic",
                              showsRing: false, showsSpinner: false)
        case .recording:
            return Appearance(fillColor: recordingRed, symbolName: "mic.fill",
                              showsRing: true, showsSpinner: false)
        case .transcribing:
            return Appearance(fillColor: brandTeal, symbolName: "waveform",
                              showsRing: false, showsSpinner: true)
        case .injecting:
            return Appearance(fillColor: brandTeal, symbolName: "checkmark",
                              showsRing: false, showsSpinner: false)
        case .failed:
            return Appearance(fillColor: failureRed,
                              symbolName: "exclamationmark.triangle.fill",
                              showsRing: false, showsSpinner: false)
        }
    }

    // MARK: - Stored state

    /// Exposed so the panel's focus-safety configuration can be asserted without
    /// ever putting a window on screen — the same affordance `HUDPanel` provides.
    private(set) var panel: NSPanel

    /// True between `show()` and `hide()`. Stored rather than derived from
    /// `panel.isVisible` so the answer is deterministic and does not depend on
    /// the window server having caught up.
    private(set) var isVisible = false

    private let view: FloatingButtonView
    private var state: DictationState = .idle

    /// Screen point where the current press started, for drag detection.
    private var pressOriginScreen: NSPoint = .zero
    /// Offset from the panel's bottom-left corner to the grab point. Recomputing
    /// the origin from this on every drag event (rather than accumulating deltas)
    /// means a dropped or coalesced event cannot make the button drift.
    private var grabOffset: NSSize = .zero
    private var isDragging = false
    /// True once the hold timer has fired `onActivate` for this press, so mouse-up
    /// knows it is releasing a push-to-talk rather than completing a click.
    private var holdFired = false

    /// Bumped by every press event; a scheduled hold callback that finds a newer
    /// generation knows it has been superseded. Same idiom as
    /// `HUDPanel.dismissGeneration`, and it avoids handing a `DispatchWorkItem`
    /// across the concurrency boundary.
    private var pressGeneration: UInt64 = 0
    private var dismissGeneration: UInt64 = 0

    private var ringTimer: DispatchSourceTimer?
    private var lastLevelAt: Date = .distantPast
    private var smoothedLevel: Float = 0

    private var isHovering = false
    private var reduceMotion = false

    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?

    // MARK: - Init

    init() {
        let side = Self.panelSide

        // .borderless removes the title bar; .nonactivatingPanel is what stops a
        // click on this window from activating PhayaVoice and pulling focus out
        // of the user's text field.
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // The one deliberate divergence from HUDPanel: this window is a control.
        panel.ignoresMouseEvents = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the layer draws a circular shadow; an
                                         // AppKit window shadow would box it.
        panel.isMovableByWindowBackground = false   // dragging is implemented by
                                                    // hand so it can be told
                                                    // apart from a click.
        // Needed for NSTrackingArea enter/exit and tooltips to have any chance of
        // firing while PhayaVoice is not the active app.
        panel.acceptsMouseMovedEvents = true
        // PhayaVoice runs modal alerts (the Diagnostics sheet). Without this the
        // button would go dead for the duration of one.
        panel.worksWhenModal = true

        // .floating, not .statusBar: this window is permanently on screen, and
        // .statusBar (25) sits *above* the menu bar (24). A control the user never
        // dismisses must never cover a menu they pulled down. .floating (3) is
        // above every ordinary window of every app and below all system UI.
        panel.level = .floating
        // .canJoinAllSpaces: follow the user across Spaces rather than pinning to
        // the Space where it was shown. .fullScreenAuxiliary: appear over a
        // full-screen app, which is exactly where the menubar item is least
        // reachable. .stationary: do not slide during Mission Control.
        // .ignoresCycle: never appear in Cmd-` window cycling.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Suppress AppKit's window fade — the button is toggled from a menu and
        // should appear at once.
        panel.animationBehavior = .none

        let view = FloatingButtonView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        panel.contentView = view

        self.panel = panel
        self.view = view

        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Wire raw pointer events out of the view. All interpretation — drag vs
        // click vs hold — lives here, so the view stays a dumb renderer.
        view.onPressBegan = { [weak self] point in self?.handlePressBegan(at: point) }
        view.onPressMoved = { [weak self] point in self?.handlePressMoved(to: point) }
        view.onPressEnded = { [weak self] point in self?.handlePressEnded(at: point) }
        view.onHoverChanged = { [weak self] hovering in self?.handleHoverChanged(hovering) }

        // Place the panel now, at init, rather than in show(): the restored origin
        // has to be clamped on screen before anything can order it front, and
        // doing it here means the geometry can be asserted headlessly.
        panel.setFrameOrigin(Self.restoredOrigin(for: NSSize(width: side, height: side)))

        installObservers()
        applyCurrentAppearance(animated: false)
        updateOpacity(animated: false)
    }

    // `isolated deinit` (SE-0371) keeps teardown on the main actor. Without it
    // Swift 6 refuses to touch the non-Sendable observer tokens from a nonisolated
    // deinit — and they must be released on the thread they were registered
    // against anyway.
    isolated deinit {
        ringTimer?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
    }

    // MARK: - Visibility

    /// Idempotent: the menubar toggle can call this on an already-visible button.
    func show() {
        guard !isVisible else { return }
        // Re-clamp first. Screens may have changed while hidden, and a saved
        // origin from a monitor that is no longer attached must not be honoured.
        clampIntoScreen(persist: false)
        // orderFrontRegardless, never makeKeyAndOrderFront: it shows the panel
        // while PhayaVoice is inactive, and takes no focus doing it.
        panel.orderFrontRegardless()
        isVisible = true
        updateOpacity(animated: false)
    }

    /// Idempotent.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        cancelPress()
        panel.orderOut(nil)
    }

    // MARK: - State

    /// Reflect the owner's dictation state.
    ///
    /// NOTE the difference from `HUDPanel.show(_:)`: there, `.idle` means "hide".
    /// Here `.idle` is the button's *resting* look — teal, mic glyph, still on
    /// screen. This button is a permanent control; only `hide()` removes it.
    func setState(_ newState: DictationState) {
        dismissGeneration &+= 1
        state = newState

        switch newState {
        case .idle:
            stopRingTimer()
            smoothedLevel = 0
            view.setRingProgress(0, animated: false)
            view.toolTip = "PhayaVoice — click to dictate, or hold to talk"

        case .recording:
            smoothedLevel = 0
            lastLevelAt = Date()
            view.setRingProgress(Self.minimumRingArc, animated: false)
            startRingTimer()
            view.toolTip = "Recording — click to stop"

        case .transcribing:
            stopRingTimer()
            view.toolTip = "Transcribing…"

        case .injecting:
            stopRingTimer()
            view.toolTip = "Inserting text…"
            scheduleReturnToIdle(after: Self.injectingAutoDismiss)

        case .failed(let message):
            stopRingTimer()
            // The message has nowhere else to go: this control has no label, and
            // the HUD may already be gone. A tooltip is the only text surface a
            // 52 pt circle has.
            view.toolTip = message
            scheduleReturnToIdle(after: Self.failureAutoDismiss)
        }

        applyCurrentAppearance(animated: true)
        // Not animated: opacity here is *state*, and dictation has just started or
        // stopped. Fading in over 150 ms would mean the first 150 ms of recording
        // is shown at resting opacity. The hover crossfade is decoration and is
        // the only thing that animates.
        updateOpacity(animated: false)
    }

    /// Live microphone level, 0…1 linear RMS, as published by `AudioRecorder`.
    func setLevel(_ rms: Float) {
        // Guard on state, not on visibility: a level arriving while idle would
        // otherwise animate a ring that is not supposed to be drawn at all.
        guard case .recording = state else { return }
        lastLevelAt = Date()
        let scaled = Self.displayScale(min(max(rms, 0), 1))
        smoothedLevel = smoothedLevel * (1 - Self.levelSmoothing) + scaled * Self.levelSmoothing
        view.setRingProgress(Self.ringArc(for: smoothedLevel), animated: !reduceMotion)
    }

    /// `AudioRecorder` publishes *linear* RMS on purpose and leaves perceptual
    /// shaping to the display layer — this is that layer.
    ///
    /// Conversational speech sits around 0.02–0.15 linear RMS, so a linear ring
    /// would hug zero and look broken. Mapping through decibels with a −50 dBFS
    /// floor puts normal speech at roughly 30–75 % of the circle, which is where
    /// a meter reads as responsive; −50 dB is also close to typical room noise,
    /// so silence rests at the bottom instead of shimmering.
    ///
    /// Deliberately duplicated from `HUDPanel`'s `LevelMeter.displayScale`: that
    /// type is file-private, and the two surfaces must agree on the mapping or the
    /// HUD meter and this ring would disagree about the same audio.
    static func displayScale(_ rms: Float) -> Float {
        guard rms > 0.00001 else { return 0 }
        let db = 20 * log10(rms)
        let floorDB: Float = -50
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }

    /// Map a 0…1 display level onto the drawn fraction of the circle, keeping a
    /// always-visible minimum tick.
    static func ringArc(for level: Float) -> Float {
        let clamped = min(max(level, 0), 1)
        return minimumRingArc + (1 - minimumRingArc) * clamped
    }

    // MARK: - Interaction

    /// Pure drag-vs-click test, in screen points. Compared squared so the hot
    /// path never calls `sqrt`.
    static func exceedsDragThreshold(from start: NSPoint,
                                     to current: NSPoint,
                                     threshold: CGFloat = dragThreshold) -> Bool {
        let dx = current.x - start.x
        let dy = current.y - start.y
        return (dx * dx + dy * dy) > threshold * threshold
    }

    /// `.recording` is the only state in which a click means "stop".
    /// `.transcribing` / `.injecting` are the owner's busy window: a click there
    /// could only start a second dictation on top of the first, so it is ignored.
    private var clickWouldStop: Bool {
        if case .recording = state { return true }
        return false
    }

    private var clickWouldStart: Bool {
        switch state {
        case .idle, .failed: return true
        case .recording, .transcribing, .injecting: return false
        }
    }

    private func handlePressBegan(at screenPoint: NSPoint) {
        pressGeneration &+= 1
        let generation = pressGeneration

        pressOriginScreen = screenPoint
        isDragging = false
        holdFired = false

        let frame = panel.frame
        grabOffset = NSSize(width: screenPoint.x - frame.minX,
                            height: screenPoint.y - frame.minY)

        // Push-to-talk arms here and fires only if the press survives
        // `holdThreshold` without becoming a drag or a release. Nothing is fired
        // on mouse-down itself: a press that turns into a drag must not have
        // started a recording that then has to be cancelled.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pressGeneration == generation else { return }
                guard !self.isDragging, self.clickWouldStart else { return }
                self.holdFired = true
                self.onActivate()
            }
        }
    }

    private func handlePressMoved(to screenPoint: NSPoint) {
        if !isDragging, Self.exceedsDragThreshold(from: pressOriginScreen, to: screenPoint) {
            isDragging = true
            // Supersede the pending hold: the user is moving the button, not
            // talking into it.
            pressGeneration &+= 1
        }
        guard isDragging else { return }

        let proposed = NSPoint(x: screenPoint.x - grabOffset.width,
                               y: screenPoint.y - grabOffset.height)
        moveClamped(to: proposed)
    }

    private func handlePressEnded(at screenPoint: NSPoint) {
        pressGeneration &+= 1

        if isDragging {
            isDragging = false
            moveClamped(to: NSPoint(x: screenPoint.x - grabOffset.width,
                                    y: screenPoint.y - grabOffset.height))
            persistOrigin()
            return
        }

        if holdFired {
            holdFired = false
            // Unconditional, deliberately: this is a push-to-talk release. A stop
            // that is dropped leaves the microphone open forever, which is far
            // worse than a redundant stop — and the owner already guards its own
            // `busy` flag, so a redundant one is a no-op.
            onDeactivate()
            return
        }

        // Plain click: toggle.
        if clickWouldStop {
            onDeactivate()
        } else if clickWouldStart {
            onActivate()
        }
    }

    /// Abandon any press in flight (used by `hide()`), without firing callbacks.
    private func cancelPress() {
        pressGeneration &+= 1
        isDragging = false
        holdFired = false
        handleHoverChanged(false)
    }

    private func handleHoverChanged(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        updateOpacity(animated: true)
    }

    // MARK: - Geometry

    /// Keep `size` fully inside `visible`. Pure, so it can be checked against a
    /// garbage saved origin without a screen.
    ///
    /// The `max(visible.minX, …)` guards are not decoration: if the panel were
    /// ever wider than the visible frame, `maxX - width` would fall below `minX`
    /// and the clamp would invert, pinning the button *off* the screen it was
    /// meant to be pulled onto.
    static func clamp(origin: NSPoint, size: NSSize, into visible: NSRect) -> NSPoint {
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return NSPoint(x: min(max(origin.x, visible.minX), maxX),
                       y: min(max(origin.y, visible.minY), maxY))
    }

    /// `visibleFrame` of the screen a proposed frame lands on. "Lands on" is the
    /// screen containing the frame's centre — the same rule the window server
    /// uses to decide which screen a window belongs to — falling back to the
    /// screen it overlaps most, then to the main screen. `visibleFrame` (not
    /// `frame`) is what excludes the menu bar and the Dock.
    static func landingVisibleFrame(for proposed: NSRect, screens: [NSScreen]) -> NSRect? {
        guard !screens.isEmpty else { return nil }

        let centre = NSPoint(x: proposed.midX, y: proposed.midY)
        if let containing = screens.first(where: { $0.frame.contains(centre) }) {
            return containing.visibleFrame
        }

        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.frame.intersection(proposed)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        if let best { return best.visibleFrame }

        // Saved position points at a monitor that is no longer attached (or is
        // outright garbage). Fall back to the main screen so the clamp pulls the
        // button back into view rather than leaving it in the void.
        return (NSScreen.main ?? screens[0]).visibleFrame
    }

    /// Bottom-right of the main screen's visible area.
    static func defaultOrigin(size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(x: visible.maxX - size.width - edgeMargin,
                y: visible.minY + defaultBottomInset)
    }

    /// The saved origin if there is one, otherwise the default — either way
    /// clamped onto a screen that actually exists.
    static func restoredOrigin(for size: NSSize, defaults: UserDefaults = .standard) -> NSPoint {
        let screens = NSScreen.screens
        // Absence of the key, not a sentinel, is what means "never moved".
        // NSPointFromString returns (0, 0) for unparseable input, which the clamp
        // below then rescues, so corrupt defaults cannot hide the button.
        let saved = defaults.string(forKey: originDefaultsKey).map(NSPointFromString)

        let fallbackVisible = (NSScreen.main ?? screens.first)?.visibleFrame
        let proposed: NSPoint
        if let saved {
            proposed = saved
        } else if let fallbackVisible {
            proposed = defaultOrigin(size: size, in: fallbackVisible)
        } else {
            proposed = .zero
        }

        let frame = NSRect(origin: proposed, size: size)
        guard let visible = landingVisibleFrame(for: frame, screens: screens) else {
            // No screens at all (headless session). Nothing to clamp against;
            // returning the proposal unchanged is the only honest answer.
            return proposed
        }
        return clamp(origin: proposed, size: size, into: visible)
    }

    private func moveClamped(to origin: NSPoint) {
        let size = panel.frame.size
        let frame = NSRect(origin: origin, size: size)
        guard let visible = Self.landingVisibleFrame(for: frame, screens: NSScreen.screens) else {
            panel.setFrameOrigin(origin)
            return
        }
        panel.setFrameOrigin(Self.clamp(origin: origin, size: size, into: visible))
    }

    /// Pull the current position back on screen — after a display change, or
    /// before showing.
    private func clampIntoScreen(persist: Bool) {
        moveClamped(to: panel.frame.origin)
        if persist { persistOrigin() }
    }

    private func persistOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin),
                                  forKey: Self.originDefaultsKey)
    }

    // MARK: - Appearance

    private func applyCurrentAppearance(animated: Bool) {
        view.apply(Self.appearance(for: state),
                   animated: animated && !reduceMotion,
                   reduceMotion: reduceMotion)
    }

    /// Semi-transparent only while resting and unhovered. Any non-idle state is
    /// fully opaque: at that point the button is reporting something and must not
    /// be competing with the wallpaper behind it.
    ///
    /// `animated` is true only for hover. `panel.animator()` drives the change
    /// from the run loop over `hoverFade`, so the value is not yet at its target
    /// when this returns — fine for a decoration, wrong for anything that
    /// conveys state.
    private func updateOpacity(animated: Bool) {
        let resting: Bool
        if case .idle = state { resting = true } else { resting = false }
        let target: CGFloat = (isHovering || !resting) ? 1.0 : Self.idleAlpha

        guard animated, !reduceMotion else {
            panel.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hoverFade
            panel.animator().alphaValue = target
        }
    }

    // MARK: - Observers

    private func installObservers() {
        // Display reconfiguration: resolution change, laptop lid, a monitor
        // unplugged. Without this the button ends up on a screen that no longer
        // exists — and unlike the HUD, it never re-shows itself to correct that.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampIntoScreen(persist: false) }
        }

        // Accessibility options post on NSWorkspace's own notification centre,
        // not the default one — observing the default centre silently never
        // fires, which is why "Reduce Motion" is so often ignored by apps.
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.applyCurrentAppearance(animated: false)
                self.updateOpacity(animated: false)
            }
        }
    }

    // MARK: - Ring timer

    private func startRingTimer() {
        stopRingTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.ringTickInterval, repeating: Self.ringTickInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // If levels stop arriving (audio thread stalled, device being
                // swapped) drain the ring instead of leaving it frozen mid-arc —
                // a frozen meter reads as "the app hung".
                guard Date().timeIntervalSince(self.lastLevelAt) > Self.levelStallThreshold else { return }
                guard self.smoothedLevel > 0.001 else { return }
                self.smoothedLevel *= Self.ringDecay
                self.view.setRingProgress(Self.ringArc(for: self.smoothedLevel),
                                          animated: !self.reduceMotion)
            }
        }
        timer.resume()
        ringTimer = timer
    }

    private func stopRingTimer() {
        ringTimer?.cancel()
        ringTimer = nil
    }

    private func scheduleReturnToIdle(after delay: TimeInterval) {
        dismissGeneration &+= 1
        let generation = dismissGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dismissGeneration == generation else { return }
                self.setState(.idle)
            }
        }
    }

    // MARK: - SF Symbol rasterisation

    /// An SF Symbol rendered white, at an exact pixel size, as a CGImage for a
    /// CALayer's `contents`.
    ///
    /// Drawn by hand into an `NSBitmapImageRep` rather than handed to
    /// `NSImage.cgImage(forProposedRect:context:hints:)` because that picks a
    /// representation for a *generic* context and would hand back a 1× bitmap
    /// that Core Animation then upscales — visibly soft on a Retina display. Here
    /// the pixel dimensions and the layer's `contentsScale` are set from the same
    /// `scale`, so the glyph is always drawn at native resolution.
    ///
    /// Returns nil if the symbol is missing from this OS; the caller draws no
    /// glyph rather than substituting a wrong one.
    static func symbolImage(_ name: String,
                            pointSize: CGFloat,
                            weight: NSFont.Weight,
                            scale: CGFloat) -> (image: CGImage, size: NSSize)? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }

        let points = symbol.size
        let pixelsWide = Int((points.width * scale).rounded(.up))
        let pixelsHigh = Int((points.height * scale).rounded(.up))
        guard points.width > 0, points.height > 0, pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelsWide,
                                         pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0)
        else { return nil }

        // The rep is `scale`× denser than its point size; setting `size` in points
        // is what makes `draw(in:)` map points onto those pixels.
        rep.size = points
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        symbol.draw(in: NSRect(origin: .zero, size: points))
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = rep.cgImage else { return nil }
        return (cgImage, points)
    }
}

// MARK: - The view
//
// Layer-*hosting* (its root CALayer is supplied here) rather than layer-backed,
// and with no subviews at all. Two reasons: AppKit is documented not to support
// subviews inside a layer-hosting view, and hosting means `root` is a plain
// non-optional `let` — no `layer!` anywhere, which the alternative would force at
// every draw site.

@MainActor
private final class FloatingButtonView: NSView {

    // MARK: Event outlets — screen coordinates, interpreted by FloatingButton.

    var onPressBegan: (NSPoint) -> Void = { _ in }
    var onPressMoved: (NSPoint) -> Void = { _ in }
    var onPressEnded: (NSPoint) -> Void = { _ in }
    var onHoverChanged: (Bool) -> Void = { _ in }

    // MARK: Layers

    private let root = CALayer()
    private let fill = CAShapeLayer()
    /// Faint full circle behind the level arc, so the ring reads as a ring at
    /// zero level rather than as a stray tick mark.
    private let ringTrack = CAShapeLayer()
    private let ringProgress = CAShapeLayer()
    private let spinner = CAShapeLayer()
    private let glyph = CALayer()

    private var trackingAreaRef: NSTrackingArea?
    private var currentSymbolName: String?
    private var currentScale: CGFloat = 0

    /// Key under which the spinner's rotation is installed, so it can be found
    /// and removed without disturbing anything else on that layer.
    private static let spinnerAnimationKey = "phaya.spinner"

    /// Glyph point size. 22 pt inside a 52 pt circle leaves the symbol reading as
    /// an icon with a clear margin rather than as a filled disc.
    private static let glyphPointSize: CGFloat = 22

    /// One full spinner revolution. 0.9 s is the tempo of AppKit's own
    /// indeterminate spinner: unmistakably "working", not "panicking".
    private static let spinnerPeriod: CFTimeInterval = 0.9

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        root.masksToBounds = false
        // Layer-hosting requires assigning the layer *before* wantsLayer.
        layer = root
        wantsLayer = true

        fill.fillColor = FloatingButton.brandTeal.cgColor
        fill.shadowColor = NSColor.black.cgColor
        fill.shadowOpacity = 0.30
        fill.shadowRadius = 8
        // CALayer geometry on macOS is y-up, so a negative height drops the
        // shadow below the button.
        fill.shadowOffset = CGSize(width: 0, height: -2)

        for ring in [ringTrack, ringProgress, spinner] {
            ring.fillColor = nil
            ring.lineWidth = FloatingButton.ringWidth
            ring.lineCap = .round
            ring.strokeColor = NSColor.white.cgColor
        }
        ringTrack.opacity = 0.22
        ringProgress.strokeEnd = 0
        spinner.strokeColor = FloatingButton.brandTeal.cgColor

        glyph.contentsGravity = .resizeAspect

        for sublayer in [fill, ringTrack, ringProgress, spinner, glyph] {
            root.addSublayer(sublayer)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("PhayaVoice dictation")

        layoutLayers()
        // AppKit calls `updateTrackingAreas()` from its own layout pass, i.e. not
        // until the view is first displayed. Calling it here means hover works
        // from the very first frame, and the method removes any previous area, so
        // AppKit's later call cannot produce a duplicate.
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Never loaded from a nib — the panel is built entirely in code.
        fatalError("FloatingButtonView is code-only")
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutLayers()
    }

    private func layoutLayers() {
        // Layers do not participate in the implicit-animation-free world by
        // default: without this, every resize would crossfade.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let scale = window?.backingScaleFactor ?? 2
        for sublayer in [root, fill, ringTrack, ringProgress, spinner, glyph] {
            sublayer.contentsScale = scale
        }

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = FloatingButton.diameter / 2

        fill.frame = bounds
        let disc = CGPath(ellipseIn: CGRect(x: centre.x - radius,
                                            y: centre.y - radius,
                                            width: radius * 2,
                                            height: radius * 2),
                          transform: nil)
        fill.path = disc
        fill.shadowPath = disc      // exact shape, and cheaper than deriving it.

        // The ring layers get their own centred square bounds so `anchorPoint`
        // (0.5, 0.5) puts the rotation centre of the spinner on the button's
        // centre rather than on the view's origin.
        let ringCentreRadius = FloatingButton.diameter / 2 + FloatingButton.ringGap + FloatingButton.ringWidth / 2
        let box = (ringCentreRadius + FloatingButton.ringWidth / 2) * 2
        let boxBounds = CGRect(x: 0, y: 0, width: box, height: box)
        let boxCentre = CGPoint(x: box / 2, y: box / 2)

        for ring in [ringTrack, ringProgress, spinner] {
            ring.bounds = boxBounds
            ring.position = centre
            ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }

        ringTrack.path = CGPath(ellipseIn: CGRect(x: boxCentre.x - ringCentreRadius,
                                                  y: boxCentre.y - ringCentreRadius,
                                                  width: ringCentreRadius * 2,
                                                  height: ringCentreRadius * 2),
                                transform: nil)
        // Level arc: starts at 12 o'clock and grows clockwise, which is how every
        // circular progress control on this platform reads.
        ringProgress.path = arcPath(centre: boxCentre,
                                    radius: ringCentreRadius,
                                    sweep: 2 * .pi)
        // Spinner: a 240° arc, the widest sweep that still leaves an obvious gap
        // so the rotation is visible.
        spinner.path = arcPath(centre: boxCentre,
                               radius: ringCentreRadius,
                               sweep: 2 * .pi * (240.0 / 360.0))

        if currentScale != scale {
            currentScale = scale
            // Force a re-raster of the glyph at the new device scale.
            let name = currentSymbolName
            currentSymbolName = nil
            if let name { setSymbol(name) }
        }
        positionGlyph(centre: centre)
    }

    /// Arc starting at 12 o'clock, running clockwise for `sweep` radians.
    /// In this y-up layer space, π/2 is straight up.
    private func arcPath(centre: CGPoint, radius: CGFloat, sweep: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: centre,
                    radius: radius,
                    startAngle: .pi / 2,
                    endAngle: .pi / 2 - sweep,
                    clockwise: true)
        return path
    }

    private func positionGlyph(centre: CGPoint) {
        guard glyph.contents != nil else { return }
        let size = glyph.bounds.size
        glyph.position = CGPoint(x: centre.x, y: centre.y)
        glyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyph.bounds = CGRect(origin: .zero, size: size)
    }

    // MARK: Appearance

    func apply(_ appearance: FloatingButton.Appearance, animated: Bool, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        // 0.18 s: long enough to read as a colour change rather than a flicker,
        // short enough that the red is up before the user has finished clicking.
        CATransaction.setAnimationDuration(0.18)

        fill.fillColor = appearance.fillColor.cgColor
        spinner.strokeColor = appearance.fillColor.cgColor

        ringTrack.isHidden = !appearance.showsRing
        ringProgress.isHidden = !appearance.showsRing
        if !appearance.showsRing { ringProgress.strokeEnd = 0 }

        // Under Reduce Motion the spinner is removed rather than frozen: a static
        // arc conveys nothing, whereas the `waveform` glyph underneath it already
        // says "working". Same choice HUDPanel makes for its ProgressView.
        let wantsSpinner = appearance.showsSpinner && !reduceMotion
        spinner.isHidden = !wantsSpinner
        if wantsSpinner {
            startSpinner()
        } else {
            spinner.removeAnimation(forKey: Self.spinnerAnimationKey)
        }

        CATransaction.commit()

        setSymbol(appearance.symbolName)
    }

    func setRingProgress(_ progress: Float, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        // 0.08 s ≈ 1.5 publish intervals at AudioRecorder's 20 Hz, so consecutive
        // samples blend into continuous motion instead of stepping.
        CATransaction.setAnimationDuration(0.08)
        ringProgress.strokeEnd = CGFloat(min(max(progress, 0), 1))
        CATransaction.commit()
    }

    private func startSpinner() {
        guard spinner.animation(forKey: Self.spinnerAnimationKey) == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = -Double.pi * 2      // negative = clockwise in y-up space
        rotation.duration = Self.spinnerPeriod
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        spinner.add(rotation, forKey: Self.spinnerAnimationKey)
    }

    private func setSymbol(_ name: String) {
        guard currentSymbolName != name else { return }
        let scale = window?.backingScaleFactor ?? 2
        guard let raster = FloatingButton.symbolImage(name,
                                                      pointSize: Self.glyphPointSize,
                                                      weight: .semibold,
                                                      scale: scale) else {
            // Symbol unavailable on this OS: show nothing rather than a wrong
            // glyph. The fill colour still carries the state.
            glyph.contents = nil
            currentSymbolName = nil
            return
        }
        currentSymbolName = name
        currentScale = scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.contents = raster.image
        glyph.contentsScale = scale
        glyph.bounds = CGRect(origin: .zero, size: raster.size)
        glyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    // MARK: Hit testing

    /// Only the drawn circle (button + ring) is clickable. The transparent square
    /// corners decline the hit so they are not an invisible click trap over the
    /// document the user is actually working in.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the SUPERVIEW's coordinate system, not this view's —
        // comparing it against `bounds` directly is the classic silent bug here.
        let local = convert(point, from: superview)
        let dx = local.x - bounds.midX
        let dy = local.y - bounds.midY
        let radius = FloatingButton.outerRadius
        return (dx * dx + dy * dy) <= radius * radius ? self : nil
    }

    // MARK: Mouse

    /// The whole point of this control: PhayaVoice is *never* the active app when
    /// the user clicks it. Without this, the first click into an inactive window
    /// is consumed as an activation click and no `mouseDown` is delivered — which
    /// would mean every single click here was swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // `NSEvent.mouseLocation` rather than `event.locationInWindow`: the panel is
    // being moved out from under the pointer during a drag, so a window-relative
    // location is measured against a frame that has already changed. Absolute
    // screen coordinates are immune to that, and because the origin is recomputed
    // from the grab offset on every event rather than accumulated, a dropped or
    // coalesced event cannot make the button drift.

    override func mouseDown(with event: NSEvent) {
        onPressBegan(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        onPressMoved(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        onPressEnded(NSEvent.mouseLocation)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        // .activeAlways, not .activeInKeyWindow: this window can never become key,
        // so .activeInKeyWindow would never fire once. .inVisibleRect keeps the
        // area correct across resizes and makes the `rect` argument moot.
        //
        // The area is the view's full square, including the transparent corners
        // the hit test declines. That is deliberate: hover only changes opacity,
        // and a tracking area clipped to the circle would flicker as the pointer
        // grazed the rim.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged(false)
    }
}
