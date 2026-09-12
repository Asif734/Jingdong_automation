import XCTest
@testable import AutoReplyCore

final class DeliveryEvidenceTests: XCTestCase {
    func testOnlyExactServiceAuthoredTextConfirmsReply() {
        let history = """
        {"sender":"customer","t":"text","v":"同一句"}
        {"sender":"service","t":"text","v":"客服答案"}
        """
        XCTAssertTrue(DeliveryEvidence.exactServiceReplyFound(in: history, replyText: "客服答案"))
        XCTAssertFalse(DeliveryEvidence.exactServiceReplyFound(in: history, replyText: "同一句"))
        XCTAssertFalse(DeliveryEvidence.exactServiceReplyFound(in: history, replyText: "客服答"))
    }

    func testMatchingOldServiceReplyBeforeFrozenCustomerBoundaryIsIgnored() {
        let history = """
        {"sender":"customer","v":"old question"}
        {"sender":"service","v":"same reply"}
        {"sender":"customer","v":"new question"}
        """
        XCTAssertFalse(DeliveryEvidence.exactServiceReplyFound(
            in: history,
            replyText: "same reply",
            afterCustomerCount: 1
        ))

        let confirmed = history + "\n{\"sender\":\"service\",\"v\":\"same reply\"}\n"
        XCTAssertTrue(DeliveryEvidence.exactServiceReplyFound(
            in: confirmed,
            replyText: "same reply",
            afterCustomerCount: 1
        ))
    }
}
