import AppKit
import SwiftUI

/// Preferences live in their own window rather than a sheet on the main one:
/// the model list is reachable from the menu bar, and a sheet would have
/// forced the history window open behind it to show it.
@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show(_ tab: PreferencesTab) {
        // Rebuilt per showing so it opens on the requested tab; the state it
        // edits lives in AppModel, so there is nothing to preserve here.
        window?.close()
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        w.title = "OpenFlow Settings"
        w.contentView = NSHostingView(rootView: PreferencesWindow(model: model, tab: tab))
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        window = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
