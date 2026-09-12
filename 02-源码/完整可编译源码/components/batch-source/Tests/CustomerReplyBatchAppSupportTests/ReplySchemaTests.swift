import XCTest
@testable import CustomerReplyBatchAppSupport

final class ReplySchemaTests: XCTestCase {
    func testSchemaAcceptsOnlyTwoActionsWithBoundedTransferReasons() throws {
        let schemaURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CustomerReplyBatchAppSupport/Resources/reply-output.schema.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
        )
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        let action = try XCTUnwrap(properties["action"] as? [String: Any])
        XCTAssertEqual(action["enum"] as? [String], ["reply", "reply_then_transfer"])
        let transferReason = try XCTUnwrap(properties["transfer_reason"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(transferReason["enum"] as? [String])), Set([
            "none", "customer_explicitly_requested_human", "explicit_return_refund",
            "remote_assistance", "refund_operation", "logistics_lookup",
            "troubleshooting_exhausted"
        ]))
        let replyText = try XCTUnwrap(properties["reply_text"] as? [String: Any])
        XCTAssertEqual(replyText["minLength"] as? Int, 1)
        XCTAssertEqual(Set(try XCTUnwrap(object["required"] as? [String])), Set([
            "action", "reply_text", "transfer_reason", "reason"
        ]))
    }
}
