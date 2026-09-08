import AppKit
import SwiftUI

/// The window is closable and re-openable from the menu bar. The controller
/// outlives the window so reopening restores it rather than rebuilding state.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil { window = build() }
        guard let window else { return }
        model.refresh()
        // An accessory app has no Dock icon, so it must ask for focus
        // explicitly or the window opens behind whatever you were using.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "OpenFlow"
        w.contentView = NSHostingView(rootView: MainWindow(model: model))
        w.isReleasedWhenClosed = false      // closing hides; the menu reopens it
        w.center()
        w.setFrameAutosaveName("OpenFlowMain")
        w.delegate = self
        return w
    }
}
