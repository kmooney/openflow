import AppKit
import CoreGraphics

/// Put text on the clipboard and paste it into whatever has focus.
///
/// Insertion strategy is deliberately the simple one: clipboard plus a
/// synthesized Cmd-V works in essentially every app, including Electron and
/// terminals, where direct Accessibility insertion is inconsistent. The cost is
/// that we borrow the pasteboard for a moment, so we put the old contents back.
public enum Paster {
    public static func paste(_ text: String, restoreAfter: TimeInterval = 0.45) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Wait for the chord to physically lift before synthesizing Cmd-V.
        //
        // A posted keystroke picks up whatever modifiers are actually held, so
        // firing while Control-Option is still down delivers Ctrl-Opt-Cmd-V --
        // which almost nothing binds, so the paste simply does not happen. A
        // fixed delay was a guess at how fast someone lets go; this waits for
        // the real state instead.
        waitForModifiersToClear {
            sendCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreAfter) {
                guard let saved else { return }
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    /// Poll until no modifiers are held, then run `body`. Gives up after a
    /// second and pastes anyway -- a user genuinely resting on a modifier
    /// should still get their text.
    private static func waitForModifiersToClear(attempt: Int = 0,
                                                _ body: @escaping () -> Void) {
        let interesting: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
        let held = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(interesting)
        if held.isEmpty || attempt > 40 {
            // One runloop turn after the last modifier lifts, so the frontmost
            // app has processed the key-up before the paste arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: body)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            waitForModifiersToClear(attempt: attempt + 1, body)
        }
    }

    private static func sendCommandV() {
        // A private source does not inherit the hardware modifier state, so
        // the synthesized event carries exactly the flags set below.
        let src = CGEventSource(stateID: .privateState)
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Bundle id of whatever is focused, for per-app tone defaults and history.
    public static var frontmostApp: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
