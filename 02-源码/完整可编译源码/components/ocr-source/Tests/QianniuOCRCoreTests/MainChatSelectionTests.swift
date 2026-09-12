import CoreGraphics
import XCTest
@testable import QianniuOCRCore

final class MainChatSelectionTests: XCTestCase {
    func testCropsCommonChatContainerAtComposerTop() {
        let nodes = [
            node(0, nil, "AXWindow", frame: rect(0, 0, 1400, 900)),
            node(1, 0, "AXGroup", frame: rect(300, 80, 650, 760)),
            node(2, 1, "AXButton", title: "转发当前用户", frame: rect(820, 95, 40, 30)),
            node(3, 1, "AXMenuButton", title: "新建任务", frame: rect(865, 95, 40, 30)),
            node(4, 1, "AXTextArea", frame: rect(320, 650, 610, 170)),
        ]

        XCTAssertEqual(
            MainChatSelection.cropFrame(from: nodes, inside: rect(0, 0, 1400, 900)),
            rect(300, 80, 650, 570)
        )
    }

    func testFallsBackToConversationContainerWhenLiveHeadersAreWindowSiblings() {
        let nodes = [
            node(0, nil, "AXWindow", frame: rect(0, 33, 1512, 899)),
            node(44, 0, "AXButton", title: "转发当前用户", frame: rect(916, 143, 20, 20)),
            node(45, 0, "AXMenuButton", title: "新建任务", frame: rect(946, 143, 34, 20)),
            node(46, 0, "AXButton", title: "更多", frame: rect(990, 143, 20, 20)),
            node(47, 0, "AXSplitGroup", frame: rect(304, 178, 726, 752)),
            node(85, 47, "AXTextArea", frame: rect(324, 659, 706, 231)),
            node(88, 47, "AXGroup", frame: rect(304, 178, 726, 439)),
            node(89, 47, "AXGroup", frame: rect(324, 617, 706, 42)),
            node(62, 0, "AXGroup", frame: rect(1030, 129, 480, 801)),
        ]

        XCTAssertEqual(
            MainChatSelection.cropFrame(from: nodes, inside: rect(0, 33, 1512, 899)),
            rect(304, 178, 726, 439)
        )
    }

    func testFallbackRejectsComposerToolbarWhenConversationContainerIsAbsent() {
        let nodes = [
            node(0, nil, "AXWindow", frame: rect(0, 33, 1512, 899)),
            node(44, 0, "AXButton", title: "转发当前用户", frame: rect(916, 143, 20, 20)),
            node(45, 0, "AXMenuButton", title: "新建任务", frame: rect(946, 143, 34, 20)),
            node(47, 0, "AXSplitGroup", frame: rect(304, 178, 726, 752)),
            node(85, 47, "AXTextArea", frame: rect(324, 659, 706, 231)),
            node(89, 47, "AXGroup", frame: rect(324, 617, 706, 42)),
        ]

        XCTAssertNil(MainChatSelection.cropFrame(from: nodes, inside: rect(0, 33, 1512, 899)))
    }

    func testFallbackRejectsStaleShellAsItsOwnConversationContainer() {
        let nodes = [
            node(0, nil, "AXWindow", frame: rect(0, 33, 1512, 899)),
            node(44, 0, "AXButton", title: "转发当前用户", frame: rect(916, 143, 20, 20)),
            node(45, 0, "AXMenuButton", title: "新建任务", frame: rect(946, 143, 34, 20)),
            node(47, 0, "AXSplitGroup", frame: rect(304, 178, 726, 481)),
            node(85, 47, "AXTextArea", frame: rect(324, 659, 706, 231)),
        ]

        XCTAssertNil(MainChatSelection.cropFrame(from: nodes, inside: rect(0, 33, 1512, 899)))
    }

    func testTranslatedAndScaledTreeKeepsRelativeChatCrop() {
        let nodes = [
            node(0, nil, "AXWindow", frame: rect(150, 70, 2800, 1800)),
            node(1, 0, "AXGroup", frame: rect(750, 230, 1300, 1520)),
            node(2, 1, "AXButton", title: "转发当前用户", frame: rect(1790, 260, 80, 60)),
            node(3, 1, "AXMenuButton", title: "新建任务", frame: rect(1880, 260, 80, 60)),
            node(4, 1, "AXTextArea", frame: rect(790, 1370, 1220, 340)),
        ]

        XCTAssertEqual(
            MainChatSelection.cropFrame(from: nodes, inside: rect(150, 70, 2800, 1800)),
            rect(750, 230, 1300, 1140)
        )
    }

