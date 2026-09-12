import XCTest
import UnreadCore
@testable import UnreadApp

final class RowHitTests: XCTestCase {
    let row = ConversationRow(nodeID: 1, uid: "tb263147182", frame: CGRect(x: 133, y: 401, width: 240, height: 52))
    @MainActor func testRecreatedAXRowWithSamePIDFullIDAndFrameMatches() {
        let hit = AXNode(id: 99, role: "AXGroup", description: "tb263147182", frame: row.frame)
        XCTAssertTrue(NativeSession.matchesRowHit(hit, row: row, hitPID: 707, targetPID: 707))
    }
    @MainActor func testForeignApplicationWithIdenticalRowDoesNotMatch() {
        let hit = AXNode(id: 99, role: "AXGroup", description: "tb263147182", frame: row.frame)
        XCTAssertFalse(NativeSession.matchesRowHit(hit, row: row, hitPID: 708, targetPID: 707))
    }
    @MainActor func testDifferentOrTooShortTruncatedCustomerDoesNotMatch() {
        for uid in ["stoneshishininger", "tb2...", ""] {
            let hit = AXNode(id: 99, role: "AXGroup", description: uid, frame: row.frame)
            XCTAssertFalse(NativeSession.matchesRowHit(hit, row: row, hitPID: 707, targetPID: 707))
        }
        let usablePrefix = AXNode(id: 100, role: "AXGroup", description: "tb26...", frame: row.frame)
        XCTAssertTrue(NativeSession.matchesRowHit(usablePrefix, row: row, hitPID: 707, targetPID: 707))
    }
    @MainActor func testMovedOrDifferentSizedRowDoesNotMatch() {
        for frame in [CGRect(x: 133, y: 453, width: 240, height: 52), CGRect(x: 133, y: 401, width: 240, height: 547)] {
            let hit = AXNode(id: 99, role: "AXGroup", description: row.uid, frame: frame)
            XCTAssertFalse(NativeSession.matchesRowHit(hit, row: row, hitPID: 707, targetPID: 707))
        }
    }
    @MainActor func testUnrelatedControlOrConflictingIdentityDoesNotMatch() {
        for hit in [AXNode(id: 99, role: "AXButton", description: row.uid, frame: row.frame),
                    AXNode(id: 99, role: "AXGroup", title: "other", description: row.uid, frame: row.frame)] {
            XCTAssertFalse(NativeSession.matchesRowHit(hit, row: row, hitPID: 707, targetPID: 707))
        }
    }
    @MainActor func testNicknameFallbackCanVerifyAnUnlabeledRecreatedRow() {
        let fallbackRow = ConversationRow(nodeID: 7, uid: "stoneshininger", nickname: "stoneshininger", frame: row.frame)
        let unlabeledHit = AXNode(id: 99, role: "AXGroup", frame: row.frame)
        XCTAssertTrue(NativeSession.matchesRowHit(unlabeledHit, row: fallbackRow, hitPID: 707, targetPID: 707,
                                                  fallbackNickname: "stoneshininger"))
        XCTAssertTrue(NativeSession.matchesRowHit(unlabeledHit, row: fallbackRow, hitPID: 707, targetPID: 707,
                                                  fallbackNickname: "stonesh..."))
        XCTAssertFalse(NativeSession.matchesRowHit(unlabeledHit, row: fallbackRow, hitPID: 707, targetPID: 707,
                                                   fallbackNickname: "another_customer"))
    }
}
