import Foundation
import XCTest
@testable import AutoReplyCore

final class OperationDeadlineTests: XCTestCase {
    private actor Latch {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testFastOperationReturnsBeforeDeadline() async throws {
        let value = try await withOperationDeadline(.milliseconds(200), stage: "test") { 7 }
        XCTAssertEqual(value, 7)
    }

    func testDeadlineReturnsEvenWhenOperationDoesNotObserveCancellation() async {
        let latch = Latch()
        let started = ContinuousClock.now

        do {
            _ = try await withOperationDeadline(.milliseconds(30), stage: "ocr") {
                await latch.wait()
                return 1
            }
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? OperationTimeout, OperationTimeout(stage: "ocr"))
            XCTAssertLessThan(started.duration(to: .now), .milliseconds(200))
        }

        await latch.open()
    }
}
