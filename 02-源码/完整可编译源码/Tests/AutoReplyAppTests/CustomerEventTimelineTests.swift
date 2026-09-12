import XCTest
import AutoReplyCore
@testable import AutoReplyApp

final class CustomerEventTimelineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("images"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func timeline(_ lines: [String]) throws -> CustomerEventTimeline {
        try CustomerEventTimeline(
            historyData: Data((lines.joined(separator: "\n") + "\n").utf8),
            userDirectory: directory
        )
    }

    private func text(_ request: String, _ sender: String, _ value: String) -> String {
        "{\"request_id\":\"\(request)\",\"sender\":\"\(sender)\",\"t\":\"text\",\"v\":\"\(value)\"}"
    }

    private func observedText(_ request: String, status: String) -> String {
        "{\"request_id\":\"\(request)\",\"sender\":\"customer\",\"t\":\"text\",\"v\":\"again\",\"timestamp\":\"2026-08-31 20:27:09\",\"read_status\":\"\(status)\"}"
    }

    func testServiceReplyAfterBCDoesNotMoveCustomerCursor() throws {
        let abc = try timeline([
            text("a", "customer", "A"),
            text("b", "customer", "B"),
            text("c", "customer", "C"),
        ])
        let withServiceTail = try timeline([
            text("a", "customer", "A"),
            text("b", "customer", "B"),
            text("c", "customer", "C"),
            text("reply-a", "service", "answer A"),
        ])

        XCTAssertEqual(withServiceTail.currentCursor, abc.currentCursor)
        XCTAssertEqual(withServiceTail.currentCursor.count, 3)
    }

    func testBatchAfterACursorContainsOnlyBandC() throws {
        let cursorA = try timeline([text("a", "customer", "A")]).currentCursor
        let full = try timeline([
            text("a", "customer", "A"),
            text("b", "customer", "B"),
            text("c", "customer", "C"),
            text("reply-a", "service", "answer A"),
        ])

        let batch = try full.batch(after: cursorA)

        XCTAssertEqual(batch.startCursor, cursorA)
        XCTAssertEqual(batch.endCursor, full.currentCursor)
        XCTAssertFalse(batch.targetJSONL.contains("\"v\":\"A\""))
        XCTAssertTrue(batch.targetJSONL.contains("\"v\":\"B\""))
        XCTAssertTrue(batch.targetJSONL.contains("\"v\":\"C\""))
        XCTAssertFalse(batch.targetJSONL.contains("answer A"))
        XCTAssertTrue(batch.hasNonImageContent)
    }

    func testPureImageBatchReportsNoNonImageFallbackContent() throws {
        try Data("photo".utf8).write(to: directory.appendingPathComponent("images/new.jpg"))
        let full = try timeline([
            "{\"request_id\":\"image\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/new.jpg\"}"
        ])

        let batch = try full.batch(after: .empty)

        XCTAssertFalse(batch.hasNonImageContent)
        XCTAssertEqual(batch.imageRelativePaths, ["images/new.jpg"])
    }

    func testRepeatedIdenticalCustomerTextHasTwoCursorPositions() throws {
        let once = try timeline([text("same", "customer", "again")])
        let twice = try timeline([
            text("same", "customer", "again"),
            text("same", "customer", "again"),
        ])

        XCTAssertEqual(once.currentCursor.count, 1)
        XCTAssertEqual(twice.currentCursor.count, 2)
        XCTAssertNotEqual(once.currentCursor.digest, twice.currentCursor.digest)
    }

    func testReadToUnreadRepeatedTextRemainsANewCursorEvent() throws {
        let first = try timeline([observedText("first", status: "已读")])
        let full = try timeline([
            observedText("first", status: "已读"),
            observedText("second", status: "未读"),
        ])

        let batch = try full.batch(after: first.currentCursor)

        XCTAssertEqual(full.currentCursor.count, 2)
        XCTAssertTrue(batch.targetJSONL.contains("\"request_id\":\"second\""))
    }

    func testImageCursorUsesBytesNotFilename() throws {
        try Data("same image".utf8).write(to: directory.appendingPathComponent("images/old.jpg"))
        try Data("same image".utf8).write(to: directory.appendingPathComponent("images/new.jpg"))
        let old = try timeline([
            "{\"request_id\":\"image\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/old.jpg\"}"
        ])
        let renamed = try timeline([
            "{\"request_id\":\"image\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/new.jpg\"}"
        ])

        XCTAssertEqual(old.currentCursor, renamed.currentCursor)
        try Data("different image".utf8).write(to: directory.appendingPathComponent("images/new.jpg"))
        XCTAssertNotEqual(old.currentCursor, try timeline([
            "{\"request_id\":\"image\",\"sender\":\"customer\",\"t\":\"image\",\"p\":\"images/new.jpg\"}"
        ]).currentCursor)
    }

    func testNonPrefixCursorIsRejected() throws {
        let full = try timeline([text("a", "customer", "A")])
        let forged = CustomerCursor(count: 1, digest: String(repeating: "f", count: 64))

        XCTAssertFalse(full.containsPrefix(forged))
        XCTAssertThrowsError(try full.batch(after: forged))
    }
}
