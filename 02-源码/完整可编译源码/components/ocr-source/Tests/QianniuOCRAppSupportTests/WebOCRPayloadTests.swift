import XCTest
@testable import QianniuOCRAppSupport

final class WebOCRPayloadTests: XCTestCase {
    func testDecodesEveryLineWithoutFilteringOrRewriting() throws {
        let json = #"{"lines":[{"text":"1","confidence":0.99,"box":{"x":5,"y":10,"width":8,"height":12}},{"text":"原文  空格","confidence":0.4,"box":{"x":20,"y":30,"width":60,"height":15}},{"text":"1","confidence":0.2,"box":{"x":5,"y":50,"width":8,"height":12}}]}"#

        let payload = try JSONDecoder().decode(WebOCRPayload.self, from: Data(json.utf8))

        XCTAssertEqual(payload.lines.map(\.text), ["1", "原文  空格", "1"])
        XCTAssertEqual(payload.lines.map(\.confidence), [0.99, 0.4, 0.2])
        XCTAssertEqual(payload.lines[0].box.origin.x, 5)
    }
}
