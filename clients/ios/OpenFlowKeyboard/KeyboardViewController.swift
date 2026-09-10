import UIKit
import SwiftUI
import OpenFlowKit

/// The OpenFlow keyboard.
///
/// **A keyboard extension cannot use the microphone** — that is a platform
/// rule, not a difficulty — and extensions run under a memory ceiling far
/// below what a Whisper model needs. So the app records and transcribes, and
/// this is the control surface.
///
/// It can nonetheless *start* a recording, which used to be impossible, and
/// the reason is worth stating plainly: the app no longer opens the microphone
/// per recording. It opens it once, in the foreground, and holds it. iOS
/// forbids a backgrounded app from *beginning* capture; it has never forbidden
/// one from continuing. So this key does not start a microphone — it asks an
/// already-running one to start keeping what it hears.
///
/// The cost is honest and visible: the system recording indicator stays lit,
/// and the app really is holding the microphone, for as long as the session is
/// open. That is the trade the design makes, and the reason there is a key
/// here to close it.
final class KeyboardViewController: UIInputViewController {

    private var handoff: Handoff?
    private var observers: [NSObjectProtocol] = []
    private let status = UILabel()
    private var micButton: UIButton!
    private var sideButton: UIButton!
    /// Hosts `OpenAppKey`. A child view controller because a `Link` only works
    /// as a real SwiftUI view in a real hierarchy — see `OpenAppKey` for why it
    /// cannot be a `UIButton` like every other key here.
    private var openAppKey: UIHostingController<OpenAppKey>!
    /// Tone is "a per-utterance choice, not a setting" by its own definition,
    /// so it belongs where the utterance happens rather than in an app the user
    /// left several minutes ago.
    private var tonePicker: UISegmentedControl!
    /// Runs only while the keyboard is on screen. Drives the elapsed counter
    /// and picks up state the Darwin notification missed.
    private var poll: Timer?
    /// What we asked the app for and are still waiting to see confirmed.
    ///
    /// Carries *what would count as confirmation*, not just a deadline. The
    /// first version carried only a deadline and outranked the shared state
    /// file until it expired — so a recording that had already started 10 ms
    /// ago still showed a greyed-out key for the remaining 1.5 seconds. The
    /// user was waiting on this timeout, not on the microphone.
    private enum Awaiting { case starting, finishing }
    private var pendingRequest: (kind: Awaiting, label: String, symbol: String,
                                 since: Date, until: Date)?

    /// Whether this instance is the keyboard actually on screen.
    ///
    /// iOS keeps keyboard extension instances alive across host apps, and the
    /// transcript observer below lives as long as the instance — not as long as
    /// it is visible. So an instance left over from an app used earlier would
    /// wake on the notification, `take()` the transcript (which deletes it),
    /// and insert into its own dead `textDocumentProxy`. The keyboard the user
    /// was looking at then found nothing waiting, and the text existed only in
    /// the app's history.
    ///
    /// `take()` is one-shot by design, so exactly one instance may be allowed
    /// to call it: the visible one.
    private var isVisible = false

    /// Identifies this instance among however many iOS is keeping alive. Only
    /// the instance that most recently appeared may consume a transcript.
    private let instanceToken = UUID().uuidString

    override func viewDidLoad() {
        super.viewDidLoad()
        handoff = Handoff(appGroup: OpenFlowIDs.appGroup)
        // Only possible with Full Access, so it doubles as the app's signal
        // that the keyboard is actually usable.
        if hasFullAccess { handoff?.markKeyboardReady() }
        buildKeyboard()
        observers.append(Handoff.observe { [weak self] in
            DispatchQueue.main.async { self?.insertPendingIfAny() }
        })
        // The app posts this on every transition. Without it the keyboard only
        // learns about a finished transcription on its next poll, which reads
        // as a lag between tapping the key and anything happening.
        observers.append(Handoff.observeStateChanges { [weak self] in
            DispatchQueue.main.async { self?.refreshState() }
        })
        observers.append(Handoff.observeToneChanges { [weak self] in
            DispatchQueue.main.async { self?.refreshTone() }
        })
    }

    deinit {
        for o in observers { Handoff.removeObserver(o) }
        poll?.invalidate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        refreshTone()
        lastClaim = Date()
        handoff?.claimKeyboard(instanceToken)
        refreshState()
        insertPendingIfAny()
        startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        stopPolling()
    }

