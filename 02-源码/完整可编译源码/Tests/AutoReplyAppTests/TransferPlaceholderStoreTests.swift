import XCTest
@testable import AutoReplyApp
import CustomerReplyBatchCore

final class TransferPlaceholderStoreTests: XCTestCase {
    func testWritesUIDBoundNoOpPlaceholderIdempotently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferPlaceholderStore(root: root)
        let reply = ReplyEnvelope(
            action: .replyThenTransfer,
            replyText: "好的亲，我这边为您转人工处理。",
            transferReason: .customerExplicitlyRequestedHuman,
            reason: "客户明确要求人工"
        )

        let first = try store.record(
            uid: "buyer-1", customerRevision: "revision-7", reply: reply,
            now: Date(timeIntervalSince1970: 0)
        )
        let second = try store.record(
            uid: "buyer-1", customerRevision: "revision-7", reply: reply,
            now: Date(timeIntervalSince1970: 999)
        )

        XCTAssertEqual(first, second)
        let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 1)
        let value = try JSONDecoder().decode(TransferPlaceholder.self, from: Data(contentsOf: first))
        XCTAssertEqual(value.uid, "buyer-1")
        XCTAssertEqual(value.sourceCustomerRevision, "revision-7")
        XCTAssertEqual(value.transferReason, .customerExplicitlyRequestedHuman)
        XCTAssertEqual(value.state, "placeholder")
    }
}
