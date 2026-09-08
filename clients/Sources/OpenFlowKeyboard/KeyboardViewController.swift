import UIKit
import AVFoundation
import OpenFlowKit

/// The OpenFlow keyboard.
///
/// It deliberately does almost nothing. **A keyboard extension cannot use the
/// microphone** — that is a platform rule, not a difficulty — and extensions
/// run under a memory ceiling far below what a Whisper model needs. So this is
/// a microphone *button* and a text sink: the app records and transcribes, and
/// the keyboard inserts what it finds waiting.
///
/// Insertion happens whenever the keyboard appears, not only when it is woken
/// by a notification. That matters because the usual path is the user switching
/// back from the app by hand, at which point no notification is delivered — the
/// keyboard simply looks for pending text every time it comes on screen.
final class KeyboardViewController: UIInputViewController {

    private var handoff: Handoff?
    private var observer: NSObjectProtocol?
    private var stopObserver: NSObjectProtocol?
    private let status = UILabel()
    private var micButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        handoff = Handoff(appGroup: OpenFlowIDs.appGroup)
        // Only possible with Full Access, so it doubles as the app's signal
        // that the keyboard is actually usable.
        if hasFullAccess { handoff?.markKeyboardReady() }
        buildKeyboard()
        stopObserver = Handoff.observe { [weak self] in
            DispatchQueue.main.async { self?.insertPendingIfAny() }
        }
        observer = Handoff.observe { [weak self] in
            DispatchQueue.main.async { self?.insertPendingIfAny() }
        }
    }

    deinit {
        if let observer { Handoff.removeObserver(observer) }
        if let stopObserver { Handoff.removeObserver(stopObserver) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshState()
        insertPendingIfAny()
    }

    // MARK: - handoff

    private func insertPendingIfAny() {
        guard hasFullAccess else { return }
        guard let pending = handoff?.take() else { return }
        textDocumentProxy.insertText(pending.text)
        flash("Inserted \(pending.text.split(separator: " ").count) words")
    }

    private func refreshState() {
        micButton.isEnabled = true
        guard hasFullAccess else {
            // "Allow Full Access" means nothing to anyone who has not read
            // Apple's documentation. Say what it is for, promise what it is
            // not for, and offer to walk them there.
            status.text = "OpenFlow needs permission to receive your dictated text.\nTap to set it up — nothing is ever sent off your device."
            setMic(symbol: "gear", title: " Set up")
            return
        }
        if handoff?.isRecording() == true {
            status.text = "Listening in the OpenFlow app — tap to finish and insert"
            setMic(symbol: "stop.circle.fill", title: " Finish")
        } else if handoff?.hasPending == true {
            status.text = "Text ready — tap to insert"
            setMic(symbol: "text.insert", title: " Insert")
        } else {
            status.text = "Tap to dictate"
            setMic(symbol: "mic.fill", title: nil)
        }
    }

    private func setMic(symbol: String, title: String?) {
        var config = micButton.configuration
        config?.image = UIImage(systemName: symbol)
        config?.title = title
        micButton.configuration = config
    }

    private func flash(_ message: String) {
        status.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshState()
        }
    }

    // MARK: - actions

    @objc private func micTapped() {
        // Without Full Access the container is unreachable, so the only useful
        // thing the key can do is take the user somewhere they can fix it.
        guard hasFullAccess else { openContainingApp(); return }

        if handoff?.isRecording() == true {
            // The app is listening in the background. Ask it to stop; the
            // transcript arrives by notification and is inserted below.
            Handoff.requestStop()
            status.text = "Transcribing…"
            return
        }
        if handoff?.hasPending == true {
            insertPendingIfAny()
            return
        }
        // If the app is alive in the background it can start recording without
        // being brought forward -- no app switch at all, which is better than
        // flipping even when flipping works.
        if handoff?.appIsAlive() == true {
            Handoff.requestStart()
            status.text = "Listening… tap to finish"
            setMic(symbol: "stop.circle.fill", title: " Finish")
            return
        }
        openContainingApp()
    }

    /// Open the app so it can record.
    ///
    /// Three routes, tried in order, because which of them works has moved
    /// between iOS releases and the failure is silent either way. The status
    /// label reports which one succeeded so this stops being guesswork.
    private func openContainingApp() {
        let url = OpenFlowIDs.dictateURL

        // 1. The documented API. Apple says a keyboard extension gets `false`
        //    here, but that is worth testing rather than assuming.
        if let ctx = extensionContext {
            ctx.open(url) { [weak self] opened in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if opened {
                        self.flash("Opening OpenFlow…")
                    } else {
                        self.openViaResponderChain(url)
                    }
                }
            }
            return
        }
        openViaResponderChain(url)
    }

    /// An extension has no `UIApplication`, so walk the responder chain for
    /// anything that implements `openURL:`. Undocumented, and the route that
    /// several shipping dictation keyboards rely on.
    private func openViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                flash("Opening OpenFlow… (chain)")
                return
            }
            responder = r.next
        }
        // Nothing in the chain took it. Say what to do rather than failing mute.
        status.text = "Open the OpenFlow app once, then this key works from anywhere."
    }

    /// DIAGNOSTIC: what can a keyboard extension actually do here?
    ///
    /// Reports microphone capture, whether the app is reachable in the
    /// background, and how much memory this extension is holding — the three
    /// unknowns the architecture depends on, answered in one tap.
    @objc private func micCheckTapped() {
        guard hasFullAccess else { status.text = "needs Full Access first"; return }
        status.text = "testing…"
        let alive = handoff?.appIsAlive() == true
        let recorder = AudioRecorder()
        do {
            try recorder.start()
        } catch {
            status.text = "MIC BLOCKED: \(error.localizedDescription) · app alive: \(alive)"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let samples = recorder.stop()
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            let mem = Self.residentMB()
            let mic: String
            if samples.isEmpty { mic = "MIC BLOCKED (no buffers)" }
            else if peak == 0 { mic = "MIC SILENT (\(samples.count) zeros)" }
            else { mic = String(format: "MIC OK peak %.3f", peak) }
            self.status.text = "\(mic) · app alive: \(alive) · mem \(mem)MB"
        }
    }

    /// Resident memory of this extension, which is what the jetsam limit
    /// actually watches.
    private static func residentMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size)
            / mach_msg_type_number_t(MemoryLayout<natural_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ok == KERN_SUCCESS ? Int(info.phys_footprint / 1024 / 1024) : -1
    }

    @objc private func deleteTapped() { textDocumentProxy.deleteBackward() }
    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") }

    // MARK: - layout

    private func buildKeyboard() {
        view.backgroundColor = .clear

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabel
        status.textAlignment = .center
        status.numberOfLines = 2
        status.adjustsFontSizeToFitWidth = true

        micButton = key(systemImage: "mic.fill", action: #selector(micTapped),
                        prominent: true)
        let globe = key(systemImage: "globe", action: #selector(handleInputModeList(from:with:)))
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)),
                        for: .allTouchEvents)
        let del = key(systemImage: "delete.left", action: #selector(deleteTapped))
        let micCheck = key(systemImage: "stethoscope", action: #selector(micCheckTapped))
        let space = key(title: "space", action: #selector(spaceTapped))
        let ret = key(title: "return", action: #selector(returnTapped))

        let bottom = UIStackView(arrangedSubviews: [globe, micCheck, space, del, ret])
        bottom.axis = .horizontal
        bottom.spacing = 6
        bottom.distribution = .fillProportionally
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [status, micButton, bottom])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            micButton.heightAnchor.constraint(equalToConstant: 64),
            bottom.heightAnchor.constraint(equalToConstant: 42),
        ])
    }

    private func key(title: String? = nil, systemImage: String? = nil,
                     action: Selector, prominent: Bool = false) -> UIButton {
        var config = prominent ? UIButton.Configuration.filled()
                               : UIButton.Configuration.gray()
        config.title = title
        if let systemImage { config.image = UIImage(systemName: systemImage) }
        config.cornerStyle = .medium
        let b = UIButton(configuration: config)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }
}
