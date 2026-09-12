import XCTest
@testable import CustomerReplyBatchCore

final class ReplyEnvelopeActionTests: XCTestCase {
    func testDecodesTwoActionModelContract() throws {
        let data = Data(#"{"action":"reply_then_transfer","reply_text":"好的亲，我这边为您转人工处理。","transfer_reason":"customer_explicitly_requested_human","reason":"客户明确要求人工"}"#.utf8)

        let reply = try JSONDecoder().decode(ReplyEnvelope.self, from: data)

        XCTAssertEqual(reply.action, .replyThenTransfer)
        XCTAssertEqual(reply.transferReason, .customerExplicitlyRequestedHuman)
        XCTAssertEqual(reply.decision, .autoSend)
        XCTAssertEqual(reply.riskLevel, .low)
    }

    func testOldPersistedEnvelopeStillDecodesAsNormalReply() throws {
        let data = Data(#"{"decision":"auto_send","risk_level":"low","reply_text":"您好","reason":"历史记录"}"#.utf8)

        let reply = try JSONDecoder().decode(ReplyEnvelope.self, from: data)

        XCTAssertEqual(reply.action, .reply)
        XCTAssertEqual(reply.transferReason, .none)
    }

    func testRejectsTransferActionWithoutSpecificTransferReason() {
        let data = Data(#"{"action":"reply_then_transfer","reply_text":"您好","transfer_reason":"none","reason":"错误组合"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ReplyEnvelope.self, from: data))
    }

    func testRejectsNormalReplyWithTransferReason() {
        let data = Data(#"{"action":"reply","reply_text":"您好","transfer_reason":"remote_assistance","reason":"错误组合"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ReplyEnvelope.self, from: data))
    }
}
