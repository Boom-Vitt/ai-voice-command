import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Why this panel is configured the way it is
//
// PhayaVoice types into whatever app the user is already working in. If the HUD
// ever takes keyboard focus, the text goes into the HUD's process instead of the
// user's document — that single mistake defeats the entire product. Everything
// below exists to guarantee the panel is visible and inert:
//
//   .nonactivatingPanel  – showing the panel does not activate this app
//   canBecomeKey/Main    – overridden to false (they are get-only on NSWindow,
//                          so they must be overridden, never assigned)
//   orderFrontRegardless – shows without activating; makeKeyAndOrderFront is
//                          precisely the focus steal we must never perform
//   ignoresMouseEvents   – clicks pass straight through to the app underneath
//   hidesOnDeactivate    – false, or the HUD would vanish the moment the user's
//                          app (correctly) stays frontmost
//   collectionBehavior   – .canJoinAllSpaces + .fullScreenAuxiliary so it shows
//                          over a full-screen editor, which is where dictation
//                          is most often used

/// `NSWindow.canBecomeKey` / `canBecomeMain` are computed, get-only properties.
/// They can only be forced false by overriding — `panel.canBecomeKey = false`
/// does not compile, and is the usual first attempt.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Observable state backing the SwiftUI content. Split out from `HUDPanel` so
/// the view redraws on property changes without the panel having to rebuild
/// its hosting view.
@MainActor
@Observable
final class HUDViewModel {
    var state: DictationState = .idle
    /// Linear RMS straight from `AudioRecorder`, 0…1.
    var level: Float = 0
    /// Short history of levels, newest last, so the meter reads as a waveform
    /// rather than a single twitching bar.
    var levelHistory: [Float] = Array(repeating: 0, count: HUDPanel.meterBarCount)
    var elapsed: TimeInterval = 0
    var reduceMotion: Bool = false
}

/// The only UI PhayaVoice has: a small floating capsule at the bottom-centre of
/// the active screen showing dictation state and a live level meter.
@MainActor
final class HUDPanel: DictationHUD {

    // MARK: - Layout / timing constants

    /// Bars in the level meter. 14 is enough to read as a waveform at this size
    /// while each bar stays ≥ 3 pt wide, which is the point below which a bar
    /// stops being legible on a non-Retina display.
    static let meterBarCount = 14

    /// Gap between the panel and the top of the Dock. We position inside
    /// `NSScreen.visibleFrame`, which already excludes the Dock and menu bar, so
    /// this is pure breathing room rather than Dock arithmetic.
    private let bottomMargin: CGFloat = 24

    /// Elapsed-time refresh. The readout shows tenths of a second, so 100 ms is
    /// exactly the rate at which the displayed value can change — faster is
    /// wasted redraws, slower makes the tenths digit stutter.
    private let elapsedTickInterval: TimeInterval = 0.1

    /// How long a `.failed` message stays up before dismissing itself. 3 s is
    /// the usual floor for "long enough to read a short sentence" and is what
    /// the spec calls for; the user has already moved on by then.
    private let failureAutoDismiss: TimeInterval = 3.0

    /// Safety net for `.injecting`. Injection is a few milliseconds, and the
    /// controller normally calls `hide()` straight after. If it ever does not
    /// (crash, thrown error swallowed upstream) the HUD must not sit on screen
    /// forever. 1.5 s is far beyond any real injection.
    private let injectingAutoDismiss: TimeInterval = 1.5

    /// Multiplier applied to the newest meter sample on each tick during which
    /// no fresh level arrived, so the bars drain instead of freezing if the
    /// audio thread stalls. 0.85 per 100 ms tick reaches silence in about a
    /// second — visibly falling, not an abrupt cut.
    private let meterDecay: Float = 0.85

    /// How long `setLevel` must stay silent before the meter starts draining.
    /// `AudioRecorder` publishes at 20 Hz (50 ms), so 150 ms is three missed
    /// updates: comfortably past normal scheduling jitter, and still fast enough
    /// that a genuinely stalled meter never reads as a hung app.
    private let levelStallThreshold: TimeInterval = 0.150

    // MARK: - State

    /// Exposed so the panel's focus-safety configuration can be asserted in a
    /// test without ever putting a window on screen.
    private(set) var panel: NSPanel

    private let model = HUDViewModel()
    private var hostingView: NSHostingView<HUDContentView>!

