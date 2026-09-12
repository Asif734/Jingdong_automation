import XCTest
@testable import AutoReplyCore

final class UIOperationLeaseTests: XCTestCase {
    func testNewLeaseInvalidatesOldLease() async {
        let registry = UIOperationLeaseRegistry()
        let old = registry.acquire(uid: "A")
        let current = registry.acquire(uid: "B")

        let oldIsValid = registry.isValid(old)
        let currentIsValid = registry.isValid(current)
        XCTAssertFalse(oldIsValid)
        XCTAssertTrue(currentIsValid)
    }

    func testStopRevokesCurrentLease() async {
        let registry = UIOperationLeaseRegistry()
        let lease = registry.acquire(uid: "A")

        registry.revokeAll()

        let leaseIsValid = registry.isValid(lease)
        XCTAssertFalse(leaseIsValid)
    }
}
