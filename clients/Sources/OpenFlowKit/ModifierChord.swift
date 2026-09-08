import Foundation

/// The held-modifier combination that opens the microphone.
///
/// Modifiers only, by design: `HotkeyMonitor` watches `flagsChanged` rather
/// than key codes, so the chord cannot collide with a shortcut the focused app
/// already owns and nothing is typed while you hold it. That is also why this
/// is a bitmask rather than a key code -- it is the same value `ChordTracker`
/// reconciles against.
///
/// Raw values match `NSEvent.ModifierFlags` so the mask can cross into AppKit
/// untouched; they are spelled out here because OpenFlowKit is shared with iOS
/// and must not import AppKit.
public struct ModifierChord: Equatable, Hashable, Sendable, Codable {
    public static let shift: UInt    = 1 << 17
    public static let control: UInt  = 1 << 18
    public static let option: UInt   = 1 << 19
    public static let command: UInt  = 1 << 20
    public static let function: UInt = 1 << 23

    /// Caps lock is deliberately absent: it latches, so "held" has no meaning.
    public static let allowedMask = shift | control | option | command | function

    /// Control-Option. Rarely held on its own, on any keyboard layout, which
    /// is the whole requirement.
    public static let `default` = ModifierChord(mask: control | option)

    public let mask: UInt

    public init(mask: UInt) { self.mask = mask & Self.allowedMask }

    public var count: Int { mask.nonzeroBitCount }

    /// A single modifier fires the moment you reach for any ordinary shortcut,
    /// so one is never enough. Two is the floor the UI enforces.
    public var isUsable: Bool { count >= 2 }

    /// Command and Shift are held constantly while using an app normally --
    /// ⌘⇧Z, ⌘⇧4, holding Shift to select text. A chord built from them works,
    /// but it will also open the microphone by accident, so the UI says so.
    public var isCollisionProne: Bool { mask & (Self.command | Self.shift) != 0 }

    /// Apple's canonical order: fn ⌃ ⌥ ⇧ ⌘.
    public var symbols: String {
        Self.ordered.filter { mask & $0.0 != 0 }.map(\.1).joined()
    }

    /// "Control-Option", for places where glyphs would not read aloud.
    public var name: String {
        Self.ordered.filter { mask & $0.0 != 0 }.map(\.2).joined(separator: "-")
    }

    private static let ordered: [(UInt, String, String)] = [
        (function, "fn", "Function"),
        (control, "⌃", "Control"),
        (option, "⌥", "Option"),
        (shift, "⇧", "Shift"),
        (command, "⌘", "Command"),
    ]
}
