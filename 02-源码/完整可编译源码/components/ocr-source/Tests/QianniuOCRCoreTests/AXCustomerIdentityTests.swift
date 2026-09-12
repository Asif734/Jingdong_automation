import CoreGraphics
import XCTest
@testable import QianniuOCRCore

final class AXCustomerIdentityTests: XCTestCase {
    func testMatchesTruncatedHeaderToUniqueArbitraryReceptionUserID() {
        let nodes = [
            node(1, nil, role: "AXGroup", title: "stoneshishininger", frame: rect(60, 130, 220, 70)),
            node(2, nil, role: "AXGroup", title: "another-user_测试", frame: rect(60, 200, 220, 70)),
            node(3, nil, role: "AXStaticText", value: "stoneshishinin...", frame: rect(330, 110, 140, 24)),
        ]

        XCTAssertEqual(
            AXCustomerIdentity.candidates(nodes: nodes, chatFrame: rect(300, 100, 700, 520)),
            CustomerIdentityCandidates(
                axHeader: "stoneshishininger",
                axSessionList: "stoneshishininger",
                ocr: nil
            )
        )
    }

    func testFindsCurrentChatTitleImmediatelyAboveTheDynamicallyLocatedChatFrame() {
        let nodes = [
            node(1, nil, role: "AXGroup", title: "stoneshishininger", frame: rect(102, 315, 336, 70)),
            node(2, nil, role: "AXGroup", title: "tb263147182", frame: rect(102, 385, 336, 70)),
            node(3, nil, role: "AXStaticText", value: "stoneshishinin...", frame: rect(475, 174, 250, 32)),
            node(4, nil, role: "AXStaticText", value: "nihao", frame: rect(475, 235, 100, 24)),
            node(5, nil, role: "AXStaticText", frame: rect(457, 196, 20, 20)),
            node(6, nil, role: "AXStaticText", frame: rect(462, 194, 748, 62)),
        ]

        XCTAssertEqual(
            AXCustomerIdentity.candidates(nodes: nodes, chatFrame: rect(462, 223, 748, 625)),
            CustomerIdentityCandidates(
                axHeader: "stoneshishininger",
                axSessionList: "stoneshishininger",
                ocr: nil
            )
        )
    }

    func testIdentitySelectionMovesWithTheChatFrameInsteadOfUsingFixedScreenCoordinates() {
        let nodes = [
            node(1, nil, role: "AXGroup", title: "中文-user.@_", frame: rect(960, 530, 220, 70)),
            node(2, nil, role: "AXStaticText", value: "中文-user.@_", frame: rect(1_230, 510, 180, 24)),
        ]

        XCTAssertEqual(
            AXCustomerIdentity.candidates(nodes: nodes, chatFrame: rect(1_200, 500, 700, 520)),
            CustomerIdentityCandidates(
                axHeader: "中文-user.@_",
                axSessionList: "中文-user.@_",
                ocr: nil
            )
        )
    }

    func testDoesNotGuessWhenTruncatedHeaderMatchesMultipleReceptionRows() {
        let nodes = [
            node(1, nil, role: "AXGroup", title: "same-prefix-alpha", frame: rect(60, 130, 220, 70)),
            node(2, nil, role: "AXGroup", title: "same-prefix-beta", frame: rect(60, 200, 220, 70)),
            node(3, nil, role: "AXStaticText", value: "same-prefix...", frame: rect(330, 110, 140, 24)),
        ]

        XCTAssertEqual(
            AXCustomerIdentity.candidates(nodes: nodes, chatFrame: rect(300, 100, 700, 520)),
            .empty
        )
    }

    func testFindsHeaderAndSelectedReceptionSession() {
        let nodes = [
            node(1, nil, role: "AXStaticText", value: "正在接待 2", frame: rect(70, 100, 100, 20)),
            node(2, nil, role: "AXGroup", title: "tb9783153356", frame: rect(60, 130, 220, 70), isSelected: true),
            node(3, nil, role: "AXGroup", title: "tb263147182", frame: rect(60, 200, 220, 70)),
            node(4, nil, role: "AXStaticText", value: "tb9783153356", frame: rect(330, 110, 140, 24)),
            node(5, nil, role: "AXButton", title: "转发当前用户", frame: rect(850, 110, 24, 24)),
            node(6, nil, role: "AXMenuButton", title: "新建任务", frame: rect(885, 110, 34, 24)),
        ]

        XCTAssertEqual(
            AXCustomerIdentity.candidates(nodes: nodes, chatFrame: rect(300, 100, 700, 520)),
            CustomerIdentityCandidates(
                axHeader: "tb9783153356",
                axSessionList: "tb9783153356",
                ocr: nil
            )
        )
    }

    func testUsesSelectedReceptionSessionWhenHeaderIsAbsent() {
        let nodes = [
            node(1, nil, role: "AXStaticText", value: "正在接待 2", frame: rect(70, 100, 100, 20)),
            node(2, nil, role: "AXGroup", description: "tb9783153356", frame: rect(60, 130, 220, 70)),
            node(3, nil, role: "AXGroup", description: "tb263147182", frame: rect(60, 200, 220, 70), isSelected: true),
        ]

        let result = AXCustomerIdentity.candidates(nodes: nodes, chatFrame: rect(300, 100, 700, 520))

        XCTAssertNil(result.axHeader)
        XCTAssertEqual(result.axSessionList, "tb263147182")
    }

    func testHeaderCrossChecksMatchingReceptionRowWithoutSelectedAttribute() {
        let nodes = [
            node(1, nil, role: "AXGroup", title: "tb9783153356", frame: rect(60, 130, 220, 70)),
            node(2, nil, role: "AXGroup", title: "tb263147182", frame: rect(60, 200, 220, 70)),
            node(3, nil, role: "AXStaticText", value: "tb9783153356", frame: rect(330, 110, 140, 24)),
        ]

        let result = AXCustomerIdentity.candidates(nodes: nodes, chatFrame: rect(300, 100, 700, 520))

        XCTAssertEqual(result.axHeader, "tb9783153356")
        XCTAssertEqual(result.axSessionList, "tb9783153356")
    }

    func testDoesNotGuessFromUnselectedReceptionRows() {
        let nodes = [
            node(1, nil, role: "AXStaticText", value: "正在接待 2", frame: rect(70, 100, 100, 20)),
            node(2, nil, role: "AXGroup", title: "tb9783153356", frame: rect(60, 130, 220, 70)),
            node(3, nil, role: "AXGroup", title: "tb263147182", frame: rect(60, 200, 220, 70)),
        ]

        XCTAssertNil(
            AXCustomerIdentity.candidates(nodes: nodes, chatFrame: rect(300, 100, 700, 520)).axSessionList
        )
    }

    private func node(
        _ id: Int,
        _ parentID: Int?,
        role: String,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        frame: CGRect,
        isSelected: Bool = false
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
            ),
            isSelected: isSelected
        )
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
