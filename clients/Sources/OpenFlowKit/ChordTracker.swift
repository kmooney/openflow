import Foundation

/// Decides press/release for a held modifier chord from raw flag bitmasks.
///
/// Extracted from the hotkey monitor so it can be tested without AppKit: this
/// logic has produced two user-visible bugs (a stuck `engaged` flag behaving
/// like a toggle) and deserves coverage rather than trust.
///
/// It is deliberately *state-reconciling* rather than event-counting — every
/// caller passes the current flags and gets back what changed. A dropped event
/// therefore corrects itself on the next update instead of inverting the
/// hotkey for the rest of the session.
public struct ChordTracker {
    public enum Transition: Equatable, Sendable {
        case none, pressed, released
    }

    public let mask: UInt
    private var engaged = false

    public init(mask: UInt) { self.mask = mask }

    public var isEngaged: Bool { engaged }

    public mutating func update(flags: UInt) -> Transition {
        let held = (flags & mask) == mask
        if held && !engaged {
            engaged = true
            return .pressed
        }
        if !held && engaged {
            engaged = false
            return .released
        }
        return .none
    }
}
