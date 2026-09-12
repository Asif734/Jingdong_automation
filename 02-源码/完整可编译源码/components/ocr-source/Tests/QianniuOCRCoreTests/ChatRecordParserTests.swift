import CoreGraphics
import XCTest
@testable import QianniuOCRCore

final class ChatRecordParserTests: XCTestCase {
    func testExtractsOnlyLinesBetweenRoamingBannerAndPaginationRow() {
        let lines = [
            line("全部消息", x: 10, y: 100),
            line("文件", x: 100, y: 100),
            line("图片/视频", x: 160, y: 100),
            line("近一个月内没有需要漫游的消息", x: 10, y: 130),
            line("客服", x: 10, y: 190),
            line("1", x: 220, y: 220),
            line("1", x: 220, y: 250),
            line("K", x: 100, y: 500),
            line("41/41", x: 180, y: 500),
            line(">", x: 250, y: 500),
        ]

        XCTAssertEqual(
            ChatRecordParser.extract(from: lines).map(\.text),
            ["客服", "1", "1"]
        )
    }

    func testCombinesSplitRoamingBannerFragmentsAcrossAdjacentVisualRows() {
        let lines = [
            line("近一个月内没有", x: 10, y: 100),
            line("需要漫游的消息", x: 10, y: 118),
            line("原文", x: 10, y: 170),
            line("1/1", x: 160, y: 400),
        ]

        XCTAssertEqual(ChatRecordParser.extract(from: lines).map(\.text), ["原文"])
    }

    func testUsesMessageTypeNavigationWhenBannerIsMissing() {
        let lines = [
            line("全部消息", x: 10, y: 100),
            line("文件", x: 100, y: 101),
            line("正文", x: 10, y: 180),
            line("12 / 20", x: 160, y: 400),
        ]

        XCTAssertEqual(ChatRecordParser.extract(from: lines).map(\.text), ["正文"])
    }

    func testUsesFirstTimestampRowWhenRoamingBannerIsCorruptedIntoShortNoise() {
        let lines = [
            line("全部消息", x: 10, y: 50),
            line("文件", x: 100, y: 50),
            line("图片/视频", x: 160, y: 50),
            line("7", x: 10, y: 90),
            line("OK", x: 80, y: 90),
            line("tb263147182", x: 10, y: 150),
            line("2026-8-820:51:06", x: 180, y: 150),
            line("正文", x: 10, y: 210),
            line("41/41", x: 160, y: 400),
        ]

        XCTAssertEqual(
            ChatRecordParser.extract(from: lines).map(\.text),
            ["tb263147182", "2026-8-820:51:06", "正文"]
        )
    }

    func testSkipsInterfaceNoiseBetweenRecognizedBannerAndFirstTimestampRow() {
        let lines = [
            line("全部消息", x: 10, y: 50),
            line("文件", x: 100, y: 50),
            line("近一个月内没有需要漫游的消息", x: 10, y: 80),
            line("7", x: 10, y: 110),
            line("OK", x: 80, y: 110),
            line("tb263147182", x: 10, y: 150),
            line("2026-8-820:51:06", x: 180, y: 150),
            line("正文", x: 10, y: 210),
            line("41/41", x: 160, y: 400),
        ]

        XCTAssertEqual(
            ChatRecordParser.extract(from: lines).map(\.text),
            ["tb263147182", "2026-8-820:51:06", "正文"]
        )
    }

    func testExcludesEntirePaginationRowWhenLeftArrowLooksLikeEachKnownVariant() {
        for arrow in ["K", "く", "<"] {
            let lines = [
                line("全部消息", x: 10, y: 50),
                line("文件", x: 100, y: 50),
                line("正文", x: 10, y: 120),
                line(arrow, x: 100, y: 400),
                line("2/9", x: 160, y: 401),
                line(">", x: 220, y: 400),
            ]

            XCTAssertEqual(ChatRecordParser.extract(from: lines).map(\.text), ["正文"])
        }
    }

    func testDoesNotUseStandaloneArrowLikeTextAsPaginationBoundary() {
        let lines = [
            line("正文", x: 10, y: 100),
            line("K", x: 10, y: 140),
            line("く", x: 10, y: 180),
        ]

        XCTAssertEqual(ChatRecordParser.extract(from: lines), lines)
    }

    func testReturnsFullInputForContradictoryBoundaries() {
        let lines = [
            line("41/41", x: 100, y: 300),
            line("近一个月需要漫游的消息", x: 10, y: 400),
        ]

        XCTAssertEqual(ChatRecordParser.extract(from: lines), lines)
    }

    func testReturnsFullInputWhenSliceWouldBeEmpty() {
        let lines = [
            line("近一个月需要漫游的消息", x: 10, y: 100),
            line("1/1", x: 100, y: 120),
        ]

        XCTAssertEqual(ChatRecordParser.extract(from: lines), lines)
    }

    func testPreservesTextBoxesConfidenceAndDuplicateInputOrder() {
        let first = OCRLine(
            text: "1",
            box: CGRect(x: 12, y: 150, width: 9, height: 11),
            confidence: 0.55
        )
        let second = OCRLine(
            text: "1",
            box: CGRect(x: 240, y: 190, width: 10, height: 12),
            confidence: 0.91
        )
        let lines = [
            line("全部消息", x: 10, y: 100),
            line("文件", x: 100, y: 100),
            first,
            second,
            line("3/3", x: 160, y: 400),
        ]

        XCTAssertEqual(ChatRecordParser.extract(from: lines), [first, second])
    }

    func testInvalidGeometryReturnsFullInput() {
        let invalid = OCRLine(
            text: "正文",
            box: CGRect(x: CGFloat.nan, y: 100, width: 20, height: 10)
        )
        let lines = [invalid, line("1/1", x: 100, y: 400)]

        XCTAssertEqual(ChatRecordParser.extract(from: lines), lines)
    }

    private func line(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 70,
        height: CGFloat = 12
    ) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height))
    }
}
