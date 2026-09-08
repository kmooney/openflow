import UIKit
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
    private let status = UILabel()
    private var micButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        handoff = Handoff(appGroup: OpenFlowIDs.appGroup)
        // Only possible with Full Access, so it doubles as the app's signal
        // that the keyboard is actually usable.
        if hasFullAccess { handoff?.markKeyboardReady() }
        buildKeyboard()
        observer = Handoff.observe { [weak self] in
            DispatchQueue.main.async { self?.insertPendingIfAny() }
        }
    }

    deinit {
        if let observer { Handoff.removeObserver(observer) }
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
            // iOS will not let a backgrounded app start the microphone, so
            // this key cannot begin a recording however much we would like it
            // to. It says what actually works instead of offering something
            // that silently fails.
            status.text = "Dictate in the OpenFlow app — your text arrives here"
            setMic(symbol: "arrow.up.forward.app", title: " Open OpenFlow")
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
            // The key has to stop looking tappable. It used to keep saying
            // "Finish" and stay enabled, so the obvious reading of a slow
            // transcription was that the tap had not registered -- and each
            // extra tap posted another stop request.
            micButton.isEnabled = false
            setMic(symbol: "ellipsis", title: " Working")
            // A transcription that fails posts no notification at all, so
            // nothing would ever re-enable the key. Recover on a timer rather
            // than leaving it dead until the keyboard is dismissed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, !self.micButton.isEnabled else { return }
                self.refreshState()
            }
            return
        }
        if handoff?.hasPending == true {
            insertPendingIfAny()
            return
        }
        openContainingApp()
    }

    /// Ask iOS to bring the app forward, then tell the truth about it.
    ///
    /// Measured on iOS 26: `extensionContext.open` returns false, and the
    /// undocumented responder-chain `openURL:` walk finds a responder, calls
    /// it, and nothing happens. Both routes are dead for keyboard extensions.
    ///
    /// They are still *attempted*, because the cost is nothing and the rule
    /// has moved between releases before, but neither is allowed to claim
    /// success: the old code said "Opening OpenFlow…" the instant the chain
    /// accepted the selector, which looked exactly like success while the user
    /// sat on an unchanged screen.
    private func openContainingApp() {
        let url = OpenFlowIDs.dictateURL
        extensionContext?.open(url, completionHandler: nil)
        attemptResponderChain(url)
        status.text = hasFullAccess
            ? "Open OpenFlow and tap its microphone. Come back here and your text lands where the cursor is."
            : "Open OpenFlow to turn on Full Access, then this keyboard can receive your text."
    }

    /// An extension has no `UIApplication`, so walk the responder chain for
    /// anything that implements `openURL:`. Undocumented, and no longer
    /// effective; kept only because it costs nothing to try.
    private func attemptResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
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
        let space = key(title: "space", action: #selector(spaceTapped))
        let ret = key(title: "return", action: #selector(returnTapped))

        let bottom = UIStackView(arrangedSubviews: [globe, space, del, ret])
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
