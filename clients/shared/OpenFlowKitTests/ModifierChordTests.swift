import XCTest
@testable import OpenFlowKit

final class ModifierChordTests: XCTestCase {
    func testTheDefaultIsControlOption() {
        XCTAssertEqual(ModifierChord.default.symbols, "⌃⌥")
        XCTAssertEqual(ModifierChord.default.name, "Control-Option")
        XCTAssertTrue(ModifierChord.default.isUsable)
        XCTAssertFalse(ModifierChord.default.isCollisionProne)
    }

    /// One modifier fires the moment you reach for any ordinary shortcut.
    func testOneModifierIsNotAChord() {
        XCTAssertFalse(ModifierChord(mask: ModifierChord.control).isUsable)
        XCTAssertFalse(ModifierChord(mask: 0).isUsable)
        XCTAssertTrue(ModifierChord(mask: ModifierChord.control | ModifierChord.shift).isUsable)
    }

    func testSymbolsUseAppleOrderWhateverOrderTheBitsArrive() {
        let all = ModifierChord(mask: ModifierChord.command | ModifierChord.control
                                | ModifierChord.shift | ModifierChord.option
                                | ModifierChord.function)
        XCTAssertEqual(all.symbols, "fn⌃⌥⇧⌘")
        XCTAssertEqual(all.name, "Function-Control-Option-Shift-Command")
    }

    func testCommandAndShiftAreFlaggedAsCollisionProne() {
        // Held constantly during ⌘⇧Z, ⌘⇧4, or any shift-selection.
        XCTAssertTrue(ModifierChord(mask: ModifierChord.command | ModifierChord.option)
                        .isCollisionProne)
        XCTAssertTrue(ModifierChord(mask: ModifierChord.shift | ModifierChord.control)
                        .isCollisionProne)
        XCTAssertFalse(ModifierChord(mask: ModifierChord.control | ModifierChord.option)
                        .isCollisionProne)
    }

    /// Caps lock latches, so "held" is meaningless; anything else that is not
    /// a modifier has no business in the mask either.
    func testStrayBitsAreDiscardedOnTheWayIn() {
        let capsLock: UInt = 1 << 16
        let chord = ModifierChord(mask: ModifierChord.control | ModifierChord.option
                                  | capsLock | (1 << 30))
        XCTAssertEqual(chord, ModifierChord.default)
        XCTAssertEqual(chord.count, 2)
    }

    func testItSurvivesBeingStoredAndReadBack() throws {
        let chord = ModifierChord(mask: ModifierChord.control | ModifierChord.command)
        let data = try JSONEncoder().encode(chord)
        XCTAssertEqual(try JSONDecoder().decode(ModifierChord.self, from: data), chord)
    }

    /// The mask is handed straight to ChordTracker, so the two must agree.
    func testTheMaskDrivesTheTrackerDirectly() {
        var tracker = ChordTracker(mask: ModifierChord.default.mask)
        XCTAssertEqual(tracker.update(flags: ModifierChord.control), .none)
        XCTAssertEqual(tracker.update(flags: ModifierChord.default.mask), .pressed)
        XCTAssertEqual(tracker.update(flags: 0), .released)
    }
}
