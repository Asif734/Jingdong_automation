import CoreGraphics
import XCTest
@testable import QianniuOCRCore

final class CustomerRequestManifestTests: XCTestCase {
    func testExtractsAccountLikeIdentifierFromChatHeader() {
        let lines = [
            OCRLine(text: "下面的消息", box: CGRect(x: 20, y: 200, width: 80, height: 20)),
            OCRLine(text: "tb263147182", box: CGRect(x: 20, y: 12, width: 100, height: 20)),
        ]

        XCTAssertEqual(
            CustomerIdentityExtractor.extract(from: lines, imageHeight: 375),
            CustomerIdentity(value: "tb263147182", status: .detected)
        )
    }

    func testDoesNotTreatOrdinaryShortMessageAsCustomerIdentifier() {
        let lines = [
            OCRLine(text: "你好", box: CGRect(x: 20, y: 12, width: 40, height: 20)),
            OCRLine(text: "打印机坏了", box: CGRect(x: 20, y: 70, width: 90, height: 20)),
        ]

        XCTAssertNil(CustomerIdentityExtractor.detectedValue(from: lines, imageHeight: 375))
    }

    func testDoesNotTreatTopDateOrOrderNumberAsCustomerIdentifier() {
        let lines = [
            OCRLine(text: "20260810", box: CGRect(x: 20, y: 10, width: 80, height: 20)),
            OCRLine(text: "123456789012", box: CGRect(x: 20, y: 40, width: 100, height: 20)),
        ]

        XCTAssertNil(CustomerIdentityExtractor.detectedValue(from: lines, imageHeight: 375))
    }

    func testMissingIdentifierUsesRequestScopedSafeFallback() {
        XCTAssertEqual(
            CustomerIdentityExtractor.identity(
                from: [OCRLine(text: "你好", box: .zero)],
                imageHeight: 375,
                requestID: "20260810-0001"
            ),
            CustomerIdentity(value: "unknown-20260810-0001", status: .needsReview)
        )
    }

    func testMessagesKeepTextAndImageInPageOrder() {
        let lines = [
            OCRLine(text: "图片之后", box: CGRect(x: 20, y: 240, width: 80, height: 20)),
            OCRLine(text: "图片之前", box: CGRect(x: 20, y: 40, width: 80, height: 20)),
        ]
        let images = [CGRect(x: 30, y: 100, width: 200, height: 120)]

        XCTAssertEqual(
            CustomerRequestManifestBuilder.messages(lines: lines, imageBoxes: images),
            [
                CustomerRequestMessage(t: "text", v: "图片之前", p: nil),
                CustomerRequestMessage(t: "image", v: nil, p: "images/1.jpg"),
                CustomerRequestMessage(t: "text", v: "图片之后", p: nil),
            ]
        )
    }
}