    /// A file read every 250 ms, only while visible. Cheap, and it is the only
    /// thing that can show a running seconds count: the app is in the
    /// background and cannot push one.
    private func startPolling() {
        stopPolling()
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshClaim()
            self.refreshState()
        }
    }

    /// Keep this instance's claim alive while it is on screen, so a claim left
    /// by an instance that never came back ages out instead of blocking
    /// insertion forever. Throttled: the poll runs four times a second and this
    /// does not need to.
    private var lastClaim = Date.distantPast
    private func refreshClaim() {
        guard isVisible, Date().timeIntervalSince(lastClaim) > 1 else { return }
        lastClaim = Date()
        handoff?.claimKeyboard(instanceToken)
    }

    private func stopPolling() { poll?.invalidate(); poll = nil }

    // MARK: - handoff

    private func insertPendingIfAny() {
        guard hasFullAccess else { return }
        // Never consume on behalf of a keyboard nobody can see. An off-screen
        // instance that takes the transcript destroys it: reading deletes, and
        // its text proxy goes nowhere. The visible instance picks it up on the
        // notification, or on its next `viewWillAppear` if it was not running
        // when the notification fired.
        guard isVisible else { return }
        // Belt and braces: an abandoned instance may never be told it
        // disappeared, so being on screen is claimed rather than assumed.
        guard handoff?.isCurrentKeyboard(instanceToken) == true else { return }
        guard let pending = handoff?.take() else { return }
        textDocumentProxy.insertText(pending.text)
        pendingRequest = nil
        flash("Inserted \(pending.text.split(separator: " ").count) words")
    }

    private func refreshState() {
        guard hasFullAccess else {
            // "Allow Full Access" means nothing to anyone who has not read
            // Apple's documentation. Say what it is for, promise what it is
            // not for, and offer to walk them there.
            micButton.isEnabled = true
            showOpenAppKey(false)
            status.text = "OpenFlow needs permission to receive your dictated text.\nTap to set it up — nothing is ever sent off your device."
            setMic(symbol: "gear", title: " Set up")
            setSide(nil)
            return
        }

        let mic = handoff?.micState() ?? .closed

        // A request we are still waiting on outranks the state file — but only
        // until the state file shows the thing we asked for. Confirmation, not
        // expiry, is what ends the wait.
        if pendingRequest != nil { showOpenAppKey(false) }
        if let request = pendingRequest {
            // A failure ends it immediately too. Otherwise the key sat on
            // "Working" for the full timeout after the app had already given
            // up, which is indistinguishable from a tap that never registered.
            if let failure = handoff?.takeFailure() {
                pendingRequest = nil
                flash(failure)
                return
            }
            let confirmed: Bool
            switch request.kind {
            case .starting:
                confirmed = mic.recording
            case .finishing:
                // Deliberately never confirmed here. The app clears `recording`
                // the moment it stops, which is *before* it has transcribed
                // anything — treating that as confirmation flipped the key back
                // to "Speak" while the words were still being worked out. What
                // ends this wait is the transcript arriving (which clears it in
                // `insertPendingIfAny`), a failure, or the deadline.
                confirmed = false
            }
            if confirmed {
                pendingRequest = nil
            } else if Date() < request.until {
                switch request.kind {
                case .starting:
                    // Starting is a flag flip against a microphone that is
                    // already running, so it is drawn as started at once. Not
                    // blind optimism: it is checked every poll and reverts with
                    // a reason if the app does not confirm.
                    micButton.isEnabled = true
                    status.text = String(format: "● Listening  %.0fs",
                                         Date().timeIntervalSince(request.since))
                    setMic(symbol: "checkmark", title: " Insert")
                    setSide("xmark")
                case .finishing:
                    // Transcribing genuinely takes most of a second, and there
                    // is nothing to show but that it is happening.
                    micButton.isEnabled = false
                    status.text = request.label
                    setMic(symbol: request.symbol, title: " Working")
                    setSide(nil)
                }
                return
            } else {
                // Timed out. Fall through to whatever is actually true.
                pendingRequest = nil
            }
        }

        micButton.isEnabled = true
        showOpenAppKey(false)

        if mic.recording {
            status.text = String(format: "● Listening  %.0fs", mic.elapsed)
            setMic(symbol: "checkmark", title: " Insert")
            setSide("xmark")
            return
        }
        if handoff?.hasPending == true {
            status.text = "Text ready — tap to insert"
            setMic(symbol: "text.insert", title: " Insert")
            setSide(nil)
            return
        }
        if mic.live {
            // The whole reason this design exists. The microphone is already
            // running, so this key can begin a recording without the app ever
            // coming forward.
            status.text = "Microphone open — tap and speak"
            setMic(symbol: "mic.fill", title: " Speak")
            setSide("mic.slash")
            return
        }
        // No session, and a backgrounded app cannot open the microphone — so
        // the only useful thing here is a way back to the app. That is the one
        // key that is not a UIButton: see `OpenAppKey`.
        status.text = "Open OpenFlow to switch the microphone on. After that you can stay here."
        showOpenAppKey(true)
        setSide(nil)
    }

    /// What each key currently shows. The poll runs four times a second to
    /// move the seconds counter; reassigning a `UIButton.Configuration` that
    /// often re-lays-out the key for nothing and makes the label shimmer.
    private var renderedMic: String?
    private var renderedSide: String?

    private func setMic(symbol: String, title: String?) {
        let key = "\(symbol)|\(title ?? "")"
        guard renderedMic != key else { return }
        renderedMic = key
        var config = micButton.configuration
        config?.image = UIImage(systemName: symbol)
        config?.title = title
        micButton.configuration = config
    }

    /// The secondary key: discard while recording, close the microphone while
    /// merely open, nothing otherwise. Hidden rather than disabled — a key
    /// that means something different in each state should not sit there
    /// greyed out inviting a guess.
    private func setSide(_ symbol: String?) {
        guard renderedSide != symbol else { return }
        renderedSide = symbol
        guard let symbol else { sideButton.isHidden = true; return }
        sideButton.isHidden = false
        var config = sideButton.configuration
        config?.image = UIImage(systemName: symbol)
        sideButton.configuration = config
    }

    /// Swap the microphone key for the one that can actually open the app.
    /// They occupy the same slot: only one of them is ever the right thing to
    /// offer, and showing both would ask the user to choose between a key that
    /// works and one that cannot.
    private func showOpenAppKey(_ show: Bool) {
        guard openAppKey.view.isHidden == show else { return }
        openAppKey.view.isHidden = !show
        micButton.isHidden = show
    }

    private func flash(_ message: String) {
        status.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshState()
        }
    }

    /// Note a request we have posted and are waiting on. The window is the
    /// honest one: transcription of a long utterance takes seconds on a phone.
    private func awaiting(_ kind: Awaiting, _ label: String,
                          symbol: String = "ellipsis", seconds: TimeInterval) {
        pendingRequest = (kind, label, symbol, Date(),
                          Date().addingTimeInterval(seconds))
        refreshState()
    }

    // MARK: - actions

    @objc private func micTapped() {
        // Without Full Access the container is unreachable, so the only useful
        // thing the key can do is take the user somewhere they can fix it.
        guard hasFullAccess else { openContainingApp(); return }

        let mic = handoff?.micState() ?? .closed

        // During the optimistic start window the key already reads Insert, so a
        // tap means finish — even though the state file may not have caught up.
        if mic.recording || pendingRequest?.kind == .starting {
            // The app is listening in the background. Ask it to stop; the
            // transcript arrives by notification and is inserted above.
            Handoff.requestStop()
            awaiting(.finishing, "Transcribing…", seconds: 20)
            return
        }
        if handoff?.hasPending == true {
            insertPendingIfAny()
            return
        }
        if mic.live {
            Handoff.requestStart()
            // Short window. Starting is a flag flip against a running graph, so
            // it is confirmed in milliseconds; the deadline exists only to
            // catch the case where the app is gone.
            awaiting(.starting, "Starting…", symbol: "mic", seconds: 1.5)
            return
        }
        openContainingApp()
    }

    @objc private func sideTapped() {
        guard hasFullAccess else { return }
        let mic = handoff?.micState() ?? .closed
        if mic.recording {
            Handoff.requestCancel()
            flash("Discarded")
        } else if mic.live {
            Handoff.requestClose()
            flash("Microphone closed")
        }
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
    /// Nothing here opens the app any more — the SwiftUI `Link` key does that,
    /// because it is the only thing that still can. This is only reached when
    /// the key is tapped without Full Access, where the container is
    /// unreachable and there is nothing useful to offer but an explanation.
    private func openContainingApp() {
        status.text = "Open OpenFlow to turn on Full Access, then this keyboard can receive your text."
    }

    /// Show whatever the app last recorded, so the two surfaces never disagree
    /// about which register the next utterance will be written in.
    private func refreshTone() {
        guard hasFullAccess, let tone = handoff?.tone() else { return }
        let index = Tone.allCases.firstIndex(of: tone) ?? 0
        if tonePicker.selectedSegmentIndex != index {
            tonePicker.selectedSegmentIndex = index
        }
    }

    @objc private func toneChanged() {
        guard hasFullAccess else { return }
        let picked = Tone.allCases[tonePicker.selectedSegmentIndex]
        handoff?.setTone(picked)
        // The app applies this on its next transcription; nothing here has to
        // wait for it, so say so immediately rather than leaving the tap
        // looking unregistered.
        flash("\(picked.name) — applies to the next dictation")
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
        sideButton = key(systemImage: "xmark", action: #selector(sideTapped))
        sideButton.isHidden = true

        openAppKey = UIHostingController(rootView: OpenAppKey())
        openAppKey.view.backgroundColor = .clear
        openAppKey.view.isHidden = true
        addChild(openAppKey)

        let primary = UIStackView(arrangedSubviews: [micButton, openAppKey.view, sideButton])
        primary.axis = .horizontal
        primary.spacing = 6
        sideButton.widthAnchor.constraint(equalToConstant: 56).isActive = true

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

        openAppKey.didMove(toParent: self)

        tonePicker = UISegmentedControl(items: Tone.allCases.map(\.name))
        tonePicker.selectedSegmentIndex = 0
        tonePicker.setTitleTextAttributes(
            [.font: UIFont.systemFont(ofSize: 12)], for: .normal)
        tonePicker.addTarget(self, action: #selector(toneChanged), for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [status, tonePicker, primary, bottom])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            tonePicker.heightAnchor.constraint(equalToConstant: 30),
            primary.heightAnchor.constraint(equalToConstant: 64),
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
