import AppKit
import ApplicationServices
import OpenFlowKit

/// Reads what has focus right now: which app, and which field inside it.
///
/// This runs on the hotkey press, immediately before the microphone opens, so
/// it has a hard constraint the rest of the app does not -- it must never
/// block. An Accessibility query is a synchronous IPC round-trip into another
/// process, and a busy or hung app can sit on it for the default six seconds,
/// which would swallow the beginning of the utterance. Every query below is
/// capped, and every failure degrades to the app-wide answer rather than
/// stopping anything.
enum FocusInspector {
    /// How long we will wait on another process before giving up on the field
    /// and keeping just the app. Long enough for a healthy app answering in
    /// single-digit milliseconds, short enough that a wedged one is not our
    /// problem.
    private static let timeout: Float = 0.2

    static func current() -> DictationContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
        let base = DictationContext(bundleID: app.bundleIdentifier, appName: app.localizedName)

        // Without Accessibility permission the focused-element query returns
        // an API-disabled error for every app. Skip it: the app-wide answer is
        // still correct and still useful.
        guard AXIsProcessTrusted() else { return base }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, timeout)
        guard let focused = element(axApp, kAXFocusedUIElementAttribute) else { return base }
        AXUIElementSetMessagingTimeout(focused, timeout)

        let field = FieldKind.classify(
            role: string(focused, kAXRoleAttribute),
            subrole: string(focused, kAXSubroleAttribute),
            hints: [
                string(focused, kAXIdentifierAttribute),
                string(focused, kAXDescriptionAttribute),
                string(focused, kAXTitleAttribute),
                string(focused, kAXPlaceholderValueAttribute),
                // Chrome and Electron apps often leave the field itself
                // anonymous and name the group around it.
                element(focused, kAXParentAttribute).flatMap {
                    string($0, kAXDescriptionAttribute)
                },
            ])

        return DictationContext(bundleID: app.bundleIdentifier,
                                appName: app.localizedName,
                                field: field)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
