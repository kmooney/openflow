import XCTest
@testable import OpenFlowKit

final class HandoffTests: XCTestCase {

    /// No implicitly-unwrapped properties: with an IUO base, `XCTAssertNil`
    /// resolves against the optional itself rather than the call's result.
    private func makeHandoff() throws -> (Handoff, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("of-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (Handoff(directory: dir), dir)
    }

    func testOfferThenTake() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(handoff.take())
        try handoff.offer("Meet me at Larchmont at noon.", tone: .formal)
        XCTAssertTrue(handoff.hasPending)

        let p: PendingTranscript = try XCTUnwrap(handoff.take())
        XCTAssertEqual(p.text, "Meet me at Larchmont at noon.")
        XCTAssertEqual(p.tone, "Formal")
    }

    /// Reading consumes. Inserting the same sentence twice into someone's
    /// message is a worse failure than missing it once.
    func testTakeIsOneShot() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        try handoff.offer("hello", tone: .casual)
        XCTAssertNotNil(handoff.take())
        XCTAssertNil(handoff.take(), "a transcript must never be delivered twice")
        XCTAssertFalse(handoff.hasPending)
    }

    /// If the user gave up and went elsewhere, the text is no longer wanted.
    func testStaleTranscriptsAreDiscarded() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        let stale = PendingTranscript(text: "old news", tone: "Formal",
                                      createdAt: Date().addingTimeInterval(-600))
        try JSONEncoder().encode(stale).write(to: dir.appendingPathComponent("pending.json"))

        XCTAssertNil(handoff.take(maxAge: 180), "stale text must not be inserted")
        XCTAssertFalse(handoff.hasPending, "and it must be cleared, not left to rot")
    }

    func testCorruptFileIsIgnoredAndCleared() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("not json".utf8).write(to: dir.appendingPathComponent("pending.json"))
        XCTAssertNil(handoff.take())
        XCTAssertFalse(handoff.hasPending)
    }

    func testLatestOfferWins() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        try handoff.offer("first", tone: .formal)
        try handoff.offer("second", tone: .formal)
        XCTAssertEqual(handoff.take()?.text, "second")
    }

    func testNotificationRoundTrip() {
        let fired = expectation(description: "darwin notification")
        let token = Handoff.observe { fired.fulfill() }
        defer { Handoff.removeObserver(token) }
        Handoff.postNotification()
        wait(for: [fired], timeout: 2)
    }
}
