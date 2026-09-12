import XCTest
import QianniuSenderCore
@testable import AutoReplyApp

final class AutomationSafetyTests: XCTestCase {
    private func node(id: Int, parentID: Int? = nil, role: String, description: String? = nil, frame: CGRect) -> SenderAXNode {
        SenderAXNode(id: id, parentID: parentID, role: role, title: nil, description: description, value: nil, frame: frame, isEnabled: true)
    }
    func testSingletonHeldUntilOwnerLifetimeEndsAndStaleFileDoesNotBlock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.lock")
        try Data("stale metadata".utf8).write(to: url)
        var first: SessionLock? = try SessionLock(url: url)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try SessionLock(url: url))
        first = nil
        XCTAssertNoThrow(try SessionLock(url: url))
    }
    func testOldOperatorsAndOnlyOurOrphanSchemaBlockStart() {
        let schema = "/isolated records/运行状态/automatic-output.schema.json"
        for command in ["/Applications/旧版.app/Contents/MacOS/UnreadApp", "/usr/local/bin/QianniuOCRApp", "/tmp/CustomerReplyBatchApp",
            "/tmp/QianniuAutoSender --queue /old", "/Applications/AI客服.app/Contents/MacOS/AI客服-Codex批处理",
            "/Applications/OCR.app/Contents/MacOS/千牛主聊天区OCR-PlanB", "/Applications/Sender.app/Contents/MacOS/千牛自动发送",
            "codex exec --output-schema \(schema) -"] {
            XCTAssertTrue(OperatorProcessPolicy.blocks(command, schemaPath: schema), command)
        }
        for command in ["/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", "codex exec --output-schema /another/schema.json -",
            "/bin/zsh -c rg QianniuOCRApp", "codex exec --output-schema \(schema).backup -", "/new/AutoReplyApp"] {
            XCTAssertFalse(OperatorProcessPolicy.blocks(command, schemaPath: schema), command)
        }
    }
    func testQuitWaitsForUIAndOwnedCleanupWithoutKillingAnything() {
        XCTAssertFalse(QuitPolicy.mayTerminate(uiActive: true, liveGenerations: 0))
        XCTAssertFalse(QuitPolicy.mayTerminate(uiActive: false, liveGenerations: 1))
        XCTAssertTrue(QuitPolicy.mayTerminate(uiActive: false, liveGenerations: 0))
    }
    func testSearchClearSelectionCannotChooseMessageComposer() {
        let window = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let composer = node(id: 1, role: "AXTextArea", description: "联系人、订单号、聊天记录", frame: CGRect(x: 500, y: 600, width: 400, height: 100))
        let search = node(id: 2, role: "AXTextField", description: "联系人、订单号、聊天记录", frame: CGRect(x: 130, y: 160, width: 200, height: 30))
        XCTAssertNil(ConversationListSelection.searchField(nodes: [composer], window: window))
        XCTAssertEqual(ConversationListSelection.searchField(nodes: [composer, search], window: window)?.id, 2)
        let duplicate = node(id: 3, role: "AXTextField", description: "联系人、订单号、聊天记录", frame: search.frame)
        XCTAssertNil(ConversationListSelection.searchField(nodes: [composer, search, duplicate], window: window))
    }
    func testScrollUsesFreshCommonListAncestorNotChatPanel() {
        let window = CGRect(x: 100, y: 100, width: 1000, height: 700)
        let nodes = [
            node(id: 1, role: "AXScrollArea", frame: CGRect(x: 110, y: 200, width: 250, height: 500)),
            node(id: 2, parentID: 1, role: "AXGroup", frame: CGRect(x: 120, y: 210, width: 230, height: 50)),
            node(id: 3, parentID: 1, role: "AXGroup", frame: CGRect(x: 120, y: 260, width: 230, height: 50)),
            node(id: 4, role: "AXScrollArea", frame: CGRect(x: 400, y: 200, width: 650, height: 400))
        ]
        XCTAssertEqual(ConversationListSelection.scrollContainer(nodes: nodes, rowIDs: [2,3], window: window)?.id, 1)
        XCTAssertNil(ConversationListSelection.scrollContainer(nodes: nodes, rowIDs: [2,99], window: window))
    }

    func testFocusedReceptionWindowWinsWithoutRequiringItToBeTheOnlyReceptionWindow() {
        let windows = [
            ReceptionWindowDescriptor(title: "小丹-接待中心", frame: CGRect(x: 0, y: 0, width: 1000, height: 700), minimized: false),
            ReceptionWindowDescriptor(title: "小艳-接待中心", frame: CGRect(x: 100, y: 80, width: 1000, height: 700), minimized: false)
        ]
        XCTAssertEqual(ReceptionWindowSelection.index(in: windows, focusedIndex: 1), 1)
        XCTAssertNil(ReceptionWindowSelection.index(in: windows, focusedIndex: nil))
        XCTAssertEqual(ReceptionWindowSelection.index(in: [windows[0]], focusedIndex: nil), 0)
    }

    func testCaptureWindowGeometryAllowsOnlyTheObservedTitleBarCoordinateOffset() {
        let accessibility = CGRect(x: 94, y: 61, width: 1417, height: 843)
        XCTAssertTrue(ReceptionWindowGeometry.matches(accessibility: accessibility,
                                                      capture: CGRect(x: 94, y: 80, width: 1417, height: 843)))
        XCTAssertTrue(ReceptionWindowGeometry.matches(accessibility: accessibility, capture: accessibility))
        XCTAssertFalse(ReceptionWindowGeometry.matches(accessibility: accessibility,
                                                       capture: CGRect(x: 94, y: 110, width: 1417, height: 843)))
        XCTAssertTrue(ReceptionWindowGeometry.matches(accessibility: accessibility,
                                                      capture: CGRect(x: 95, y: 80, width: 1417, height: 843)))
        XCTAssertTrue(ReceptionWindowGeometry.matches(accessibility: accessibility,
                                                      capture: CGRect(x: 94, y: 80, width: 1416, height: 843)))
        XCTAssertFalse(ReceptionWindowGeometry.matches(accessibility: accessibility,
                                                       capture: CGRect(x: 98, y: 80, width: 1417, height: 843)))
    }

    func testCaptureUsesOnePixelPerWindowPointAcrossMixedScaleDisplays() {
        XCTAssertEqual(
            WindowCaptureGeometry.outputSize(for: CGRect(x: -1278, y: 190, width: 1310, height: 800)),
            CGSize(width: 1310, height: 800)
        )
    }
}
