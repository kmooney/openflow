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

// MARK: - microphone state
//
// Two facts, not one. "Live" is a microphone the keyboard can start a
// recording on from inside another app; "recording" is one already keeping
// audio. Collapsing them is what forced dictation to begin in the app.

extension HandoffTests {

    func testMicStateDefaultsToClosed() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(handoff.micState(), .closed)
        XCTAssertFalse(handoff.isLive())
        XCTAssertFalse(handoff.isRecording())
    }

    /// The state the whole design exists to represent: microphone open, not
    /// recording. The keyboard reads this as "I can start one from here".
    func testLiveWithoutRecording() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        handoff.setMic(live: true, recording: false)
        XCTAssertTrue(handoff.isLive())
        XCTAssertFalse(handoff.isRecording())
        XCTAssertNil(handoff.micState().startedAt)
        XCTAssertEqual(handoff.micState().elapsed, 0)
    }

    /// Elapsed time is derived from a start date rather than pushed as a
    /// number: the app is in the background while this matters and cannot be
    /// relied on to tick.
    func testElapsedComesFromTheStartDate() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        handoff.setMic(live: true, recording: true,
                       startedAt: Date().addingTimeInterval(-12))
        let state = handoff.micState()
        XCTAssertTrue(state.recording)
        XCTAssertEqual(state.elapsed, 12, accuracy: 1)
    }

    /// A recording that is not recording has no start date to leak into the
    /// keyboard's timer.
    func testStartDateIsClearedWhenNotRecording() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        handoff.setMic(live: true, recording: true)
        handoff.setMic(live: true, recording: false)
        XCTAssertNil(handoff.micState().startedAt)
    }

    /// If the app is killed mid-session nothing cleans the file up, and the
    /// keyboard would otherwise offer to finish a recording that no longer
    /// exists — forever.
    func testStaleStateReadsAsClosed() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        handoff.setMic(live: true, recording: true)
        XCTAssertTrue(handoff.isLive(staleAfter: 60))
        XCTAssertEqual(handoff.micState(staleAfter: -1), .closed,
                       "a heartbeat older than the timeout is not evidence of anything")
    }

    /// The heartbeat exists to keep a long, quiet session believable without
    /// pretending anything about it changed.
    func testHeartbeatRefreshesWithoutChangingState() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        handoff.setMic(live: true, recording: true,
                       startedAt: Date().addingTimeInterval(-30))
        let before = handoff.micState()
        Thread.sleep(forTimeInterval: 0.05)
        handoff.heartbeat()
        let after = handoff.micState()

        XCTAssertEqual(after.live, before.live)
        XCTAssertEqual(after.recording, before.recording)
        XCTAssertEqual(after.startedAt, before.startedAt,
                       "the timer must not restart every five seconds")
        XCTAssertGreaterThan(after.updatedAt, before.updatedAt)
    }

    /// Nothing to refresh is not an error, and must not invent a session.
    func testHeartbeatOnNothingStaysClosed() throws {
        let (handoff, dir) = try makeHandoff()
        defer { try? FileManager.default.removeItem(at: dir) }

        handoff.heartbeat()
        XCTAssertEqual(handoff.micState(), .closed)
    }

    /// Each request is a distinct channel: a keyboard asking to start must
    /// never be heard as a keyboard asking to stop.
    func testRequestChannelsAreDistinct() {
        let start = expectation(description: "start")
        let stop = expectation(description: "stop")
        stop.isInverted = true

        let startToken = Handoff.observeStartRequests { start.fulfill() }
        let stopToken = Handoff.observeStopRequests { stop.fulfill() }
        defer {
            Handoff.removeObserver(startToken)
            Handoff.removeObserver(stopToken)
        }

        Handoff.requestStart()
        wait(for: [start, stop], timeout: 2)
    }
}
