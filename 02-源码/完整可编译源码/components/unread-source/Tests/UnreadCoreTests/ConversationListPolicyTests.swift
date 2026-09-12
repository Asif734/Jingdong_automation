import CoreGraphics
import XCTest
@testable import UnreadCore

final class ConversationListPolicyTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1287, height: 768)

    func testBlankShortHeaderDoesNotBecomeCustomer() throws {
        let nodes = fixtureNodes(includeMalformedMiddleNode: false)
        let policy = try ConversationListPolicy.calibrate(nodes: nodes, window: window)
        let result = try ConversationLocator.candidates(
            nodes: nodes,
            window: window,
            policy: policy,
            preferStructuralUID: true
        )

        XCTAssertEqual(policy.medianCustomerHeight, 52, accuracy: 0.001)
        XCTAssertEqual(result.compactMap(\.identity.resolved), ["stoneshishininger", "customer-b"])
        XCTAssertFalse(result.contains { $0.nodeID == 10 })
    }

    func testMalformedNodeDoesNotDiscardValidRows() throws {
        let nodes = fixtureNodes(includeMalformedMiddleNode: true)
        let policy = try ConversationListPolicy.calibrate(nodes: nodes, window: window)
        let result = try ConversationLocator.candidates(
            nodes: nodes,
            window: window,
            policy: policy,
            preferStructuralUID: true
        )

        XCTAssertEqual(Set(result.compactMap(\.identity.resolved)), ["stoneshishininger", "customer-b"])
    }

    private func fixtureNodes(includeMalformedMiddleNode: Bool) -> [AXNode] {
        var nodes = [
            AXNode(id: 0, role: "AXWindow", frame: window),
            AXNode(id: 1, parent: 0, role: "AXGroup", frame: CGRect(x: 58, y: 170, width: 212, height: 590)),
            AXNode(id: 2, parent: 1, role: "AXCheckBox", title: "正在接待买家列表", frame: CGRect(x: 74, y: 240, width: 100, height: 30)),
            AXNode(id: 3, parent: 1, role: "AXGroup", frame: CGRect(x: 64, y: 280, width: 202, height: 480)),
            AXNode(id: 10, parent: 3, role: "AXGroup", frame: CGRect(x: 64, y: 382, width: 202, height: 34)),
            AXNode(id: 11, parent: 3, role: "AXGroup", title: "stoneshishininger", frame: CGRect(x: 64, y: 416, width: 202, height: 52)),
            AXNode(id: 13, parent: 3, role: "AXGroup", title: "customer-b", frame: CGRect(x: 64, y: 502, width: 202, height: 52)),
        ]
        if includeMalformedMiddleNode {
            nodes.insert(
                AXNode(id: 12, parent: 999, role: "AXGroup", title: "broken", frame: CGRect(x: CGFloat.nan, y: 468, width: -10, height: 0)),
                at: 6
            )
        }
        return nodes
    }
}
