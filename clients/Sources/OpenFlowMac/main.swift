import AppKit

// AppDelegate is @MainActor; top-level code is not, so enter the actor
// explicitly rather than letting the isolation be inferred.
@MainActor
func run() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu-bar only: no Dock icon, no main window at launch.
    app.setActivationPolicy(.accessory)
    // Keep the delegate alive for the process lifetime.
    withExtendedLifetime(delegate) { app.run() }
}

MainActor.assumeIsolated { run() }
