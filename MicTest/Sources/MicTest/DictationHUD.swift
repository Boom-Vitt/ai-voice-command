import AppKit
import Foundation

// MARK: - Why this panel is built the way it is
//
// This app types into whatever application the user is already working in
// (Slack, VS Code, a browser). If this window ever takes keyboard focus, the
// caret leaves the user's text field and injection breaks — that single mistake
// defeats the whole product. Everything below exists to keep the HUD visible
// and inert:
//
//   NonActivatingHUDPanel – overrides canBecomeKey / canBecomeMain to false.
//                           They are get-only computed properties on NSWindow,
//                           so overriding is the ONLY way to force them;
//                           `panel.canBecomeKey = false` does not compile, and
//                           is the usual first attempt.
//   .nonactivatingPanel   – showing or clicking the panel does not activate us.
//   orderFrontRegardless  – shows without activating. makeKeyAndOrderFront is
//                           precisely the focus steal we must never perform and
//                           appears nowhere in this file.
//   hidesOnDeactivate     – false, or the HUD would vanish the instant the
//                           user's app (correctly) stays frontmost.
//   collectionBehavior    – .canJoinAllSpaces + .fullScreenAuxiliary +
//                           .stationary so it follows the user across Spaces,
//                           shows over a full-screen editor, and does not slide
//                           away during Mission Control.
//   acceptsFirstMouse     – see HUDBackgroundView / HUDActionButton. This app is
//                           NEVER the active app, so every click on the HUD is
//                           a "first" click into an inactive window. Without
//                           the override AppKit swallows it as an activation
//                           click and delivers no mouseDown — which would mean
//                           the stop and quit buttons never fire and the panel
//                           can never be dragged.
//
// There is no NSAlert anywhere in this file, deliberately: a modal alert both
// activates the app and blocks the run loop.

// MARK: - Panel

/// `NSWindow.canBecomeKey` / `canBecomeMain` are get-only computed properties.
/// They can only be forced false by overriding.
private final class NonActivatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Background

/// The panel's content view. Subclassed purely for `acceptsFirstMouse`: the
/// panel is dragged by its background (`isMovableByWindowBackground`), and
/// AppKit only starts that drag if the first mouse-down is actually delivered.
private final class HUDBackgroundView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Status-row buttons

/// Every clickable control in the status row (stop, quit) is one of these.
///
/// Same reason as `HUDBackgroundView`: without `acceptsFirstMouse` every click
/// on this control is eaten as an activation click and the action never fires.
/// A plain `NSButton` here looks right and is dead on arrival — this app is
/// never frontmost, so *every* click it will ever receive is a first-mouse
/// click. Any control added to the HUD must be built on this class, never on
/// NSButton directly.
private final class HUDActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Level meter

/// Bar-graph level meter fed by a rolling history of linear RMS values.
///
/// Drawn in `draw(_:)` rather than with CALayer `cgColor`s so the semantic
/// colours resolve against the view's *current* appearance — a `cgColor` is
/// resolved once and would not follow a light/dark switch.
private final class HUDLevelMeterView: NSView {

    /// 10 bars keeps each bar ≥ 4 pt wide inside the 64 pt meter, which is the
    /// width below which a bar stops reading as a bar on a non-Retina display.
    static let barCount = 10

    private var history = [Float](repeating: 0, count: HUDLevelMeterView.barCount)

    /// Newest sample in on the right, oldest out on the left, so the meter
    /// scrolls like a waveform instead of redrawing in place.
    func push(_ value: Float) {
        history.removeFirst()
        history.append(min(max(value, 0), 1))
        needsDisplay = true
    }

    func reset() {
        history = [Float](repeating: 0, count: Self.barCount)
        needsDisplay = true
    }

    /// The newest displayed sample, so the owner can tell whether the meter has
    /// already drained to silence and skip pointless redraws.
    var newestSample: Float { history.last ?? 0 }

