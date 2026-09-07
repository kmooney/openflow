import AppKit
import AVFoundation
import Combine
import OpenFlowKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private var model: AppModel!
    private var windowController: MainWindowController!
    private var bag = Set<AnyCancellable>()
    private var frontApp: String?
    private var hotkeyReady = false

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenFlow", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(idle: true)

        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let store = try? Store(path: dir.appendingPathComponent("history.sqlite").path) else {
            return fatal("Could not open the history database in \(dir.path).")
        }
        guard let modelURL = Self.resolveModel() else {
            return fatal("""
            No Whisper model found.

            Put ggml-small.en.bin in:
            \(dir.appendingPathComponent("models").path)

            (clients/build-macos.sh downloads and links one.)
            """)
        }

        let engine = DictationEngine(modelPath: modelURL.path, store: store)
        engine.vocabulary = Vocabulary.load(from: dir.appendingPathComponent("vocab.txt"))
        engine.supportDirectory = dir
        engine.warmUp()

        model = AppModel(engine: engine, store: store)
        model.onRequestAccessibility = { [weak self] in self?.openAccessibilitySettings() }
        windowController = MainWindowController(model: model)

        // Menu bar mirrors the model rather than keeping its own copy.
        model.$state.sink { [weak self] in self?.render($0) }.store(in: &bag)
        model.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.buildMenu() } }
            .store(in: &bag)

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard !granted else { return }
            DispatchQueue.main.async {
                self.notify("Microphone access denied",
                            "OpenFlow can't hear you. Enable it in System Settings › Privacy & Security › Microphone.")
            }
        }

        hotkey.onPress = { [weak self] in
            guard let self else { return }
            // Capture focus before recording: the status item must not steal it.
            self.frontApp = Paster.frontmostApp
            self.model.begin()
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            self.model.finish(.paste(appContext: self.frontApp))
        }

        setUpHotkey()

        buildMenu()
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            windowController.show()
        }
    }

    // MARK: - accessibility

    /// Install the hotkey, asking for permission only if we actually need it.
    ///
    /// The authoritative test is whether the event tap installs -- not what
    /// `AXIsProcessTrusted()` reports. Trusting that check is what made the app
    /// prompt on every launch even when permission had already been granted.
    private func setUpHotkey() {
        if hotkey.start() {
            hotkeyReady = true
            model?.hotkeyReady = true
            return
        }
        // Genuinely not permitted. Show the system prompt once, then wait for
        // the grant rather than demanding a relaunch -- the user is already in
        // System Settings, and making them quit and reopen is gratuitous.
        HotkeyMonitor.requestAccessibilityPermission()
        waitForPermission()
    }

    private func waitForPermission(attempt: Int = 0) {
        guard attempt < 180 else {          // ~3 minutes, then stop nagging
            notify("OpenFlow can't hear the hotkey",
                   """
                   Grant Accessibility permission in System Settings › Privacy \
                   & Security › Accessibility, then choose Open OpenFlow from \
                   the menu bar.
                   """)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.hotkeyReady else { return }
            if self.hotkey.start() {
                self.hotkeyReady = true
                self.model?.hotkeyReady = true
                self.model?.status = "Hotkey ready — hold ⌃⌥ to talk"
                self.buildMenu()
                return
            }
            self.waitForPermission(attempt: attempt + 1)
        }
    }

    // MARK: - status item

    private func render(_ state: DictationState) {
        switch state {
        case .recording:
            setIcon(idle: false)
        case .thinking:
            statusItem.button?.title = " …"
        case .idle, .failed:
            setIcon(idle: true)
            statusItem.button?.title = ""
        }
    }

    private func setIcon(idle: Bool) {
        guard let b = statusItem.button else { return }
        b.image = NSImage(systemSymbolName: idle ? "mic" : "mic.fill",
                          accessibilityDescription: "OpenFlow")
        b.contentTintColor = idle ? nil : .systemRed
    }

    private func buildMenu() {
        guard let model else { return }
        let s = model.stats
        let menu = NSMenu()

        add(menu, "Open OpenFlow", #selector(openWindow), key: "o")
        menu.addItem(.separator())
        menu.addItem(header("\(s.spokenWords.formatted()) words spoken · \(s.todayWords.formatted()) today"))
        menu.addItem(header("\(s.utterances) utterances · \(Int(s.secondsSpoken / 60)) min of speech"))
        menu.addItem(.separator())
        if hotkeyReady {
            menu.addItem(header("Hold ⌃⌥ to talk, release to paste"))
        } else {
            add(menu, "⚠︎ Grant Accessibility permission…", #selector(openAccessibilitySettings))
        }
        menu.addItem(.separator())

        for t in Tone.allCases {
            let i = NSMenuItem(title: t.name, action: #selector(pickTone(_:)), keyEquivalent: "")
            i.target = self
            i.state = (t == model.tone) ? .on : .off
            i.tag = Int(t.rawValue)
            menu.addItem(i)
        }
        menu.addItem(.separator())
        let audio = NSMenuItem(title: "Keep Audio for Debugging",
                               action: #selector(toggleKeepAudio), keyEquivalent: "")
        audio.target = self
        audio.state = model.keepAudio ? .on : .off
        menu.addItem(audio)
        add(menu, "Edit Vocabulary…", #selector(openVocab))
        add(menu, "Quit OpenFlow", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    private func header(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        menu.addItem(i)
    }

    // MARK: - actions

    @objc private func openWindow() { windowController.show() }

    @objc private func pickTone(_ sender: NSMenuItem) {
        model.tone = Tone(rawValue: UInt32(sender.tag)) ?? .formal
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        waitForPermission()
    }

    @objc private func toggleKeepAudio() {
        model.keepAudio.toggle()
        buildMenu()
    }

    @objc private func openVocab() {
        let url = Self.supportDir.appendingPathComponent("vocab.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? """
            # Words OpenFlow should expect: names, places, jargon.
            # One per line. Lines starting with # are ignored.
            # Whisper's prompt caps around 224 tokens, so keep the most-used first.
            """.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.model.reloadVocabulary(from: url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func notify(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    private func fatal(_ message: String) {
        notify("OpenFlow can't start", message)
        NSApp.terminate(nil)
    }

    private static func resolveModel() -> URL? {
        let dir = supportDir.appendingPathComponent("models")
        return ["ggml-small.en.bin", "ggml-base.en.bin", "ggml-large-v3-turbo.bin"]
            .map { dir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
