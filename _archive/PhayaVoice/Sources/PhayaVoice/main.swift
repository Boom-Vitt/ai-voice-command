import AppKit
import OSLog

/// PhayaVoice — hold Right-Option, speak, and the text lands in whatever
/// text field currently has focus.
///
/// There is deliberately no window and no settings UI. The whole product is a
/// menubar item and a hotkey.
/// Unambiguous launch tracing to a file. OSLog .info is memory-only and was
/// invisible to `log show`, which made a working app look like a dead one.
func trace(_ msg: String) {
    let line = "\(Date().formatted(date: .omitted, time: .standard))  \(msg)\n"
    if let d = line.data(using: .utf8) {
        let u = URL(fileURLWithPath: "/tmp/pv_trace.txt")
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: u) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.boombignose.phayavoice", category: "App")

    private var hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let injector = TextInjector()
    private let hud = HUDPanel()
    private let floater = FloatingButton()
    private let transcriber = LocalTranscriber()

    private var statusItem: NSStatusItem?
    private var busy = false
    private var lastTranscript = ""
    private var serverReady = false
    private var permissionTimer: Timer?
    private var axGranted = false
    private var micGranted = false

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        trace("applicationDidFinishLaunching")
        buildStatusItem()
        trace("statusItem=\(statusItem != nil) visible=\(statusItem?.isVisible ?? false)")
        trace("ACCESSIBILITY granted = \(hotkey.permissionGranted())")

        wireHotkey()

        // The floating button is the second way in, and on this machine the
        // primary one: the menubar is full, so the status icon hides behind the
        // notch. Both routes call the same begin/end pair.
        floater.onActivate = { [weak self] in self?.beginDictation() }
        floater.onDeactivate = { [weak self] in self?.endDictation() }
        applyFloatingButtonVisibility()

        recorder.levelHandler = { [weak self] rms in
            self?.hud.setLevel(rms)
            self?.floater.setLevel(rms)
        }

        // Permissions: ask up front so the first dictation is not the thing that
        // fails. Accessibility cannot be granted programmatically — we can only
        // open the pane and tell the user why.
        axGranted = hotkey.permissionGranted()
        if !axGranted {
            _ = hotkey.requestPermission()
            presentAccessibilityNotice()
        }
        hotkey.start()
        trace("hotkey tap installed = \(hotkey.isHealthy)  key=\(Self.keyName(Settings.shared.hotkeyKeyCode))")
        startPermissionWatcher()

        Task {
            let mic = await AudioRecorder.requestMicrophoneAccess()
            micGranted = mic
            trace("MICROPHONE granted = \(mic)")
            await recorder.prewarm()          // ~2.5s cold vs ~68ms warm; never on the hot path
            await startServer()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        recorder.idle()
        Task { await WhisperServerManager.shared.stop() }
    }

    /// macOS grants Accessibility while the app is already running, and the
    /// event tap installed before the grant never receives events. Polling and
    /// reinstalling removes the "quit and relaunch" dance entirely.
    private func startPermissionWatcher() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheckPermissions() }
        }
    }

    /// Re-read both permissions; rebuild the hotkey tap if Accessibility just
    /// arrived. Safe to call repeatedly — it only acts on a transition.
    @objc func recheckPermissions() {
        let ax = hotkey.permissionGranted()
        if ax != axGranted {
            axGranted = ax
            trace("ACCESSIBILITY changed -> \(ax)")
            if ax {
                // Reinstall: a tap created before the grant is inert.
                hotkey.stop()
                hotkey = HotkeyMonitor(keyCode: Settings.shared.hotkeyKeyCode == 0
                                       ? 61 : Settings.shared.hotkeyKeyCode)
                wireHotkey()
                hotkey.start()
                trace("hotkey REINSTALLED after grant, healthy=\(hotkey.isHealthy)")
                setStatus(title: serverReady ? "Ready" : "Loading model…",
                          symbol: serverReady ? "mic" : "mic.badge.xmark")
                showState(.failed("Accessibility granted — ready to dictate"))
            } else {
                setStatus(title: "Needs Accessibility", symbol: "mic.slash")
            }
        }
        if !micGranted {
            Task { [weak self] in
                let m = await AudioRecorder.requestMicrophoneAccess()
                if m, let self, !self.micGranted {
                    self.micGranted = true
                    trace("MICROPHONE changed -> true")
                }
            }
        }
        if !axGranted {
            setStatus(title: "Needs Accessibility", symbol: "mic.slash")
        }
    }

    private func startServer() async {
        setStatus(title: "Loading model…", symbol: "mic.badge.xmark")
        do {
            try await WhisperServerManager.shared.ensureReady(timeout: 120)
            serverReady = true
            trace("ENGINE ready")
            setStatus(title: "Ready", symbol: "mic")
            log.info("whisper-server ready")
        } catch {
            serverReady = false
            setStatus(title: "Engine unavailable", symbol: "mic.slash")
            log.error("whisper-server failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - dictation

    private func beginDictation() {
        trace(">>> HOTKEY DOWN")
        guard !busy else { return }
        guard axGranted else {
            showState(.failed("Grant Accessibility in System Settings"))
            recheckPermissions()
            return
        }
        guard serverReady else {
            showState(.failed("Speech engine still starting"))
            return
        }
        if injector.secureInputActive() {
            // A password field or a Cursor/Terminal leak is holding Secure Event
            // Input. Injection would silently fail, so refuse loudly instead.
            showState(.failed("Secure input active — can't type here"))
            return
        }
        busy = true
        recorder.startCapture()
        showState(.recording(startedAt: Date()))
        setStatus(title: "Listening…", symbol: "mic.fill")
    }

    private func endDictation() {
        trace("<<< HOTKEY UP")
        guard busy else { return }
        showState(.transcribing)
        setStatus(title: "Transcribing…", symbol: "waveform")

        Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }

            guard let wav = await recorder.stopCapture() else {
                showState(.failed("No audio captured"))
                setStatus(title: "Ready", symbol: "mic")
                return
            }
            defer { try? FileManager.default.removeItem(at: wav) }

            let req = TranscriptionRequest(
                audioURL: wav,
                language: Settings.shared.language,
                glossary: GlossaryProvider.current(frontmost: injector.frontmostAppInfo())
            )
            let result = await transcriber.transcribe(req)

            guard result.ok else {
                showState(.failed(result.error ?? "Transcription failed"))
                setStatus(title: "Ready", symbol: "mic")
                return
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                hideState()
                setStatus(title: "Ready", symbol: "mic")
                return
            }
            lastTranscript = text
            trace("TRANSCRIPT (\(result.latencyMS)ms): \(text)")
            log.info("transcribed \(text.count, privacy: .public) chars in \(result.latencyMS, privacy: .public)ms")

            showState(.injecting)
            if let reason = injector.inject(text) {
                trace("INJECT FAILED: \(reason)")
                // Injection failed, but the words are not lost — park them on the
                // clipboard so the user can paste manually.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showState(.failed("\(reason) — copied to clipboard instead"))
            } else {
                hideState()
            }
            setStatus(title: "Ready", symbol: "mic")
        }
    }

    /// One call site for both indicators so they can never disagree.
    private func showState(_ state: DictationState) {
        hud.show(state)
        floater.setState(state)
    }

    private func hideState() {
        hud.hide()
        floater.setState(.idle)
    }

    // MARK: - menubar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A title as well as the glyph: if the symbol ever fails to load, an
        // image-only item collapses to zero width and the app looks like it
        // never launched. The title guarantees the item is always findable.
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "PhayaVoice")
        item.button?.image?.isTemplate = true   // adapts to light/dark menubar
        item.behavior = []                      // never let the user hide it accidentally
        item.isVisible = true

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Hold \(Self.keyName(Settings.shared.hotkeyKeyCode == 0 ? 61 : Settings.shared.hotkeyKeyCode)) to dictate", action: nil, keyEquivalent: ""))
        menu.items.first?.isEnabled = false
        menu.addItem(.separator())

        let langItem = NSMenuItem(title: "Language: \(Settings.shared.language == "th" ? "Thai" : "English")",
                                  action: #selector(toggleLanguage), keyEquivalent: "")
        langItem.target = self
        menu.addItem(langItem)

        let hkItem = NSMenuItem(title: "Dictation key", action: nil, keyEquivalent: "")
        let hkMenu = NSMenu()
        let current = Settings.shared.hotkeyKeyCode == 0 ? 61 : Settings.shared.hotkeyKeyCode
        for choice in Self.hotkeyChoices {
            let mi = NSMenuItem(title: choice.name, action: #selector(chooseHotkey(_:)), keyEquivalent: "")
            mi.target = self; mi.tag = Int(choice.code)
            mi.state = (choice.code == current) ? .on : .off
            hkMenu.addItem(mi)
        }
        hkItem.submenu = hkMenu
        menu.addItem(hkItem)

        let fbItem = NSMenuItem(title: "Show floating button", action: #selector(toggleFloatingButton(_:)), keyEquivalent: "")
        fbItem.target = self
        fbItem.state = (UserDefaults.standard.object(forKey: "showFloatingButton") as? Bool ?? true) ? .on : .off
        menu.addItem(fbItem)

        let recheckItem = NSMenuItem(title: "Re-check permissions",
                                     action: #selector(recheckPermissions), keyEquivalent: "")
        recheckItem.target = self
        menu.addItem(recheckItem)

        let copyItem = NSMenuItem(title: "Copy last transcript", action: #selector(copyLast), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())
        let diagItem = NSMenuItem(title: "Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagItem.target = self
        menu.addItem(diagItem)

        let quitItem = NSMenuItem(title: "Quit PhayaVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    private func setStatus(title: String, symbol: String) {
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        statusItem?.button?.image?.isTemplate = true
        statusItem?.isVisible = true
        statusItem?.button?.toolTip = "PhayaVoice — \(title)"
        statusItem?.menu?.items.first?.title = title == "Ready"
            ? "Hold \(Self.keyName(Settings.shared.hotkeyKeyCode == 0 ? 61 : Settings.shared.hotkeyKeyCode)) to dictate" : title
    }

    /// The nine modifier keys HotkeyMonitor can watch. F-keys are deliberately
    /// absent: the tap listens on .flagsChanged, which only modifiers emit.
    static let hotkeyChoices: [(name: String, code: UInt16)] = [
        ("Right Option  ⌥", 61), ("Left Option  ⌥", 58),
        ("Right Command  ⌘", 54), ("Left Command  ⌘", 55),
        ("Right Control  ⌃", 62), ("Left Control  ⌃", 59),
        ("Right Shift  ⇧", 60), ("Left Shift  ⇧", 56),
        ("Fn / Globe  🌐", 63),
    ]

    static func keyName(_ code: UInt16) -> String {
        hotkeyChoices.first { $0.code == code }?.name ?? "Right Option  ⌥"
    }

    /// Show or hide the floating button per the user's preference (default on).
    private func applyFloatingButtonVisibility() {
        if UserDefaults.standard.object(forKey: "showFloatingButton") as? Bool ?? true {
            floater.show()
        } else {
            floater.hide()
        }
    }

    private func wireHotkey() {
        hotkey.onPressStart = { [weak self] in self?.beginDictation() }
        hotkey.onPressEnd = { [weak self] in self?.endDictation() }
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        let code = UInt16(sender.tag)
        UserDefaults.standard.set(Int(code), forKey: "hotkeyKeyCode")
        // Rebuild the monitor: the keyCode is fixed at init.
        hotkey.stop()
        hotkey = HotkeyMonitor(keyCode: code)
        wireHotkey()
        hotkey.start()
        trace("hotkey rebound to \(Self.keyName(code)) installed=\(hotkey.isHealthy)")
        if let menu = sender.menu {
            for i in menu.items { i.state = (i.tag == sender.tag) ? .on : .off }
        }
        statusItem?.button?.toolTip = "PhayaVoice — hold \(Self.keyName(code))"
    }

    @objc private func toggleFloatingButton(_ sender: NSMenuItem) {
        let show = !(UserDefaults.standard.object(forKey: "showFloatingButton") as? Bool ?? true)
        UserDefaults.standard.set(show, forKey: "showFloatingButton")
        sender.state = show ? .on : .off
        applyFloatingButtonVisibility()
    }

    @objc private func toggleLanguage() {
        let next = Settings.shared.language == "th" ? "en" : "th"
        UserDefaults.standard.set(next, forKey: "language")
        statusItem?.menu?.items.first(where: { $0.title.hasPrefix("Language:") })?
            .title = "Language: \(next == "th" ? "Thai" : "English")"
    }

    @objc private func copyLast() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    @objc private func showDiagnostics() {
        Task { @MainActor in
            let diag = await WhisperServerManager.shared.diagnostics()
            let alert = NSAlert()
            alert.messageText = "PhayaVoice diagnostics"
            alert.informativeText = """
                Accessibility: \(hotkey.permissionGranted() ? "granted" : "NOT granted")
                Hotkey tap:    \(hotkey.isHealthy ? "healthy" : "not installed")
                Secure input:  \(injector.secureInputActive() ? "ACTIVE (typing blocked)" : "clear")
                Engine ready:  \(serverReady ? "yes" : "no")

                \(diag)
                """
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    private func presentAccessibilityNotice() {
        let alert = NSAlert()
        alert.messageText = "PhayaVoice needs Accessibility permission"
        alert.informativeText = """
            Without it PhayaVoice cannot see the Right-Option hotkey or type into \
            other apps.

            Open System Settings > Privacy & Security > Accessibility and enable \
            PhayaVoice, then relaunch.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Placeholder for the context-aware glossary. Today it returns whatever the
/// user configured; the moat is filling this from the frontmost app, the current
/// git branch, and identifiers in the open buffer.
enum GlossaryProvider {
    static func current(frontmost: (name: String, bundleID: String)?) -> [String] {
        UserDefaults.standard.stringArray(forKey: "glossary") ?? []
    }
}

trace("--- top-level code start ---")
let app = NSApplication.shared
let delegate = AppDelegate()
trace("delegate constructed")
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menubar only: no Dock icon, no window
trace("about to run(); delegate set = \(app.delegate != nil)")
app.run()