    private var elapsedTimer: DispatchSourceTimer?
    private var dismissGeneration: UInt64 = 0
    private var lastLevelAt: Date = .distantPast
    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var isVisible = false

    // MARK: - Init

    init() {
        // .borderless removes the title bar; .nonactivatingPanel is what keeps
        // showing this window from activating the app.
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 56),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // SwiftUI draws the shadow, so the
                                         // rounded corners are not boxed by an
                                         // AppKit rectangle shadow.
        // .statusBar sits above normal and floating windows, which is where a
        // status indicator belongs — and above most app-drawn overlays too.
        panel.level = .statusBar
        // .canJoinAllSpaces: follow the user across Spaces instead of pinning to
        // the Space where dictation started. .fullScreenAuxiliary: appear over a
        // full-screen app. .stationary: do not slide during Mission Control.
        // .ignoresCycle: never appear in Cmd-` window cycling.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Suppress AppKit's default window fade — it is motion the user did not
        // ask for, and it delays the indicator on a fast press/release.
        panel.animationBehavior = .none

        self.panel = panel

        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let hosting = NSHostingView(rootView: HUDContentView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.hostingView = hosting

        installObservers()
        resize()
        reposition()
    }

    // `isolated deinit` (SE-0371) keeps teardown on the main actor. Without it
    // Swift 6 refuses to touch the non-Sendable observer tokens from a
    // nonisolated deinit — and these tokens must be released on the main thread
    // anyway, since that is the queue they were registered against.
    isolated deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
    }

    // MARK: - DictationHUD

    func show(_ state: DictationState) {
        dismissGeneration &+= 1

        model.state = state
        switch state {
        case .idle:
            hide()
            return

        case .recording(let startedAt):
            model.elapsed = Date().timeIntervalSince(startedAt)
            model.level = 0
            model.levelHistory = Array(repeating: 0, count: Self.meterBarCount)
            lastLevelAt = Date()
            startElapsedTimer(from: startedAt)

        case .transcribing:
            stopElapsedTimer()

        case .injecting:
            stopElapsedTimer()
            scheduleAutoDismiss(after: injectingAutoDismiss)

        case .failed:
            stopElapsedTimer()
            scheduleAutoDismiss(after: failureAutoDismiss)
        }

        resize()
        reposition()
        // orderFrontRegardless, never makeKeyAndOrderFront: it shows the panel
        // even though this app is not active, and takes no focus doing it.
        panel.orderFrontRegardless()
        isVisible = true
    }

    func setLevel(_ rms: Float) {
        guard isVisible else { return }
        lastLevelAt = Date()
        let clamped = min(max(rms, 0), 1)
        model.level = clamped
        pushLevelSample(clamped)
    }

    /// Shift one sample into the rolling history, oldest out on the left. The
    /// meter therefore scrolls like a waveform rather than redrawing in place.
    private func pushLevelSample(_ value: Float) {
        var history = model.levelHistory
        if history.isEmpty {
            history = Array(repeating: 0, count: Self.meterBarCount)
        }
        history.removeFirst()
        history.append(value)
        model.levelHistory = history
    }

    func hide() {
        dismissGeneration &+= 1
        stopElapsedTimer()
        isVisible = false
        panel.orderOut(nil)
        model.state = .idle
        model.level = 0
        model.elapsed = 0
    }

    // MARK: - Geometry

    /// Bottom-centre of the active screen. `visibleFrame` already subtracts the
    /// Dock and the menu bar (on whichever edge the user keeps them), so the
    /// "position above the Dock" requirement is satisfied by construction rather
    /// than by guessing the Dock's height.
    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.minY + bottomMargin).rounded())
        panel.setFrameOrigin(origin)
    }

    private func resize() {
        hostingView.layoutSubtreeIfNeeded()
        var size = hostingView.intrinsicContentSize
        if size.width <= 0 || size.height <= 0 { size = hostingView.fittingSize }
        guard size.width > 0, size.height > 0 else { return }
        panel.setContentSize(size)
    }

    // MARK: - Observers

    private func installObservers() {
        // Display reconfiguration: resolution change, laptop lid, a monitor
        // unplugged. Without this the HUD ends up off-screen or over the Dock.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
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
                self?.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    // MARK: - Timers

    private func startElapsedTimer(from startedAt: Date) {
        stopElapsedTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + elapsedTickInterval, repeating: elapsedTickInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.elapsed = Date().timeIntervalSince(startedAt)
                // If levels stop arriving (audio thread stalled, device being
                // swapped) drain the meter instead of leaving it frozen
                // mid-waveform — a frozen meter reads as "the app hung".
                // Samples are pushed through the same history the renderer
                // actually reads, so the decay is visible rather than notional.
                let stalled = Date().timeIntervalSince(self.lastLevelAt) > self.levelStallThreshold
                if stalled, (self.model.levelHistory.last ?? 0) > 0.001 || self.model.level > 0.001 {
                    self.model.level *= self.meterDecay
                    self.pushLevelSample((self.model.levelHistory.last ?? 0) * self.meterDecay)
                }
            }
        }
        timer.resume()
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }

    private func scheduleAutoDismiss(after delay: TimeInterval) {
        dismissGeneration &+= 1
        let generation = dismissGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dismissGeneration == generation else { return }
                self.hide()
            }
        }
    }
}

