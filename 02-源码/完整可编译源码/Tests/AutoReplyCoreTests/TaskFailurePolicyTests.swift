import XCTest
@testable import AutoReplyCore

final class TaskFailurePolicyTests: XCTestCase {
    func testFirstRetryableUIFailureMovesAttemptToTail() {
        XCTAssertEqual(TaskFailurePolicy.uiDisposition(previousFailures: 0), .requeueTail)
    }

    func testSecondRetryableUIFailureParksAttempt() {
        XCTAssertEqual(TaskFailurePolicy.uiDisposition(previousFailures: 1), .park)
    }
}
