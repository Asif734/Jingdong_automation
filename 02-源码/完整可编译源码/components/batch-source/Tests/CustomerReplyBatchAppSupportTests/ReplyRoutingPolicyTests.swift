import XCTest
@testable import CustomerReplyBatchAppSupport
@testable import CustomerReplyBatchCore

final class ReplyRoutingPolicyTests: XCTestCase {
    func testConvertsEveryHumanReviewReplyToAutoSend() throws {
        let reply = ReplyEnvelope(
            decision: .humanReview,
            riskLevel: .high,
            replyText: "请立即停止使用，我们将为您转人工处理。",
            reason: "转人工：安全问题，设备冒烟"
        )

        let normalized = try ReplyRoutingPolicy.normalize(reply)

        XCTAssertEqual(normalized.decision, .autoSend)
        XCTAssertEqual(normalized.replyText, reply.replyText)
    }

    func testConvertsUnapprovedHumanReviewDraftToAutoSend() throws {
        let reply = ReplyEnvelope(
            decision: .humanReview,
            riskLevel: .medium,
            replyText: "您好，请问您的具体型号是什么？",
            reason: "型号不清楚"
        )

        let normalized = try ReplyRoutingPolicy.normalize(reply)

        XCTAssertEqual(normalized.decision, .autoSend)
        XCTAssertEqual(normalized.riskLevel, .low)
        XCTAssertEqual(normalized.replyText, "您好，请问您的具体型号是什么？")
    }

    func testConvertsNoActionReplyToAutoSend() throws {
        let reply = ReplyEnvelope(
            decision: .noAction,
            riskLevel: .low,
            replyText: "您好，请问有什么可以帮您？",
            reason: "没有未回复客户消息"
        )

        let normalized = try ReplyRoutingPolicy.normalize(reply)

        XCTAssertEqual(normalized.decision, .autoSend)
        XCTAssertEqual(normalized.replyText, "您好，请问有什么可以帮您？")
    }

    func testRejectsAnyReplyWithoutSendableText() {
        let reply = ReplyEnvelope(
            decision: .noAction,
            riskLevel: .low,
            replyText: "",
            reason: "没有内容"
        )

        XCTAssertThrowsError(try ReplyRoutingPolicy.normalize(reply))
    }

    func testLeavesNormalAutoSendUnchanged() throws {
        let reply = ReplyEnvelope(
            decision: .autoSend,
            riskLevel: .low,
            replyText: "您好",
            reason: "普通咨询"
        )

        XCTAssertEqual(try ReplyRoutingPolicy.normalize(reply), reply)
    }
}
