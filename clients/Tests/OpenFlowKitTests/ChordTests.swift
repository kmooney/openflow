import XCTest
@testable import OpenFlowKit

final class ChordTests: XCTestCase {
    // Matching NSEvent.ModifierFlags raw values
    private let control: UInt = 1 << 18
    private let option: UInt = 1 << 19
    private let command: UInt = 1 << 20
    private var chord: UInt { control | option }

    func testHoldAndRelease() {
        var t = ChordTracker(mask: chord)
        XCTAssertEqual(t.update(flags: control), .none, "half the chord is not the chord")
        XCTAssertEqual(t.update(flags: chord), .pressed)
        XCTAssertEqual(t.update(flags: chord), .none, "still held is not a new press")
        XCTAssertEqual(t.update(flags: control), .released, "letting go of either key releases")
        XCTAssertEqual(t.update(flags: 0), .none)
    }

    /// The bug that made it behave like a toggle: a release event goes missing,
    /// so the next press is swallowed and every press after that is inverted.
    /// Reconciling against current state must recover on the next update.
    func testARecoveredMissedReleaseDoesNotInvertTheHotkey() {
        var t = ChordTracker(mask: chord)
        XCTAssertEqual(t.update(flags: chord), .pressed)
        // release event never arrives; the poll sees the true state instead
        XCTAssertEqual(t.update(flags: 0), .released)
        XCTAssertEqual(t.update(flags: chord), .pressed, "the next hold must still work")
        XCTAssertEqual(t.update(flags: 0), .released)
    }

    func testExtraModifiersDoNotBreakTheChord() {
        var t = ChordTracker(mask: chord)
        XCTAssertEqual(t.update(flags: chord | command), .pressed,
                       "holding an extra key must not prevent the chord")
        XCTAssertEqual(t.update(flags: chord), .none)
    }

    func testNeverToggles() {
        // whatever sequence arrives, pressed and released must alternate
        var t = ChordTracker(mask: chord)
        var last: ChordTracker.Transition = .released
        for flags in [chord, chord, 0, 0, chord, control, chord, 0, chord, 0] as [UInt] {
            let r = t.update(flags: flags)
            if r != .none {
                XCTAssertNotEqual(r, last, "two \(r) in a row — that is a toggle, not push-to-talk")
                last = r
            }
        }
    }
}
