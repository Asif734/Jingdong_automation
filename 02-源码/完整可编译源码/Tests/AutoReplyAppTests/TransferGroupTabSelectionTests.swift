import XCTest
import QianniuOCRCore
@testable import AutoReplyApp

final class TransferGroupTabSelectionTests: XCTestCase {
    func testSelectsNewQianniuPopupNearestTransferButton() throws {
        let reception = CGRect(x: 500, y: 30, width: 1_300, height: 900)
        let anchor = CGRect(x: 1_610, y: 90, width: 24, height: 24)
        let windows = [
            TransferWindowCandidate(id: 1, frame: reception),
            TransferWindowCandidate(id: 2, frame: CGRect(x: 1_210, y: 145, width: 356, height: 436)),
            TransferWindowCandidate(id: 3, frame: CGRect(x: 100, y: 100, width: 400, height: 400))
        ]

        let selected = TransferPopupSelection.select(
            windows: windows,
            visibleBefore: [1, 3],
            receptionWindowID: 1,
            receptionFrame: reception,
            transferButtonFrame: anchor
        )

        XCTAssertEqual(selected?.id, 2)
    }

    func testRejectsAmbiguousNewPopups() {
        let reception = CGRect(x: 500, y: 30, width: 1_300, height: 900)
        let anchor = CGRect(x: 1_610, y: 90, width: 24, height: 24)
        let windows = [
            TransferWindowCandidate(id: 1, frame: reception),
            TransferWindowCandidate(id: 2, frame: CGRect(x: 1_210, y: 145, width: 356, height: 436)),
            TransferWindowCandidate(id: 4, frame: CGRect(x: 1_230, y: 150, width: 350, height: 430))
        ]

        XCTAssertNil(TransferPopupSelection.select(
            windows: windows,
            visibleBefore: [1],
            receptionWindowID: 1,
            receptionFrame: reception,
            transferButtonFrame: anchor
        ))
    }

    func testFindsUniqueTransferToGroupTextAndReturnsItsCenter() throws {
        let lines = [
            OCRLine(text: "转交到人", box: CGRect(x: 18, y: 20, width: 88, height: 28), confidence: 0.99),
            OCRLine(text: "转 交 到 组", box: CGRect(x: 128, y: 19, width: 102, height: 30), confidence: 0.96),
            OCRLine(text: "售前分组", box: CGRect(x: 32, y: 190, width: 110, height: 26), confidence: 0.99)
        ]

        XCTAssertEqual(
            TransferGroupTabSelection.clickPoint(lines: lines, imageSize: CGSize(width: 356, height: 131)),
            CGPoint(x: 179, y: 34)
        )
    }

    func testRejectsLowConfidenceOrDuplicateTransferToGroupText() {
        let lowConfidence = [
            OCRLine(text: "转交到组", box: CGRect(x: 100, y: 20, width: 100, height: 30), confidence: 0.30)
        ]
        XCTAssertNil(TransferGroupTabSelection.clickPoint(
            lines: lowConfidence,
            imageSize: CGSize(width: 356, height: 131)
        ))

        let duplicate = [
            OCRLine(text: "转交到组", box: CGRect(x: 100, y: 20, width: 100, height: 30), confidence: 0.95),
            OCRLine(text: "转交到组", box: CGRect(x: 110, y: 70, width: 100, height: 30), confidence: 0.95)
        ]
        XCTAssertNil(TransferGroupTabSelection.clickPoint(
            lines: duplicate,
            imageSize: CGSize(width: 356, height: 131)
        ))
    }

    func testFallbackRegionTracksTransferButtonInsteadOfAbsoluteScreenCoordinates() throws {
        let display = CGRect(x: 200, y: 20, width: 1_920, height: 1_080)
        let reception = CGRect(x: 500, y: 30, width: 1_300, height: 900)
        let button = CGRect(x: 1_610, y: 90, width: 24, height: 24)

        XCTAssertEqual(
            TransferPopupFallback.region(
                displayFrame: display,
                receptionFrame: reception,
                transferButtonFrame: button
            ),
            CGRect(x: 1_102, y: 94, width: 532, height: 190)
        )
    }

    func testListsGroupRowsFromTopToBottomAndExcludesPopupControls() {
        let lines = [
            OCRLine(text: "转交到组", box: CGRect(x: 120, y: 20, width: 100, height: 28), confidence: 0.99),
            OCRLine(text: "搜索", box: CGRect(x: 40, y: 95, width: 50, height: 24), confidence: 0.98),
            OCRLine(text: "售后分组 (0人接待中)", box: CGRect(x: 42, y: 245, width: 220, height: 28), confidence: 0.88),
            OCRLine(text: "售前分组 (1人接待中)", box: CGRect(x: 42, y: 310, width: 220, height: 28), confidence: 0.97),
            OCRLine(text: "批量转交", box: CGRect(x: 270, y: 20, width: 70, height: 28), confidence: 0.99)
        ]

        XCTAssertEqual(
            TransferGroupCandidateSelection.clickPoints(
                lines: lines,
                imageSize: CGSize(width: 356, height: 436)
            ),
            [CGPoint(x: 152, y: 259), CGPoint(x: 152, y: 324)]
        )
    }

    func testContinuesAfterUnchangedDisabledRowAndStopsWhenPopupDisappears() {
        XCTAssertEqual(
            TransferGroupCandidateSelection.resultAfterClick(
                popupStillVisible: true,
                recognizedTextsBefore: ["转交到组", "售后分组(0人接待中)", "售前分组(1人接待中)"],
                recognizedTextsAfter: ["转交到组", "售后分组(0人接待中)", "售前分组(1人接待中)"]
            ),
            .continueTrying
        )

        XCTAssertEqual(
            TransferGroupCandidateSelection.resultAfterClick(
                popupStillVisible: false,
                recognizedTextsBefore: ["转交到组", "售前分组(1人接待中)"],
                recognizedTextsAfter: []
            ),
            .selectionAccepted
        )
    }

    func testStopsWhenClickOpensAConfirmationStep() {
        XCTAssertEqual(
            TransferGroupCandidateSelection.resultAfterClick(
                popupStillVisible: true,
                recognizedTextsBefore: ["转交到组", "售前分组(1人接待中)"],
                recognizedTextsAfter: ["确认转交", "取消", "确定"]
            ),
            .selectionAccepted
        )
    }

    func testContinuesWhenOnlyOneOCRLineHasMinorInstability() {
        XCTAssertEqual(
            TransferGroupCandidateSelection.resultAfterClick(
                popupStillVisible: true,
                recognizedTextsBefore: ["转交到组", "批量转交", "售后分组", "售前分组", "上次转交"],
                recognizedTextsAfter: ["转交到组", "批量转交", "售后分组", "售前分组", "上次转文"]
            ),
            .continueTrying
        )
    }
}
