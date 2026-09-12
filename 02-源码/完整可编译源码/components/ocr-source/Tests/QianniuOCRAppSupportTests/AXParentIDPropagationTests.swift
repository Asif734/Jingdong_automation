import XCTest
@testable import QianniuOCRAppSupport

final class AXParentIDPropagationTests: XCTestCase {
    func testCarriesNearestFramedParentAcrossUnframedIntermediates() {
        let framedParentID = AXParentIDPropagation.childrenParentID(
            nodeID: 7,
            inheritedParentID: nil
        )
        let firstUnframedParentID = AXParentIDPropagation.childrenParentID(
            nodeID: nil,
            inheritedParentID: framedParentID
        )
        let secondUnframedParentID = AXParentIDPropagation.childrenParentID(
            nodeID: nil,
            inheritedParentID: firstUnframedParentID
        )

        XCTAssertEqual(framedParentID, 7)
        XCTAssertEqual(firstUnframedParentID, 7)
        XCTAssertEqual(secondUnframedParentID, 7)
    }
}
