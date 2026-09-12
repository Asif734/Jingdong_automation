import CoreGraphics
import XCTest
@testable import UnreadCore

final class IdentityPendingTrackerTests: XCTestCase {
    private let unresolved = ConversationCandidate(
        nodeID: 45,
        frame: CGRect(x: 64, y: 282, width: 202, height: 34),
        identity: .unresolved(labels: [])
    )

    func testUnchangedUnresolvedDotRetriesTwiceThenParksAndSuppresses() {
        var tracker = IdentityPendingTracker(maximumAttempts: 2, maximumAge: 10)
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(tracker.observe(dotted: [unresolved], now: start).map(\.disposition), [.retry(attempt: 1)])
        XCTAssertEqual(tracker.observe(dotted: [unresolved], now: start.addingTimeInterval(1)).map(\.disposition), [.retry(attempt: 2)])
        XCTAssertEqual(tracker.observe(dotted: [unresolved], now: start.addingTimeInterval(2)).map(\.disposition), [.park])
        XCTAssertEqual(tracker.observe(dotted: [unresolved], now: start.addingTimeInterval(3)).map(\.disposition), [.suppressed])
    }

    func testTenSecondAgeParksEvenBeforeAttemptBudgetIsExhausted() {
        var tracker = IdentityPendingTracker(maximumAttempts: 10, maximumAge: 10)
        let start = Date(timeIntervalSince1970: 100)
        _ = tracker.observe(dotted: [unresolved], now: start)

        XCTAssertEqual(tracker.observe(dotted: [unresolved], now: start.addingTimeInterval(10)).map(\.disposition), [.park])
    }

    func testDotDisappearanceOrChangedEvidenceStartsFreshAttempt() {
        var tracker = IdentityPendingTracker(maximumAttempts: 1, maximumAge: 10)
        let start = Date(timeIntervalSince1970: 100)
        _ = tracker.observe(dotted: [unresolved], now: start)
        XCTAssertEqual(tracker.observe(dotted: [unresolved], now: start.addingTimeInterval(1)).map(\.disposition), [.park])

        XCTAssertTrue(tracker.observe(dotted: [], now: start.addingTimeInterval(2)).isEmpty)
        XCTAssertEqual(tracker.observe(dotted: [unresolved], now: start.addingTimeInterval(3)).map(\.disposition), [.retry(attempt: 1)])

        let changed = ConversationCandidate(nodeID: 45, frame: unresolved.frame,
                                            identity: .unresolved(labels: ["new evidence"]))
        XCTAssertEqual(tracker.observe(dotted: [changed], now: start.addingTimeInterval(4)).map(\.disposition), [.retry(attempt: 1)])
    }

    func testResolvedCandidateNeverCreatesIdentityPendingAttempt() {
        var tracker = IdentityPendingTracker()
        let resolved = ConversationCandidate(nodeID: 45, frame: unresolved.frame,
                                             identity: .full(uid: "stoneshishininger", nickname: nil))
        XCTAssertTrue(tracker.observe(dotted: [resolved], now: Date()).isEmpty)
    }
}
