import XCTest
import UnreadCore
@testable import AutoReplyApp

final class TransferMenuSelectionTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1_200, height: 800)

    func testSelectsUniquePressableTransferButtonBesideHeaderControls() {
        let nodes = [
            AXNode(id: 1, parent: 0, role: "AXStaticText", title: "tb263147182",
                   frame: CGRect(x: 300, y: 90, width: 120, height: 20)),
            AXNode(id: 2, parent: 0, role: "AXButton", title: "转发当前用户",
                   frame: CGRect(x: 430, y: 90, width: 20, height: 20)),
            AXNode(id: 3, parent: 0, role: "AXMenuButton", title: "新建任务",
                   frame: CGRect(x: 460, y: 90, width: 34, height: 20))
        ]

        XCTAssertEqual(
            TransferMenuSelection.select(
                nodes: nodes,
                window: window,
                actionNamesByNodeID: [2: ["AXPress"], 3: ["AXShowMenu"]]
            ),
            2
        )
    }

    func testRejectsDuplicateOrNonPressableTransferControls() {
        let transfer = AXNode(id: 2, parent: 0, role: "AXButton", title: "转发当前用户",
                              frame: CGRect(x: 430, y: 90, width: 20, height: 20))
        let task = AXNode(id: 3, parent: 0, role: "AXMenuButton", title: "新建任务",
                         frame: CGRect(x: 460, y: 90, width: 34, height: 20))
        let duplicate = AXNode(id: 4, parent: 0, role: "AXButton", title: "转发当前用户",
                               frame: CGRect(x: 700, y: 90, width: 20, height: 20))

        XCTAssertNil(TransferMenuSelection.select(
            nodes: [transfer, task], window: window,
            actionNamesByNodeID: [2: ["AXRaise"], 3: ["AXShowMenu"]]
        ))
        XCTAssertNil(TransferMenuSelection.select(
            nodes: [transfer, task, duplicate], window: window,
            actionNamesByNodeID: [2: ["AXPress"], 3: ["AXShowMenu"], 4: ["AXPress"]]
        ))
    }
}