    func testRejectsWindowAsOnlyCommonAncestor() {
        let nodes = [
            node(0, nil, "AXWindow", frame: rect(0, 0, 1400, 900)),
            node(1, 0, "AXButton", title: "转发当前用户", frame: rect(820, 95, 40, 30)),
            node(2, 0, "AXMenuButton", title: "新建任务", frame: rect(865, 95, 40, 30)),
            node(3, 0, "AXTextArea", frame: rect(320, 650, 610, 170)),
        ]

        XCTAssertNil(MainChatSelection.cropFrame(from: nodes, inside: rect(0, 0, 1400, 900)))
    }

    func testRejectsDuplicateNodeIDs() {
        let nodes = [
            node(0, nil, "AXWindow", frame: rect(0, 0, 1400, 900)),
            node(1, 0, "AXGroup", frame: rect(300, 80, 650, 760)),
            node(1, 0, "AXButton", title: "转发当前用户", frame: rect(820, 95, 40, 30)),
        ]

        XCTAssertNil(MainChatSelection.cropFrame(from: nodes, inside: rect(0, 0, 1400, 900)))
    }

    func testRequiresComposerAndTwoStableHeaderLabels() {
        let noComposer = [
            node(0, nil, "AXWindow", frame: rect(0, 0, 1400, 900)),
            node(1, 0, "AXGroup", frame: rect(300, 80, 650, 760)),
            node(2, 1, "AXButton", title: "转发当前用户", frame: rect(820, 95, 40, 30)),
            node(3, 1, "AXMenuButton", title: "新建任务", frame: rect(865, 95, 40, 30)),
        ]
        let oneHeader = [
            node(0, nil, "AXWindow", frame: rect(0, 0, 1400, 900)),
            node(1, 0, "AXGroup", frame: rect(300, 80, 650, 760)),
            node(2, 1, "AXButton", title: "转发当前用户", frame: rect(820, 95, 40, 30)),
            node(3, 1, "AXTextArea", frame: rect(320, 650, 610, 170)),
        ]

        XCTAssertNil(MainChatSelection.cropFrame(from: noComposer, inside: rect(0, 0, 1400, 900)))
        XCTAssertNil(MainChatSelection.cropFrame(from: oneHeader, inside: rect(0, 0, 1400, 900)))
    }

    func testCropStopsBeforeComposerAndExcludesSiblingSidebars() {
        let leftSidebar = rect(0, 80, 280, 760)
        let rightSidebar = rect(980, 80, 420, 760)
        let nodes = [
            node(0, nil, "AXWindow", frame: rect(0, 0, 1400, 900)),
            node(1, 0, "AXGroup", frame: leftSidebar),
            node(2, 0, "AXGroup", frame: rect(300, 80, 650, 760)),
            node(3, 0, "AXGroup", frame: rightSidebar),
            node(4, 2, "AXButton", title: "转发当前用户", frame: rect(820, 95, 40, 30)),
            node(5, 2, "AXMenuButton", title: "新建任务", frame: rect(865, 95, 40, 30)),
            node(6, 2, "AXTextArea", frame: rect(320, 650, 610, 170)),
        ]

        let crop = MainChatSelection.cropFrame(from: nodes, inside: rect(0, 0, 1400, 900))

        guard let crop else {
            XCTFail("Expected a crop for the chat container")
            return
        }

        XCTAssertEqual(crop, rect(300, 80, 650, 570))
        XCTAssertFalse(crop.intersects(leftSidebar))
        XCTAssertFalse(crop.intersects(rightSidebar))
        XCTAssertLessThanOrEqual(crop.maxY, 650)
    }

    private func node(
        _ id: Int,
        _ parentID: Int?,
        _ role: String,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        frame: CGRect
    ) -> AXNodeCandidate {
        AXNodeCandidate(
            id: id,
            parentID: parentID,
            candidate: AXCandidate(
                role: role,
                title: title,
                description: description,
                value: value,
                frame: frame
            )
        )
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
