import AppKit
import OpenFlowKit

/// Push-to-talk on a held modifier chord: hold to open the mic, release to
/// send. Watching `flagsChanged` rather than key codes means the chord cannot
/// collide with a shortcut the focused app already uses, and nothing is typed
/// while you hold it.
///
/// Uses `NSEvent` monitors rather than a `CGEventTap`. A tap looked like the
/// lower-level, more capable option, but `CGEvent.tapCreate` can hand back a
/// valid-looking port that never delivers a single event when the process is
/// not trusted -- failing silently and reporting success. The monitor pair is
/// the ordinary AppKit path and fails visibly instead.
///
/// **Two monitors are required.** A global monitor sees events only while
/// *other* apps are frontmost; a local monitor sees them only while ours is.
/// Installing just the global one gives a hotkey that works everywhere except
/// your own window; just the local one gives the opposite, which is what
/// happened here.
public extension ModifierChord {
    /// The bridge into AppKit. `ModifierChord` spells the bits out itself
    /// because OpenFlowKit is shared with iOS and cannot import AppKit; this is
    /// the one place that conversion is allowed to happen.
    var appKitFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mask) }
}

public final class HotkeyMonitor {
    /// Default: hold Control-Option.
    public var chord: NSEvent.ModifierFlags = [.control, .option]
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var poll: Timer?
    private var tracker: ChordTracker

    public init() {
        tracker = ChordTracker(mask: UInt(([.control, .option] as NSEvent.ModifierFlags).rawValue))
    }

    public static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Installs both monitors. Returns false only when the global monitor could
    /// not be installed, which means Accessibility permission is missing --
    /// the local monitor always works, so a `true` here is a real answer.
    @discardableResult
    public func start() -> Bool {
        stop()
        tracker = ChordTracker(mask: UInt(chord.rawValue))
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in
            self?.handle(event)
            return event
        }

        // Events give a fast press and release; polling makes it *correct*.
        // A `flagsChanged` release can be missed -- during app activation, or
        // while a system window is up -- and a missed release leaves `engaged`
        // stuck true, so the next press does nothing and the one after that
        // behaves like a toggle. Reconciling against the real modifier state
        // means a dropped event costs 60ms, not a broken hotkey.
        poll = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.reconcile(NSEvent.modifierFlags)
        }
        if let poll { RunLoop.main.add(poll, forMode: .common) }

        return globalMonitor != nil && AXIsProcessTrusted()
    }

    public func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        poll?.invalidate()
        poll = nil
        globalMonitor = nil
        localMonitor = nil
        tracker = ChordTracker(mask: UInt(chord.rawValue))
    }

    /// True while the chord is physically down, whatever the event stream did.
    public var isEngaged: Bool { tracker.isEngaged }

    deinit { stop() }

    private func handle(_ event: NSEvent) { reconcile(event.modifierFlags) }

    /// Single place where engaged/disengaged is decided, from whatever the
    /// current modifier state is. Both the event monitors and the poll go
    /// through here, so they cannot disagree.
    private func reconcile(_ raw: NSEvent.ModifierFlags) {
        if tracker.mask != UInt(chord.rawValue) {
            tracker = ChordTracker(mask: UInt(chord.rawValue))
        }
        let flags = raw.intersection(.deviceIndependentFlagsMask)
        switch tracker.update(flags: UInt(flags.rawValue)) {
        case .pressed:  onPress?()
        case .released: onRelease?()
        case .none:     break
        }
    }
}
