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
    private var preferences: PreferencesWindowController!
    private var bag = Set<AnyCancellable>()
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
        // No model is no longer fatal. It used to be, which meant the only way
        // to get one was a shell script -- so the app quit at launch rather
        // than offering the download it is perfectly capable of doing.
        let models = ModelStore(directory: dir.appendingPathComponent("models"),
                                defaultID: "small.en")
        let engine = DictationEngine(modelPath: models.activeURL?.path ?? "", store: store)
        engine.supportDirectory = dir
        engine.warmUp()
        models.onSelectionChanged = { [weak engine] url in engine?.useModel(at: url.path) }

        model = AppModel(engine: engine, store: store, models: models)
        model.reloadVocabulary(from: dir.appendingPathComponent("vocab.txt"))
        model.onRequestAccessibility = { [weak self] in self?.openAccessibilitySettings() }
        windowController = MainWindowController(model: model)
        preferences = PreferencesWindowController(model: model)
        model.onShowPreferences = { [weak self] tab in self?.preferences.show(tab) }
        model.onEditVocabulary = { [weak self] in self?.openVocab() }

        // Menu bar mirrors the model rather than keeping its own copy.
        model.$state.sink { [weak self] in self?.render($0) }.store(in: &bag)
        model.$elapsed.sink { [weak self] in self?.showElapsed($0) }.store(in: &bag)
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
            // Read focus before recording: the status item must not steal it,
            // and by the time the utterance ends the field may be gone.
            self.model.begin(in: FocusInspector.current())
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            self.model.finish(.paste)
        }

        hotkey.chord = model.chord.appKitFlags
        model.onChordChanged = { [weak self] chord in
            guard let self else { return }
            self.hotkey.chord = chord.appKitFlags
            // start() re-installs both monitors; a false here means the grant
            // is gone, not that the new chord is bad.
            self.hotkeyReady = self.hotkey.start()
            self.model.hotkeyReady = self.hotkeyReady
            self.buildMenu()
        }

        setUpHotkey()
        followFrontmostApp()

        buildMenu()
        if models.activeURL == nil {
            // Nothing to transcribe with: open on the one screen that fixes it
            // rather than failing at the first press of the hotkey.
            model.status = "No speech model yet — pick one to download."
            model.showPreferences(.model)
        } else if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            windowController.show()
        }
    }

    // MARK: - context

    /// Track the frontmost app so the menu bar shows the register you are
    /// about to get, before you hold the key. Field-level detail waits for the
    /// press -- polling the focused element continuously would be an
    /// Accessibility round-trip into another process several times a second,
    /// for a label.
    private func followFrontmostApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  // Our own window is where the user *corrects* the tone, so
                  // activating it must leave the context they are correcting
                  // in place.
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            MainActor.assumeIsolated {
                self.model?.adopt(DictationContext(bundleID: app.bundleIdentifier,
                                                   appName: app.localizedName))
            }
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
                self.model?.status = "Hotkey ready — hold \(self.model?.chord.symbols ?? "") to talk"
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
            showElapsed(0)          // don't wait for the first tick to appear
        case .thinking:
            statusItem.button?.title = " …"
        // `.open` is an iOS state: the Mac opens the microphone per recording
        // rather than holding it, so it never rests there — and if it somehow
        // did, an idle icon is the honest drawing of it.
        case .idle, .open, .failed:
            setIcon(idle: true)
            statusItem.button?.title = ""
        }
    }

    /// Count up next to the icon while the chord is held, so the length of
    /// what you are about to send is visible without opening anything.
    ///
    /// Monospaced digits deliberately: a proportional font re-measures the
    /// title ten times a second, and the whole menu bar shuffles sideways as
    /// the tenths roll over.
    private func showElapsed(_ seconds: TimeInterval) {
        guard let button = statusItem.button, model?.isRecording == true else { return }
        button.attributedTitle = NSAttributedString(
            string: String(format: " %.1fs", seconds),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                        weight: .regular),
            ])
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
            menu.addItem(header("Hold \(model.chord.symbols) to talk, release to paste"))
        } else {
            add(menu, "⚠︎ Grant Accessibility permission…", #selector(openAccessibilitySettings))
        }
        menu.addItem(.separator())

        menu.addItem(header(model.toneExplanation))
        for t in Tone.allCases {
            let i = NSMenuItem(title: t.name, action: #selector(pickTone(_:)), keyEquivalent: "")
            i.target = self
            i.state = (t == model.tone) ? .on : .off
            i.tag = Int(t.rawValue)
            menu.addItem(i)
        }
        if model.toneIsRemembered {
            add(menu, "Forget Tone for \(model.context.label)", #selector(forgetTone))
        }
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openPreferences), key: ",")
        add(menu, "Speech Model: \(model.activeModelName)…", #selector(openModels))
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
        model.chooseTone(Tone(rawValue: UInt32(sender.tag)) ?? .formal)
    }

    @objc private func forgetTone() { model.forgetTone() }

    @objc private func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        waitForPermission()
    }

    @objc private func openModels() { model.showPreferences(.model) }

    @objc private func openPreferences() { model.showPreferences(.general) }

    @objc func openVocab() {
        let url = Self.supportDir.appendingPathComponent("vocab.txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? """
            # Words OpenFlow should expect: names, places, jargon.
            # One per line. Lines starting with # are ignored.
            # Whisper's prompt caps around 224 tokens, so keep the most-used first.

            # Terms above any [section] apply everywhere. A [bundle.id] header
            # starts a list used only while that app has focus -- which is how
            # you get "git status" in a terminal instead of "get status".
            # OpenFlow shows the bundle id of the app you last dictated into in
            # Settings > Vocabulary.

            # [com.apple.Terminal]
            # git status
            # kubectl
            # ssh
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
}