// MARK: - SwiftUI content

private struct HUDContentView: View {
    let model: HUDViewModel

    var body: some View {
        HStack(spacing: 10) {
            leading
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 180, maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
        .padding(6)   // room for the shadow inside the panel's own bounds
        .fixedSize()
    }

    // MARK: Leading glyph

    @ViewBuilder
    private var leading: some View {
        switch model.state {
        case .recording:
            RecordingDot(reduceMotion: model.reduceMotion)
        case .transcribing:
            if model.reduceMotion {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
            }
        case .injecting:
            Image(systemName: "text.cursor")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Body per state

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .recording:
            HStack(spacing: 10) {
                LevelMeter(history: model.levelHistory, reduceMotion: model.reduceMotion)
                    .frame(width: CGFloat(HUDPanel.meterBarCount) * 5, height: 18)
                Text(Self.formatElapsed(model.elapsed))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // Monospaced digits plus a fixed width stop the capsule from
                    // resizing every tenth of a second.
                    .frame(width: 44, alignment: .trailing)
            }
        case .transcribing:
            Text("Transcribing…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        case .injecting:
            Text("Inserting…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: 260, alignment: .leading)
        case .idle:
            EmptyView()
        }
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remainder = Int(seconds) % 60
            return String(format: "%d:%02d", minutes, remainder)
        }
        return String(format: "%.1fs", max(seconds, 0))
    }
}

/// The "live" indicator. The blink is the one piece of motion in this HUD that
/// carries information rather than decoration, so under Reduce Motion it is held
/// solid rather than removed — the user still sees that recording is active.
///
/// The repeat is driven from `@State` inside `withAnimation` rather than from a
/// `.animation(_:value:)` modifier: the surrounding view re-evaluates 10×/second
/// for the elapsed-time readout, and a value-driven repeating animation would be
/// restarted by each of those redraws.
private struct RecordingDot: View {
    let reduceMotion: Bool
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .opacity(dimmed ? 0.35 : 1.0)
            .onAppear { updateAnimation() }
            .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        guard !reduceMotion else {
            // Snap back to fully opaque and stop; no lingering repeat.
            withAnimation(.linear(duration: 0)) { dimmed = false }
            return
        }
        // 0.6 s per half-cycle: slow enough to read as a deliberate pulse rather
        // than an alarm, fast enough to be unmistakably alive.
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
            dimmed = true
        }
    }
}

/// Bar-graph level meter fed by a rolling history of linear RMS values.
private struct LevelMeter: View {
    let history: [Float]
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            let count = max(history.count, 1)
            let spacing: CGFloat = 1.5
            let barWidth = max((geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count), 1)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, value in
                    let height = max(CGFloat(Self.displayScale(value)) * geometry.size.height, 2)
                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: barWidth, height: height)
                        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }

    /// `AudioRecorder` publishes *linear* RMS on purpose, leaving perceptual
    /// shaping to the display layer — this is that layer.
    ///
    /// Conversational speech sits around 0.02–0.15 linear RMS, so a linear bar
    /// would hug the floor and look broken. Mapping through decibels with a
    /// −50 dBFS floor puts normal speech at roughly 30–75 % height, which is
    /// where a meter reads as responsive. −50 dB is also close to typical room
    /// noise, so silence sits at the bottom instead of shimmering.
    static func displayScale(_ rms: Float) -> Float {
        guard rms > 0.00001 else { return 0 }
        let db = 20 * log10(rms)
        let floorDB: Float = -50
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }
}