    /// Levels arrive as *linear* RMS; perceptual shaping belongs here, in the
    /// display layer. Conversational speech sits around 0.02–0.15 linear RMS, so
    /// a linear bar would hug the floor and look broken. Mapping through
    /// decibels with a −50 dBFS floor puts normal speech at roughly 30–75 %
    /// height, which is where a meter reads as responsive; −50 dB is also close
    /// to typical room noise, so silence rests at the bottom instead of
    /// shimmering.
    static func displayScale(_ rms: Float) -> Float {
        guard rms > 0.00001 else { return 0 }
        let db = 20 * log10(rms)
        let floorDB: Float = -50
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = CGFloat(Self.barCount)
        let spacing: CGFloat = 2
        let barWidth = max((bounds.width - spacing * (count - 1)) / count, 1)
        let radius = min(barWidth / 2, 2)

        // Track: a faint full-height column behind every bar, so a silent meter
        // still reads as a meter rather than as an empty gap.
        NSColor.tertiaryLabelColor.setFill()
        for index in 0..<Self.barCount {
            let x = CGFloat(index) * (barWidth + spacing)
            let rect = NSRect(x: x, y: bounds.midY - 1, width: barWidth, height: 2)
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }

        NSColor.controlAccentColor.setFill()
        for (index, sample) in history.enumerated() {
            let scaled = CGFloat(Self.displayScale(sample))
            let height = max(scaled * bounds.height, 2)
            let x = CGFloat(index) * (barWidth + spacing)
            let rect = NSRect(x: x,
                              y: (bounds.height - height) / 2,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Corrected highlight

/// A rounded stroke drawn just inside the panel's edge, shown while a cloud
/// correction has just landed. Its whole job is to make the correction *visible*
/// — the user should see the text get replaced, not merely find it changed.
///
/// A view that draws, rather than a `layer.borderColor`, so the semantic colour
/// re-resolves on a light/dark switch.
private final class HUDHighlightBorderView: NSView {
    var cornerRadius: CGFloat = 16

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: cornerRadius - inset,
                                yRadius: cornerRadius - inset)
        path.lineWidth = 2
        NSColor.systemGreen.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Purely decorative: never intercept a click that was meant for the panel
    /// background (a drag) or the stop button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - DictationHUD

/// The only visible UI of a background dictation app: a small, draggable,
/// never-focusable status panel showing what dictation is doing right now.
@MainActor
final class DictationHUD {

    // MARK: Public contract

    enum Mode: Sendable {
        case hidden
        /// Not listening, but on screen. The panel stays visible and clickable — that is
        /// the whole point of it, and `.hidden` would call `hide()`.
        ///
        /// This case exists because idle used to be rendered as `.transcribing`, chosen as
        /// the least-wrong of six when there was no sixth. The cost was not cosmetic: the
        /// HUD said the word "Transcribing" under an animated `waveform`, with the level
        /// meter running, while the microphone was OFF. Every visual cue the panel has for
        /// "I am working" was lit while it was doing nothing. `showsMeter(for:)` returns
        /// false here, which is the half that actually stops the lie.
        case idle(String)
        case listening              // mic live, waiting for speech
        case transcribing(String)   // live partial text
        case correcting(String)     // cloud pass running, showing current text
        case corrected(String)      // cloud replaced it — brief confirmation
        case error(String)
    }

    /// Called when the user clicks the HUD's stop affordance.
    var onStopRequested: (() -> Void)?

    /// Called when the user *confirms* the HUD's quit affordance — the second
    /// click of the two-click confirm described at `quitClicked`, never the
    /// first. The owner is expected to terminate the app.
    ///
    /// This exists because the menu bar item used to be the only way out, and a
    /// status item on a notched MacBook can be pushed behind the notch and
    /// become unreachable. The HUD is the affordance that is always there, so it
    /// has to carry the exit.
    var onQuitRequested: (() -> Void)?

    // MARK: Layout constants

    /// Fixed width. The HUD is a status indicator, not a document window; a
    /// width that changed with the text would make it twitch on every partial.
    ///
    /// 348 rather than 320 because the status row gained the quit button: 20 pt
    /// of button plus an 8 pt gap. Absorbing those 28 pt inside the old width
    /// would have come out of `statusLabel`, which has the lowest compression
    /// resistance in the row and is therefore the first thing to truncate.
    /// Widening by exactly what the row grew leaves the status word the same
    /// 169 pt it had before, so "Transcribing" still reads in full.
    private static let width: CGFloat = 348

    /// Corner radius of the panel.
    private static let cornerRadius: CGFloat = 16

    private static let horizontalPadding: CGFloat = 14
    private static let verticalPadding: CGFloat = 12
    /// Height of the status row (icon, title, meter, stop, quit).
    private static let headerHeight: CGFloat = 18
    /// Gap between the status row and the transcript text.
    private static let headerTextGap: CGFloat = 8

    /// Everything above and below the text: padding + header + gap + padding.
    private static var chromeHeight: CGFloat {
        verticalPadding * 2 + headerHeight + headerTextGap
    }

    /// Idle height ≈ 88 pt, i.e. two lines of Thai-spaced text.
    private static let minTextHeight: CGFloat = 88 - chromeHeight
    /// Hard ceiling so a long partial cannot turn the indicator into a window.
    private static let maxTextHeight: CGFloat = 196 - chromeHeight

    private static var textWidth: CGFloat { width - horizontalPadding * 2 }

    /// Body text size. 13.5 pt is the smallest size at which Thai tone marks
    /// stay individually legible on a Retina display.
    private static let bodyFontSize: CGFloat = 13.5

    /// Thai stacks vowels above and tone marks above those; at the default
    /// single-spaced line height the upper marks of one line collide with the
    /// descenders of the line above and get clipped. 1.5 is the multiple at
    /// which a two-storey Thai stack clears comfortably.
    private static let lineHeightMultiple: CGFloat = 1.5

    /// Show/hide fade. 150 ms reads as "appeared" rather than as an animation.
    private static let fadeDuration: TimeInterval = 0.15

    /// How long the `corrected` state stays visibly distinct. 1.5 s is long
    /// enough to catch out of the corner of the eye and short enough that it is
    /// gone before the user reaches the end of the next sentence.
    private static let correctedHighlightDuration: Duration = .milliseconds(1500)

    /// How long the quit button stays armed after its first click. 2 s is long
    /// enough to see the glyph change and click again on purpose, short enough
    /// that a button armed by accident has disarmed itself before the user's
    /// attention comes back to the HUD.
    private static let quitConfirmWindow: Duration = .milliseconds(2000)

    /// Hard floor under `quitConfirmMinDelay`, for the case where the system
    /// reports a pathologically small double-click interval. 350 ms is the value
    /// this button shipped with, and the measurement behind it still holds: it is
    /// well above the gap inside a real double-click (typically under 200 ms) and
    /// well under the time it takes to notice the icon changed and act on it. It
    /// is the *minimum* now, not the rule.
    private static let quitConfirmAbsoluteMinDelay: Duration = .milliseconds(350)

    /// Floor on the gap between arming quit and confirming it. Under this the
    /// second click is the tail of a double-click or of impatient mashing, not a
    /// decision.
    ///
    /// Derived from `NSEvent.doubleClickInterval` and read live on every check.
    /// This is the one thing in here that must NOT be "simplified" back to a
    /// literal, because `doubleClickInterval` is not a constant of the machine —
    /// it is the user's Accessibility → Pointer Control → double-click speed
    /// setting. The literal this replaced (0.35) was chosen against the macOS
    /// default of 0.5 s, so it left a 350–500 ms band in which a pair of clicks
    /// is one double-click to the OS but arm-then-confirm to this code; the
    /// button does not set `ignoresMultiClick`, so both actions really are
    /// delivered, and the app really did quit in that band. Worse, *slowing* the
    /// accessibility setting widens the band while a literal stays put — so the
    /// population most exposed would be exactly the one that slowed it because
    /// repeat clicks are hard for them to control, and quitting mid-dictation is
    /// the worst outcome this file has. Read live rather than cached at init or
    /// at arm time: the setting can change while the app runs, there is no
    /// notification for it, and one read site per check is also what keeps the
    /// floor and the expiry from disagreeing.
    ///
    /// Capped at half `quitConfirmWindow`, and the cap earns its place: the
    /// setting can be slowed far enough that an uncapped floor would meet or
    /// exceed the confirm window, at which point every second click is "too
    /// soon" and the window expires first — quit becomes unreachable. This
    /// button exists precisely because the menu bar item can vanish behind the
    /// notch, so an exit that cannot be clicked is a worse failure than the band
    /// the floor closes. The cap is written against the window rather than as a
    /// number so that shortening the window cannot silently reintroduce that
    /// deadlock. The cap does leave a residual band above a 1 s double-click
    /// setting, and that is the accepted trade: a narrowed band still needs a
    /// deliberate pause on a specific pair of clicks, whereas an unreachable
    /// quit is broken every time.
    private static var quitConfirmMinDelay: Duration {
        min(max(.seconds(NSEvent.doubleClickInterval), quitConfirmAbsoluteMinDelay),
            quitConfirmWindow / 2)
    }

    /// Meter housekeeping tick, and how long `setLevel` must stay silent before
    /// the bars start draining. A frozen meter reads as "the app hung", so the
    /// bars fall to silence instead of stopping mid-waveform.
    private static let meterTickInterval: Duration = .milliseconds(100)
    private static let levelStallThreshold: TimeInterval = 0.150
    private static let meterDecay: Float = 0.85

    /// Default distance above the bottom of the screen's visible frame. 120 pt
    /// clears the Dock and its bottom-corner stacks; the user can drag it
    /// anywhere and that position is remembered.
    private static let defaultBottomInset: CGFloat = 120

    /// Where the user parked the HUD, as `NSStringFromPoint` output (`"{x, y}"`)
    /// so it is legible in `defaults read` and survives a plist round-trip
    /// without a custom coder. Absence of the key — not a sentinel — means
    /// "never moved".
    private static let originDefaultsKey = "DictationHUD.origin"

    /// Debounce before a dragged position is written to `UserDefaults`. A
    /// background drag posts didMove once per frame; without this the HUD would
    /// hammer the defaults database for the length of the gesture.
    private static let persistDebounce: Duration = .milliseconds(300)

    // MARK: Views

    private let panel: NonActivatingHUDPanel
    private let background: HUDBackgroundView
    private let highlightBorder = HUDHighlightBorderView()
    private let iconView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let meterView = HUDLevelMeterView()
    private let stopButton = HUDActionButton()
    private let quitButton = HUDActionButton()
    private let textLabel = NSTextField(labelWithString: "")
    private var textHeightConstraint: NSLayoutConstraint!

    /// Off-screen twin of `textLabel`, used only for measurement. Measuring with
    /// the same cell type that will lay the text out is the only way to get a
    /// height that agrees with the render — `NSAttributedString.boundingRect`
    /// disagrees with TextKit exactly where `lineHeightMultiple` and Thai marks
    /// are involved, which is the case that matters here.
    private let measuringLabel = NSTextField(labelWithString: "")

    // MARK: State

    private var mode: Mode = .hidden
    private var isShown = false
    private var reduceMotion = false

    /// The last origin *this* class set. `didMove` is not reliably posted
    /// synchronously from `setFrame`, so a "programmatic move" boolean flag can
    /// have been cleared by the time the notification arrives — and a
    /// screen-change reposition would then be persisted as if the user had
    /// dragged there, destroying the saved position. Comparing against the last
    /// origin we set is immune to notification timing.
    private var lastProgrammaticOrigin: NSPoint?

    private var lastLevelAt: Date = .distantPast
    private var smoothedLevel: Float = 0

    private var fadeGeneration: UInt64 = 0
    private var correctedGeneration: UInt64 = 0
    private var persistGeneration: UInt64 = 0
    private var meterTask: Task<Void, Never>?

    /// Quit's confirm state: when the button was armed, and the task that
    /// disarms it again. See `quitClicked`.
    ///
    /// `ContinuousClock`, not `Date`, and that is a correctness point rather
    /// than a style one. The expiry half of this window is a `Task.sleep`, which
    /// is monotonic; if the floor half compared `Date()` values it would be on
    /// the wall clock, and a forward correction landing between the two clicks —
    /// NTP, a timezone or DST write, a manual set — would make the floor believe
    /// more time had passed than really had and let a fast pair through. Both
    /// halves are on the one monotonic clock.
    ///
    /// `nil` is the single source of truth for "not armed", so an armed flag and
    /// an armed instant cannot drift apart.
    private var quitArmedAt: ContinuousClock.Instant?
    private var quitArmed: Bool { quitArmedAt != nil }
    private var quitConfirmTask: Task<Void, Never>?

    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?

    // MARK: Init

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: Self.width, height: 88)

        // .borderless removes the title bar; .nonactivatingPanel is what stops
        // showing or clicking this window from activating the app.
        panel = NonActivatingHUDPanel(contentRect: contentRect,
                                      styleMask: [.nonactivatingPanel, .borderless],
                                      backing: .buffered,
                                      defer: false)

        background = HUDBackgroundView(frame: contentRect)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        // .active, not .followsWindowActiveState: this panel is never key, so
        // "follows active state" would render it permanently inactive and flat.
        background.state = .active
        // A mask image, not `layer.cornerRadius`: with .behindWindow blending
        // the blur is composited by the window server outside the view's layer,
        // so a layer corner radius clips the fill but not the blur. The mask
        // also shapes the window's alpha, which is what the AppKit drop shadow
        // is derived from — so the shadow follows the rounded corners instead of
        // boxing them.
        background.maskImage = Self.roundedMaskImage(radius: Self.cornerRadius)

        panel.contentView = background

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The HUD is draggable, so — unlike a pure read-only overlay — it must
        // receive mouse events rather than let them fall through.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        // Stay usable while some other app runs a modal sheet.
        panel.worksWhenModal = true
        // .statusBar sits above normal and floating windows, which is where a
        // status indicator belongs, and above most app-drawn overlays too.
        panel.level = .statusBar
        // .canJoinAllSpaces: follow the user across Spaces instead of pinning to
        // the Space where dictation started. .fullScreenAuxiliary: appear over a
        // full-screen editor, which is where dictation is most often used.
        // .stationary: do not slide during Mission Control. .ignoresCycle: never
        // appear in Cmd-` window cycling.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Suppress AppKit's own window fade; show/hide is animated by hand so it
        // can be skipped under Reduce Motion.
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.setAccessibilityLabel("Dictation status")

        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        buildContent()
        installObservers()

        set(.listening)
        moveTo(Self.restoredOrigin(for: panel.frame.size))
    }

    // `isolated deinit` (SE-0371) keeps teardown on the main actor. Without it
    // Swift 6 refuses to touch the non-Sendable observer tokens from a
    // nonisolated deinit — and these tokens must be released on the queue they
    // were registered against anyway.
    isolated deinit {
        meterTask?.cancel()
        quitConfirmTask?.cancel()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
    }

    // MARK: - Content

    private func buildContent() {
        let pad = Self.horizontalPadding
        let vpad = Self.verticalPadding

        highlightBorder.cornerRadius = Self.cornerRadius
        highlightBorder.translatesAutoresizingMaskIntoConstraints = false
        highlightBorder.isHidden = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        // The icon repeats the state that the status text states in words; it is
        // never the only carrier of the state, so a colour-blind user (or a
        // monochrome display) loses nothing.
        iconView.setAccessibilityHidden(true)

        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        meterView.translatesAutoresizingMaskIntoConstraints = false
        meterView.setAccessibilityHidden(true)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.isBordered = false
        stopButton.bezelStyle = .regularSquare
        stopButton.imagePosition = .imageOnly
        stopButton.image = NSImage(systemSymbolName: "stop.circle.fill",
                                   accessibilityDescription: "Stop dictation")
        stopButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = "Stop dictation"
        stopButton.setAccessibilityLabel("Stop dictation")
        stopButton.setAccessibilityRole(.button)

        quitButton.translatesAutoresizingMaskIntoConstraints = false
        quitButton.isBordered = false
        quitButton.bezelStyle = .regularSquare
        quitButton.imagePosition = .imageOnly
        quitButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        quitButton.target = self
        quitButton.action = #selector(quitClicked)
        quitButton.setAccessibilityRole(.button)
        // Symbol, tint, tooltip and label all depend on whether quit is armed,
        // so they are set together in one place instead of piecemeal here.
        updateQuitAppearance()

        configureBodyLabel(textLabel)
        configureBodyLabel(measuringLabel)
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(textLabel)
        background.addSubview(iconView)
        background.addSubview(statusLabel)
        background.addSubview(meterView)
        background.addSubview(stopButton)
        background.addSubview(quitButton)
        background.addSubview(highlightBorder)

        textHeightConstraint = textLabel.heightAnchor.constraint(equalToConstant: Self.minTextHeight)

        NSLayoutConstraint.activate([
            highlightBorder.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            highlightBorder.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            highlightBorder.topAnchor.constraint(equalTo: background.topAnchor),
            highlightBorder.bottomAnchor.constraint(equalTo: background.bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: pad),
            iconView.topAnchor.constraint(equalTo: background.topAnchor, constant: vpad),
            iconView.widthAnchor.constraint(equalToConstant: Self.headerHeight),
            iconView.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            statusLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
            statusLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            meterView.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),
            meterView.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),
            meterView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            meterView.widthAnchor.constraint(equalToConstant: 64),
            meterView.heightAnchor.constraint(equalToConstant: 14),

            // Trailing chain, read right to left: quit at the edge, stop 8 pt to
            // its left, the meter 8 pt left of that. Every view in the row is
            // pinned to its neighbour, so the row has exactly one solution and
            // nothing here is ambiguous.
            stopButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -8),
            stopButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 20),
            stopButton.heightAnchor.constraint(equalToConstant: 20),

            quitButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -(pad - 2)),
            quitButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            quitButton.widthAnchor.constraint(equalToConstant: 20),
            quitButton.heightAnchor.constraint(equalToConstant: 20),

            textLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: pad),
            textLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -pad),
            textLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: Self.headerTextGap),
            textHeightConstraint,
        ])
    }

    private func configureBodyLabel(_ field: NSTextField) {
        field.font = .systemFont(ofSize: Self.bodyFontSize)
        field.textColor = .labelColor
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.preferredMaxLayoutWidth = Self.textWidth
        field.isSelectable = false
        field.drawsBackground = false
        field.isBezeled = false
    }

    @objc private func stopClicked() {
        onStopRequested?()
    }

    // MARK: - Quit
    //
    // Quit takes two clicks, and the reasoning is worth writing down because
    // every cheaper option is worse here:
    //
    //   * A single click would sit one 8 pt gap from stop, on a panel that is
    //     dragged by its own background and stays on screen the whole time the
    //     app runs. A click aimed at stop that lands 8 pt past its trailing edge,
    //     or a drag begun slightly off, would end the session and take whatever
    //     text was still in flight with it. Stop is recoverable; quit is not.
    //   * An NSAlert confirmation is out of the question: it activates the app
    //     and moves the caret out of the user's text field, which is the single
    //     failure this whole file exists to prevent (see the note at the top).
    //     That is why there is no NSAlert anywhere in here.
    //   * Enabling quit only while idle would hide the exit at exactly the
    //     moment a wedged capture makes the user want it — and the reason this
    //     button exists at all is that the menu bar item can disappear behind
    //     the notch. The affordance has to stay live; it only has to refuse to
    //     fire by accident.
    //
    // Two clicks with a floor on the gap between them also inherits two pieces
    // of protection for free. NSButton sends no action when the mouse is dragged
    // off the button before release, so a drag that begins on quit can only ever
    // arm it; and `quitConfirmMinDelay` — derived from the live system
    // double-click interval, never a literal, see its declaration — turns
    // mashing, a double-click, or clicking again because nothing seemed to
    // happen, back into a re-arm. Only a click the user paused before gets
    // through.
    //
    // The armed state is carried by the glyph *and* the tint, never by colour
    // alone, which is the rule the rest of the HUD already follows.

    @objc private func quitClicked() {
        guard let armedAt = quitArmedAt else {
            armQuit()
            return
        }
        // Monotonic on both sides: this instant came from `ContinuousClock` and
        // so does the comparison, matching the `Task.sleep` that expires the
        // window. The floor is read from the live system setting here, at check
        // time, rather than captured when the button was armed — one read site,
        // so a double-click speed changed mid-window cannot leave the two halves
        // of the same window disagreeing about how long it is.
        guard armedAt.duration(to: .now) >= Self.quitConfirmMinDelay else {
            // Too soon to be a decision. Re-arming also restarts the window, so
            // repeated fast clicks can never accumulate into a quit.
            armQuit()
            return
        }
        disarmQuit()
        // No thread hop, exactly like stopClicked: this class is @MainActor and
        // AppKit delivers control actions on the main thread, so the callback
        // already runs there.
        onQuitRequested?()
    }

    private func armQuit() {
        quitArmedAt = .now
        updateQuitAppearance()

        // A stored task that is cancelled, rather than the generation counters
        // used elsewhere in this file: only one disarm is ever pending, so there
        // is nothing to version. `[weak self]` keeps a sleeping task from holding
        // the HUD alive, and the deinit cancels it so a HUD torn down mid-window
        // leaves nothing ticking.
        quitConfirmTask?.cancel()
        quitConfirmTask = Task { [weak self] in
            // `clock:` is spelled out rather than defaulted. It does default to
            // `.continuous` today, so this is not a behaviour change — but this
            // half of the window has to stay on the same clock as the floor
            // check in `quitClicked`, and leaving it to a stdlib default nothing
            // in this file controls is exactly how the two halves came to be on
            // different clocks the first time. Continuous rather than
            // suspending, specifically: a window armed just before the lid
            // closed must be expired by the time the machine wakes, because
            // hours later the user has no memory of arming it and their next
            // click has to arm, not quit.
            try? await Task.sleep(for: Self.quitConfirmWindow, clock: .continuous)
            // `try?` swallows the cancellation error, so the cancelled case has
            // to be tested rather than caught.
            if Task.isCancelled { return }
            self?.disarmQuit()
        }
    }

    private func disarmQuit() {
        // Safe to call from inside quitConfirmTask itself: by then the task is
        // past its only suspension point and simply returns.
        quitConfirmTask?.cancel()
        quitConfirmTask = nil
        // Tested before the instant is cleared, so the appearance update below
        // always runs on a real armed→disarmed transition and the button can
        // never be left red with nothing armed behind it.
        guard quitArmed else { return }
        quitArmedAt = nil
        updateQuitAppearance()
    }

    /// Symbol, tint, tooltip and accessibility label for quit's two states, set
    /// together so they cannot drift apart — a button still captioned "Quit
    /// MicTest" while its icon says "confirm" would be worse than no confirm
    /// step at all.
    private func updateQuitAppearance() {
        let label = quitArmed ? "Confirm quit MicTest" : "Quit MicTest"
        let symbol = quitArmed ? "exclamationmark.circle.fill" : "xmark.circle.fill"
        quitButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        // Red only while armed. A permanently red control next to stop would
        // read as the primary action of the row; at rest quit carries the same
        // weight as stop, because a quit button the user cannot find is the
        // problem this was added to solve.
        quitButton.contentTintColor = quitArmed ? .systemRed : .secondaryLabelColor
        quitButton.toolTip = quitArmed ? "Click again to quit MicTest" : "Quit MicTest"
        quitButton.setAccessibilityLabel(label)
    }

    // MARK: - Visibility

    func show() {
        guard !isShown else { return }
        isShown = true
        // The armed invariant is restored on *both* edges of visibility, not
        // just hide()'s. hide() disarms and clears `isShown` before starting its
        // 150 ms fade, and for the length of that fade the panel is still
        // ordered in and still hit-testable: a click landing there re-arms, the
        // panel then orders out, and the next show() would hand back an
        // already-armed button on which a single click quits. Enforcing it here
        // too makes the invariant hold whatever the caller does.
        //
        // Deliberately *after* the `isShown` guard, not before it: a redundant
        // show() on an already-visible HUD must not disarm a confirm the user is
        // halfway through. Only a genuine hidden→shown transition resets it.
        disarmQuit()
        fadeGeneration &+= 1

        // Screens may have changed while hidden: a saved origin from a monitor
        // that is no longer attached must not be honoured.
        moveTo(Self.clampedOrigin(panel.frame.origin, size: panel.frame.size))

        // orderFrontRegardless, never makeKeyAndOrderFront: it shows the panel
        // while this app is inactive, and takes no focus doing it.
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        guard !reduceMotion else {
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        fadeGeneration &+= 1
        let generation = fadeGeneration
        stopMeterTask()
        // A button the user can no longer see must not still be armed when the
        // HUD comes back; otherwise the next single click would quit. This edge
        // alone does not settle it — the fade below leaves the panel clickable
        // for another 150 ms — which is why show() disarms as well.
        disarmQuit()

        guard !reduceMotion else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // The completion handler is @Sendable under Swift 6, so it cannot touch
            // main-actor state synchronously. Hop explicitly -- NOT assumeIsolated,
            // which traps when it guesses wrong (this app already crashed that way).
            Task { @MainActor in
                // A show() during the fade bumps the generation; without this guard
                // it would be immediately ordered out again by the stale completion.
                guard let self, self.fadeGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    // MARK: - Mode

    func set(_ mode: Mode) {
        self.mode = mode
        correctedGeneration &+= 1

        if case .hidden = mode {
            hide()
            return
        }

        apply(mode, highlighted: isHighlightedMode(mode))

        if case .corrected = mode {
            // Hold the confirmation appearance briefly, then settle back to the
            // ordinary look with the same (now corrected) text still showing.
            let generation = correctedGeneration
            Task { [weak self] in
                try? await Task.sleep(for: Self.correctedHighlightDuration)
                guard let self, self.correctedGeneration == generation else { return }
                self.apply(self.mode, highlighted: false)
            }
        }

        if showsMeter(for: mode) {
            lastLevelAt = Date()
            startMeterTask()
        } else {
            stopMeterTask()
            smoothedLevel = 0
            meterView.reset()
        }
    }

    private func isHighlightedMode(_ mode: Mode) -> Bool {
        if case .corrected = mode { return true }
        return false
    }

    private func showsMeter(for mode: Mode) -> Bool {
        switch mode {
        case .listening, .transcribing: return true
        // `.idle` MUST stay on this side. The meter is the strongest "audio is being
        // captured right now" signal on the panel, and idle is precisely when it is not.
        case .hidden, .idle, .correcting, .corrected, .error: return false
        }
    }

    /// Icon, tint, status word, and body text for one mode.
    ///
    /// State is never carried by colour alone: the SF Symbol and the status word
    /// both change with every state, so the tint is confirmation rather than
    /// information.
    private func apply(_ mode: Mode, highlighted: Bool) {
        let symbol: String
        let tint: NSColor
        let status: String
        let body: String
        let bodyIsPlaceholder: Bool

        switch mode {
        case .hidden:
            return
        case .idle(let text):
            // Hollow `mic`, not `mic.fill`, and no colour: the filled red glyph is what
            // `.listening` uses, and the two states must not look alike at a glance. This
            // matches the menubar item, which already shows hollow `mic` when idle.
            symbol = "mic"
            tint = .secondaryLabelColor
            status = "Idle"
            body = text.isEmpty ? "Idle" : text
            bodyIsPlaceholder = true
        case .listening:
            symbol = "mic.fill"
            tint = .systemRed
            status = "Listening"
            body = "Speak now…"
            bodyIsPlaceholder = true
        case .transcribing(let text):
            symbol = "waveform"
            tint = .controlAccentColor
            status = "Transcribing"
            body = text.isEmpty ? "Transcribing…" : text
            bodyIsPlaceholder = text.isEmpty
        case .correcting(let text):
            symbol = "sparkles"
            tint = .systemPurple
            status = "Correcting"
            body = text.isEmpty ? "Correcting…" : text
            bodyIsPlaceholder = text.isEmpty
        case .corrected(let text):
            symbol = "checkmark.circle.fill"
            tint = .systemGreen
            status = "Corrected"
            body = text.isEmpty ? "Corrected" : text
            bodyIsPlaceholder = text.isEmpty
        case .error(let message):
            symbol = "exclamationmark.triangle.fill"
            tint = .systemOrange
            status = "Error"
            body = message.isEmpty ? "Dictation failed." : message
            bodyIsPlaceholder = false
        }

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status)
        iconView.contentTintColor = tint
        statusLabel.stringValue = status
        statusLabel.textColor = highlighted ? .systemGreen : .secondaryLabelColor

        meterView.isHidden = !showsMeter(for: mode)
        highlightBorder.isHidden = !highlighted
        highlightBorder.needsDisplay = true

        let color: NSColor = bodyIsPlaceholder ? .secondaryLabelColor : .labelColor
        let height = applyBodyText(body, color: color)

        panel.setAccessibilityLabel("Dictation \(status.lowercased()). \(body)")

        textHeightConstraint.constant = height
        resizePanel(textHeight: height)
    }

    /// Lay out `text`, head-truncating it if it would overflow, and return the
    /// height the label needs.
    ///
    /// Truncation drops the *front* of the string, not the tail: during
    /// dictation the newest words are the ones the user is checking, so the tail
    /// is what must stay on screen.
    @discardableResult
    private func applyBodyText(_ text: String, color: NSColor) -> CGFloat {
        let full = Self.attributed(text, color: color)
        measuringLabel.attributedStringValue = full
        var height = measuredHeight()

        if height > Self.maxTextHeight {
            let truncated = truncatedFromHead(text, color: color)
            measuringLabel.attributedStringValue = truncated
            height = measuredHeight()
            textLabel.attributedStringValue = truncated
        } else {
            textLabel.attributedStringValue = full
        }

        return min(max(height, Self.minTextHeight), Self.maxTextHeight)
    }

    /// Ask the same cell type that will lay the text out how tall it needs to
    /// be. `NSAttributedString.boundingRect` gives a different answer once
    /// `lineHeightMultiple` is involved, and guessing the difference with a
    /// slack constant is how Thai tone marks end up clipped.
    private func measuredHeight() -> CGFloat {
        let bounds = NSRect(x: 0, y: 0, width: Self.textWidth, height: .greatestFiniteMagnitude)
        guard let cell = measuringLabel.cell else { return Self.minTextHeight }
        return ceil(cell.cellSize(forBounds: bounds).height)
    }

    /// Smallest number of leading characters that can be dropped for the rest to
    /// fit, found by binary search over grapheme clusters (so a Thai consonant
    /// is never split from its vowels and tone marks).
    private func truncatedFromHead(_ text: String, color: NSColor) -> NSAttributedString {
        let characters = Array(text)
        let bounds = NSRect(x: 0, y: 0, width: Self.textWidth, height: .greatestFiniteMagnitude)

        func fits(dropping count: Int) -> Bool {
            measuringLabel.attributedStringValue = Self.attributed(Self.tail(characters, dropping: count),
                                                                   color: color)
            guard let cell = measuringLabel.cell else { return true }
            return ceil(cell.cellSize(forBounds: bounds).height) <= Self.maxTextHeight
        }

        var low = 0
        var high = characters.count
        while low < high {
            let mid = (low + high) / 2
            if fits(dropping: mid) { high = mid } else { low = mid + 1 }
        }

        var drop = low
        // Prefer to cut at a word boundary so an English word is not sliced in
        // half. Dropping more can only ever shrink the text, so this cannot
        // reintroduce an overflow.
        if let boundary = Self.nextWordBoundary(characters, from: drop, within: 16) {
            drop = boundary
        } else if drop > 0, Self.thaiPrePosedVowels.contains(characters[drop - 1]) {
            // Thai writes เ แ โ ใ ไ *before* the consonant they are pronounced
            // after. Cutting between them loses the vowel, so pull it back in —
            // but only if the result still fits.
            if fits(dropping: drop - 1) { drop -= 1 }
        }

        return Self.attributed(Self.tail(characters, dropping: drop), color: color)
    }

    private static func tail(_ characters: [Character], dropping count: Int) -> String {
        guard count > 0 else { return String(characters) }
        guard count < characters.count else { return "…" }
        return "…" + String(characters[count...])
    }

    /// Thai pre-posed vowels: written to the left of the consonant they follow
    /// in speech, and therefore a separate grapheme cluster from it.
    private static let thaiPrePosedVowels: Set<Character> = ["เ", "แ", "โ", "ใ", "ไ"]

    /// First index at or after `start`, within `limit` characters, that begins a
    /// new word. Nil if there is no such break — which is the normal case for
    /// Thai, where words are not separated by spaces.
    private static func nextWordBoundary(_ characters: [Character],
                                         from start: Int,
                                         within limit: Int) -> Int? {
        guard start < characters.count else { return nil }
        let end = min(start + limit, characters.count - 1)
        guard start <= end else { return nil }
        for index in start...end where characters[index].isWhitespace {
            let next = index + 1
            return next < characters.count ? next : nil
        }
        return nil
    }

    /// Body-text attributes. The paragraph style is the whole point: Thai stacks
    /// vowels above the consonant and tone marks above those, and at default
    /// leading the upper marks are clipped by the line above. `lineHeightMultiple`
    /// scales the leading and `minimumLineHeight` puts a hard floor under it so a
    /// short line cannot collapse back to single spacing.
    private static func attributed(_ text: String, color: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: bodyFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        paragraph.minimumLineHeight = ceil(bodyFontSize * lineHeightMultiple)
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: - Level meter

    /// 0…1 input level for the meter.
    func setLevel(_ rms: Float) {
        // Guard on mode, not merely on visibility: a level arriving while
        // correcting or failed would animate a meter that is not drawn at all.
        guard isShown, showsMeter(for: mode) else { return }
        lastLevelAt = Date()
        smoothedLevel = min(max(rms, 0), 1)
        meterView.push(smoothedLevel)
    }

    /// Drains the meter when levels stop arriving. A meter frozen mid-waveform
    /// reads as "the app hung"; bars falling to silence read as "nothing to
    /// hear", which is the truth.
    private func startMeterTask() {
        guard meterTask == nil else { return }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meterTickInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                self.decayMeterIfStalled()
            }
        }
    }

    private func stopMeterTask() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func decayMeterIfStalled() {
        guard Date().timeIntervalSince(lastLevelAt) > Self.levelStallThreshold else { return }
        guard smoothedLevel > 0.001 || meterView.newestSample > 0.001 else { return }
        smoothedLevel *= Self.meterDecay
        meterView.push(smoothedLevel)
    }

    // MARK: - Geometry

    private func resizePanel(textHeight: CGFloat) {
        let height = (Self.chromeHeight + textHeight).rounded()
        let frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        // Grow upward: the HUD sits near the bottom of the screen, so pinning
        // the bottom edge keeps it from creeping down over the Dock.
        let proposed = NSRect(x: frame.minX, y: frame.minY, width: Self.width, height: height)
        let origin = Self.clampedOrigin(proposed.origin, size: proposed.size)
        lastProgrammaticOrigin = origin
        panel.setFrame(NSRect(origin: origin, size: proposed.size), display: true)
        // The window shadow is cached from the previous alpha shape; without
        // this the old outline lingers around the new one.
        panel.invalidateShadow()
    }

    private func moveTo(_ origin: NSPoint) {
        lastProgrammaticOrigin = origin
        panel.setFrameOrigin(origin)
    }

    /// Keep `size` fully inside `visible`.
    ///
    /// The `max(visible.minX, …)` guards are not decoration: were the panel ever
    /// wider than the visible frame, `maxX - width` would fall below `minX` and
    /// the clamp would invert, pinning the HUD *off* the screen it was meant to
    /// be pulled onto.
    static func clamp(origin: NSPoint, size: NSSize, into visible: NSRect) -> NSPoint {
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return NSPoint(x: min(max(origin.x, visible.minX), maxX),
                       y: min(max(origin.y, visible.minY), maxY))
    }

    /// `visibleFrame` of the screen a proposed frame lands on. "Lands on" is the
    /// screen containing the frame's centre — the rule the window server uses to
    /// decide which screen a window belongs to — falling back to the screen it
    /// overlaps most, then to the main screen. `visibleFrame`, not `frame`, is
    /// what excludes the menu bar and the Dock, so positioning against it means
    /// the HUD never lands under either.
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

        // The saved position points at a monitor that is no longer attached (or
        // is outright garbage). Fall back to the main screen so the clamp pulls
        // the HUD back into view rather than leaving it in the void.
        return (NSScreen.main ?? screens[0]).visibleFrame
    }

    private static func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let frame = NSRect(origin: origin, size: size)
        guard let visible = landingVisibleFrame(for: frame, screens: NSScreen.screens) else {
            // Headless session: nothing to clamp against, so returning the
            // proposal unchanged is the only honest answer.
            return origin
        }
        return clamp(origin: origin, size: size, into: visible)
    }

    /// Bottom-centre of a screen, `defaultBottomInset` above the bottom edge.
    static func defaultOrigin(size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(x: (visible.midX - size.width / 2).rounded(),
                y: (visible.minY + defaultBottomInset).rounded())
    }

    /// The screen the pointer is currently on — the HUD should appear where the
    /// user is looking, not on whichever display macOS calls "main".
    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The saved origin if there is one, otherwise bottom-centre of the screen
    /// containing the mouse — either way clamped onto a screen that exists.
    private static func restoredOrigin(for size: NSSize,
                                       defaults: UserDefaults = .standard) -> NSPoint {
        // Absence of the key, not a sentinel, is what means "never moved".
        // NSPointFromString returns (0, 0) for unparseable input, which the
        // clamp below then rescues, so corrupt defaults cannot hide the HUD.
        if let saved = defaults.string(forKey: originDefaultsKey).map(NSPointFromString) {
            return clampedOrigin(saved, size: size)
        }
        guard let visible = screenUnderMouse()?.visibleFrame else { return .zero }
        return clampedOrigin(defaultOrigin(size: size, in: visible), size: size)
    }

    /// Persist a *user-initiated* move, debounced.
    private func schedulePersist(_ origin: NSPoint) {
        persistGeneration &+= 1
        let generation = persistGeneration
        Task { [weak self] in
            try? await Task.sleep(for: Self.persistDebounce)
            guard let self, self.persistGeneration == generation else { return }
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.originDefaultsKey)
        }
    }

    // MARK: - Observers

    private func installObservers() {
        // Display reconfiguration: resolution change, laptop lid, a monitor
        // unplugged. Without this the HUD ends up off-screen or under the Dock.
        //
        // The block is @Sendable, so it cannot touch main-actor state directly;
        // it hops with `Task { @MainActor in … }`. It deliberately does NOT use
        // MainActor.assumeIsolated, which traps when it turns out not to be on
        // the main actor.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.moveTo(Self.clampedOrigin(self.panel.frame.origin, size: self.panel.frame.size))
            }
        }

        // The panel is dragged by its background, so the only signal that the
        // user moved it is didMove. Filtering on "this is not the origin we last
        // set ourselves" is what separates a user drag from a reposition; a
        // boolean flag around setFrame would not, because didMove is not
        // guaranteed to be posted synchronously.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let origin = self.panel.frame.origin
                if let last = self.lastProgrammaticOrigin,
                   abs(last.x - origin.x) < 0.5, abs(last.y - origin.y) < 0.5 {
                    return
                }
                self.lastProgrammaticOrigin = nil
                self.schedulePersist(origin)
            }
        }

        // Accessibility options post on NSWorkspace's own notification centre,
        // not the default one — observing the default centre silently never
        // fires, which is why Reduce Motion is so often ignored by apps.
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    // MARK: - Mask

    /// A rounded-rectangle mask, cap-inset so AppKit stretches only its middle
    /// and the corners keep their radius at any panel height.
    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge))
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: edge, height: edge),
                     xRadius: radius,
                     yRadius: radius).fill()
        image.unlockFocus()
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
