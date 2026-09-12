import XCTest
@testable import CustomerReplyBatchAppSupport

final class ConcurrencyPolicyTests: XCTestCase {
    func testNormalMemoryAlwaysAdmitsWithoutNumericCapacity() {
        let policy = AdaptiveConcurrencyPolicy()
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(policy.decision(availableMemoryBytes: 2 << 30, now: now), .admit)
        XCTAssertEqual(policy.decision(availableMemoryBytes: 200 << 30, now: now), .admit)
    }

    func testHardMemoryPressureDefersWithoutFailingWork() {
        let policy = AdaptiveConcurrencyPolicy(hardMemoryFloorBytes: 1 << 30)
        XCTAssertEqual(
            policy.decision(availableMemoryBytes: (1 << 30) - 1, now: Date()),
            .deferForMemory
        )
    }

    func testExplicitBackpressureDefersUntilCooldownExpires() {
        let policy = AdaptiveConcurrencyPolicy()
        let now = Date(timeIntervalSince1970: 1_000)
        policy.recordBackpressure(now: now)

        XCTAssertEqual(
            policy.decision(availableMemoryBytes: 40 << 30, now: now),
            .deferForBackpressure(until: now.addingTimeInterval(60))
        )
        XCTAssertEqual(
            policy.decision(availableMemoryBytes: 40 << 30, now: now.addingTimeInterval(60)),
            .admit
        )
    }
}
