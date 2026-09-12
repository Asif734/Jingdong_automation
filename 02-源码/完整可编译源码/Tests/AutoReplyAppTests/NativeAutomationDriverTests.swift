import XCTest
import AutoReplyCore
import CustomerReplyBatchCore
import QianniuOCRAppSupport
import QianniuOCRCore
import UnreadCore
@testable import AutoReplyApp

private actor RecognitionGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor DeliveryCheckpoint {
    private(set) var count = 0
    func record(_ date: Date) { count += 1 }
}

@MainActor private final class UI: NativeUIAutomation {
    let leaseRegistry = UIOperationLeaseRegistry()
    var operations: [String] = []
    var headers = ["tb263147182", "tb263147182"]
    var losesFocusDuringRecognition = false
    private var ownerIsFrontmost = true
    var safetyError: Error?
    var discovered = ["outsider", "tb263147182"]
    var unreadPages: [[String]]?
    var pageIndex = 0
    var unreadObservation = (hasUnread: false, latestPreviewIsImage: false)
    var unreadObservationGate: RecognitionGate?
    var recognizeImageFlags: [Bool] = []
    var recognitionGate: RecognitionGate?
    var recognitionResult: OCRRunResult?
    var deliveryResult: DeliveryResult = .sent
    var transferMenuDelay: Duration?
    func checkSafety() throws { if let safetyError { throw safetyError } }
    func discover(eligibleUIDs: Set<String>?, lease: UIOperationLease) async throws -> [String] {
        operations.append("discover")
        guard let unreadPages else { return discovered }
        let page = NativeDiscoveryPage(unreadUIDs: unreadPages[pageIndex], selectedUID: nil, eligibleUIDs: eligibleUIDs)
        return page.discoveredUIDs
    }
    func open(uid: String, lease: UIOperationLease) async throws { operations.append("open:\(uid)") }
    func header(lease: UIOperationLease) async throws -> String? {
        operations.append("header")
        guard ownerIsFrontmost else { throw AutomationDriverError.unsafeUI("千牛未在前台") }
        return headers.isEmpty ? nil : headers.removeFirst()
    }
    func recognize(stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        operations.append("recognize")
        if let recognitionGate { await recognitionGate.wait() }
        if losesFocusDuringRecognition { ownerIsFrontmost = false }
        return recognitionResult ?? fixture()
    }
    func observeUnread(uid: String, lease: UIOperationLease) async throws -> (hasUnread: Bool, latestPreviewIsImage: Bool) {
        operations.append("observeUnread:\(uid)")
        if let unreadObservationGate { await unreadObservationGate.wait() }
        return unreadObservation
    }
    func recognize(includeImages: Bool, lease: UIOperationLease,
                   stage: @escaping (OCRStage) -> Void) async throws -> OCRRunResult {
        recognizeImageFlags.append(includeImages)
        return try await recognize(stage: stage)
    }
    func activateForValidation(lease: UIOperationLease) async throws { operations.append("activateForValidation"); ownerIsFrontmost = true }
    func send(uid: String, text: String, lease: UIOperationLease) async throws -> DeliveryResult {
        operations.append("send:\(uid)"); return deliveryResult
    }
    func openTransferMenu(uid: String, lease: UIOperationLease) async throws {
        operations.append("openTransferMenu:\(uid)")
        if let transferMenuDelay { try await Task.sleep(for: transferMenuDelay) }
    }
}

private func fixture(header: String = "tb263147182", session: String? = "tb263147182", service: Bool = false) -> OCRRunResult {
    var lines = [
        OCRLine(text: "alice --> 店铺 2026-8-26 11:00:00", box: CGRect(x: 20, y: 80, width: 400, height: 20)),
        OCRLine(text: "怎么连接手机？", box: CGRect(x: 20, y: 110, width: 150, height: 20))
    ]
    if service { lines += [
        OCRLine(text: "加普威旗舰店:小丹 2026-8-26 11:01:00", box: CGRect(x: 220, y: 200, width: 260, height: 20)),
        OCRLine(text: "您好！", box: CGRect(x: 370, y: 230, width: 100, height: 20))
    ] }
    return OCRRunResult(lines: lines, sourceImageSize: CGSize(width: 500, height: 400),
        identityCandidates: CustomerIdentityCandidates(axHeader: header, axSessionList: session, ocr: nil))
}

@MainActor final class NativeAutomationDriverTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }

    func testArbitrarySafeUIDCanBeDiscoveredCapturedAndSent() async throws {
        let ui = UI()
        ui.discovered = ["outsider"]
        ui.headers = ["outsider", "outsider"]
        ui.recognitionResult = fixture(header: "outsider", session: "outsider")
        let driver = NativeAutomationDriver(ui: ui, root: root)

        let discovered = try await driver.discover()
        let capture = try await driver.capture(uid: "outsider")
        let delivery = try await driver.send(uid: "outsider", text: "reply")
        XCTAssertEqual(discovered, ["outsider"])
        XCTAssertTrue(capture.shouldGenerate)
        XCTAssertEqual(delivery, .sent)
        XCTAssertTrue(ui.operations.contains("send:outsider"))
    }

    func testOpenedVideoCompletesCaptureWithoutHistoryExportPostValidationOrAITask() async throws {
        let ui = UI()
        ui.headers = ["tb263147182", "tb263147182"]
        ui.recognitionResult = OCRRunResult(
            lines: [
                OCRLine(
                    text: "tb263147182 --> 店铺 2026-9-1 16:00:00",
                    box: CGRect(x: 20, y: 80, width: 300, height: 20)
                )
            ],
            images: [],
            sourceImageSize: CGSize(width: 500, height: 400),
            identityCandidates: CustomerIdentityCandidates(
                axHeader: "tb263147182",
                axSessionList: "tb263147182",
                ocr: nil
            ),
            mediaDisposition: .videoHandled(messageID: "VIDEO.105", outcome: .opened)
        )
        let driver = NativeAutomationDriver(ui: ui, root: root)

        let capture = try await driver.capture(uid: "tb263147182")

        XCTAssertFalse(capture.shouldGenerate)
        XCTAssertFalse(capture.hasUnansweredCustomer)
        XCTAssertNotEqual(capture.customerRevision, "video:VIDEO.105")
        XCTAssertTrue(capture.customerRevision.hasPrefix("video:"))
        XCTAssertEqual(capture.customerRevision.count, 70)
        XCTAssertEqual(capture.startCursor, .empty)
        XCTAssertEqual(capture.endCursor, .empty)
        XCTAssertEqual(ui.operations, ["open:tb263147182", "header", "activateForValidation", "recognize"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "A video must not enter history export")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("待处理/tb263147182.json").path
            )
        )
    }
    func testConfirmedDeliveryInvokesProfileCheckpointButUncertainDoesNot() async throws {
        let sentUI = UI()
        let checkpoint = DeliveryCheckpoint()
        let sentDriver = NativeAutomationDriver(
            ui: sentUI,
            root: root,
            onConfirmedDelivery: { date in await checkpoint.record(date) }
        )
        _ = try await sentDriver.send(uid: "tb263147182", text: "reply")
        let afterSent = await checkpoint.count
        XCTAssertEqual(afterSent, 1)

        let uncertainUI = UI()
        uncertainUI.deliveryResult = .uncertain("回读超时")
        let uncertainDriver = NativeAutomationDriver(
            ui: uncertainUI,
            root: root,
            onConfirmedDelivery: { date in await checkpoint.record(date) }
        )
        _ = try await uncertainDriver.send(uid: "tb263147182", text: "reply")
        let afterUncertain = await checkpoint.count
        XCTAssertEqual(afterUncertain, 1)
    }
    func testTransferPlaceholderReopensVerifiesAndOpensOnlyTheTransferMenu() async throws {
        let ui = UI()
        ui.headers = ["tb263147182"]
        let driver = NativeAutomationDriver(ui: ui, root: root)
        let reply = ReplyEnvelope(
            action: .replyThenTransfer,
            replyText: "好的亲，我帮您转人工处理。",
            transferReason: .customerExplicitlyRequestedHuman,
            reason: "客户明确要求人工"
        )

        try await driver.recordTransferPlaceholder(
            uid: "tb263147182",
            customerRevision: "revision-1",
            reply: reply
        )

        XCTAssertEqual(
            ui.operations,
            ["open:tb263147182", "header", "openTransferMenu:tb263147182"]
        )
    }
    func testTransferPopupOCRUsesRecognitionDeadlineInsteadOfShortOpenDeadline() async throws {
        let ui = UI()
        ui.headers = ["tb263147182"]
        ui.transferMenuDelay = .milliseconds(40)
        let driver = NativeAutomationDriver(
            ui: ui,
            root: root,
            deadlines: NativeOperationDeadlines(
                discovery: .seconds(1),
                openIdentity: .milliseconds(10),
                recognition: .milliseconds(100),
                preSendEvidence: .seconds(1),
                sendInvocation: .seconds(1)
            )
        )
        let reply = ReplyEnvelope(
            action: .replyThenTransfer,
            replyText: "好的亲，我帮您转人工处理。",
            transferReason: .customerExplicitlyRequestedHuman,
            reason: "客户明确要求人工"
        )

        try await driver.recordTransferPlaceholder(
            uid: "tb263147182",
            customerRevision: "revision-deadline",
            reply: reply
        )

        XCTAssertEqual(ui.operations.last, "openTransferMenu:tb263147182")
    }
    func testVisibleExcludedUnreadIsIgnoredWithoutPagination() {
        let first = NativeDiscoveryPage(unreadUIDs: ["outsider"], selectedUID: "outsider", eligibleUIDs: ["tb263147182"])
        XCTAssertEqual(first.discoveredUIDs, [])
    }
    func testSelectedCustomerWithoutVisibleRedDotIsNotDiscovered() {
        let page = NativeDiscoveryPage(unreadUIDs: [], selectedUID: "tb263147182", eligibleUIDs: ["tb263147182"])
        XCTAssertEqual(page.discoveredUIDs, [])
    }
    func testDiscoveryKeepsVisibleUnreadWithoutSearchingOffscreenPages() async throws {
        let ui = UI(); ui.unreadPages = [["outsider"], ["tb263147182"]]
        let driver = NativeAutomationDriver(ui: ui, root: root)
        let first = try await driver.discover()
        let second = try await driver.discover()
        XCTAssertEqual(first, ["outsider"])
        XCTAssertEqual(second, ["outsider"])
        XCTAssertEqual(ui.pageIndex, 0)
        XCTAssertEqual(ui.operations, ["discover", "discover"])
    }
    func testVisibleRedDotPollingIntervalIsOneSecond() {
        XCTAssertEqual(LiveNativeUI.discoveryInterval, 1)
    }
    func testOuterSendTransactionDeadlineDoesNotPreemptPressAndVerificationDeadlines() {
        XCTAssertEqual(NativeOperationDeadlines.live.sendInvocation, .seconds(15))
    }
    func testVisibleConversationRowIsChosenBeforeSearchFallback() {
        let target = ConversationRow(
            nodeID: 7,
            uid: "tb263147182",
            frame: CGRect(x: 60, y: 280, width: 210, height: 48)
        )
        let other = ConversationRow(
            nodeID: 8,
            uid: "stoneshishininger",
            frame: CGRect(x: 60, y: 328, width: 210, height: 48)
        )

        XCTAssertEqual(
            ConversationOpenRoute.visibleRow(uid: "tb263147182", rows: [other, target])?.nodeID,
            target.nodeID
        )
        XCTAssertNil(ConversationOpenRoute.visibleRow(uid: "missing", rows: [other, target]))
    }
    func testHeaderMismatchStopsBeforeOCRAndNeverWritesHistory() async throws {
        let ui = UI(); ui.headers = ["other"]
        let driver = NativeAutomationDriver(ui: ui, root: root)
        do { _ = try await driver.capture(uid: "tb263147182"); XCTFail("must fail exact UID check") }
        catch { XCTAssertTrue(error is AutomationDriverError) }
        XCTAssertEqual(ui.operations, ["open:tb263147182", "header"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testIdentityRecheckedAfterOCRBeforeDurableExport() async throws {
        let ui = UI(); ui.headers = ["tb263147182", "other"]
        let driver = NativeAutomationDriver(ui: ui, root: root)
        do { _ = try await driver.capture(uid: "tb263147182"); XCTFail("must fail post-OCR check") }
        catch { XCTAssertTrue(error is AutomationDriverError) }
        XCTAssertEqual(ui.operations, ["open:tb263147182", "header", "activateForValidation", "recognize", "activateForValidation", "header"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testRecognitionFocusTheftIsRestoredBeforePostOCRIdentityCheck() async throws {
        let ui = UI(); ui.losesFocusDuringRecognition = true
        let driver = NativeAutomationDriver(ui: ui, root: root)

        let capture = try await driver.capture(uid: "tb263147182")

        XCTAssertTrue(capture.shouldGenerate)
        XCTAssertTrue(capture.historyJSONL.contains("怎么连接手机"))
        XCTAssertEqual(ui.operations, ["open:tb263147182", "header", "activateForValidation", "recognize", "activateForValidation", "header"])
    }

    func testActionStagesRestoreReceptionFocusImmediatelyBeforeTouchingTheUI() async throws {
        let captureUI = UI()
        let captureDriver = NativeAutomationDriver(ui: captureUI, root: root.appendingPathComponent("capture"))
        _ = try await captureDriver.capture(uid: "tb263147182")
        XCTAssertEqual(
            Array(captureUI.operations.prefix(4)),
            ["open:tb263147182", "header", "activateForValidation", "recognize"]
        )

        let preSendUI = UI()
        let preSendDriver = NativeAutomationDriver(ui: preSendUI, root: root.appendingPathComponent("pre-send"))
        _ = try await preSendDriver.captureBeforeDelivery(uid: "tb263147182")
        XCTAssertEqual(
            Array(preSendUI.operations.prefix(2)),
            ["activateForValidation", "observeUnread:tb263147182"]
        )

        let sendUI = UI()
        let sendDriver = NativeAutomationDriver(ui: sendUI, root: root.appendingPathComponent("send"))
        _ = try await sendDriver.send(uid: "tb263147182", text: "reply")
        XCTAssertEqual(sendUI.operations, ["activateForValidation", "send:tb263147182"])
    }

    func testExpiredCaptureRevokesLeaseAndLateOCRCannotContinueToValidationOrPersistence() async throws {
        let ui = UI(), gate = RecognitionGate()
        ui.recognitionGate = gate
        let driver = NativeAutomationDriver(
            ui: ui,
            root: root,
            deadlines: NativeOperationDeadlines(
                discovery: .seconds(1),
                openIdentity: .seconds(1),
                recognition: .milliseconds(30),
                preSendEvidence: .seconds(1),
                sendInvocation: .seconds(1)
            )
        )

        do {
            _ = try await driver.capture(uid: "tb263147182")
            XCTFail("capture must hit its hard recognition deadline")
        } catch let timeout as OperationTimeout {
            XCTAssertEqual(timeout.stage, "ocr-recognition")
        }

        await gate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(ui.operations, ["open:tb263147182", "header", "activateForValidation", "recognize"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    // Catches old visible images being copied again when no customer message
    // arrived while the AI was generating.
    func testPreSendCaptureSkipsImagesWithoutANewUnreadDot() async throws {
        let ui = UI()
        let driver = NativeAutomationDriver(ui: ui, root: root)

        _ = try await driver.captureBeforeDelivery(uid: "tb263147182")

        XCTAssertEqual(ui.recognizeImageFlags, [false])
        XCTAssertEqual(ui.operations, ["activateForValidation", "observeUnread:tb263147182", "open:tb263147182", "header",
                                       "activateForValidation", "recognize", "activateForValidation", "header"])
    }

    // Text can be the latest preview even when the customer sent image+text.
    // Any new unread dot therefore keeps image collection enabled; `[图片]`
    // is informative but not an exclusive gate.
    func testPreSendCaptureKeepsImagesForUnreadTextOrUnreadImage() async throws {
        for marker in [false, true] {
            let ui = UI()
            ui.unreadObservation = (hasUnread: true, latestPreviewIsImage: marker)
            let driver = NativeAutomationDriver(ui: ui, root: root.appendingPathComponent(marker ? "image" : "text"))

            _ = try await driver.captureBeforeDelivery(uid: "tb263147182")

            XCTAssertEqual(ui.recognizeImageFlags, [true])
            XCTAssertEqual(Array(ui.operations.prefix(2)), ["activateForValidation", "observeUnread:tb263147182"])
        }
    }
    func testCapturedResultUsesRealExporterAndRecoversExistingPointer() async throws {
        let ui = UI(); ui.headers += ui.headers
        let driver = NativeAutomationDriver(ui: ui, root: root)
        let first = try await driver.capture(uid: "tb263147182")
        XCTAssertTrue(first.shouldGenerate)
        XCTAssertTrue(first.historyJSONL.contains("怎么连接手机"))
        let retry = try await driver.capture(uid: "tb263147182")
        XCTAssertTrue(retry.shouldGenerate)
        XCTAssertEqual(first.customerRevision, retry.customerRevision)
    }
    func testCaptureUsesServiceAliasesFromItsStartEvenIfConfigurationChangesMidOCR() async throws {
        let ui = UI(), gate = RecognitionGate()
        ui.recognitionGate = gate
        ui.recognitionResult = OCRRunResult(lines: [
            OCRLine(text: "加普威旗舰店:小丹 2026-8-26 11:01:00", box: CGRect(x: 20, y: 80, width: 300, height: 20)),
            OCRLine(text: "旧名称仍应判为客服", box: CGRect(x: 20, y: 110, width: 180, height: 20))
        ], sourceImageSize: CGSize(width: 500, height: 400),
           identityCandidates: CustomerIdentityCandidates(axHeader: "tb263147182", axSessionList: "tb263147182", ocr: nil))
        let driver = NativeAutomationDriver(ui: ui, root: root)
        driver.serviceAliases = ["小丹"]

        let captureTask = Task { try await driver.capture(uid: "tb263147182") }
        for _ in 0..<50 {
            if ui.operations.contains("recognize") { break }
            await Task.yield()
        }
        driver.serviceAliases = ["小秦"]
        await gate.release()
        let capture = try await captureTask.value

        let senders = try capture.historyJSONL.split(separator: "\n").map { line in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(object["sender"] as? String)
        }
        XCTAssertEqual(senders, ["service"])
    }
    func testPreSendCaptureUsesServiceAliasesFromBeforeUnreadObservation() async throws {
        let ui = UI(), gate = RecognitionGate()
        ui.unreadObservationGate = gate
        ui.recognitionResult = OCRRunResult(lines: [
            OCRLine(text: "加普威旗舰店:小丹 2026-8-26 11:01:00", box: CGRect(x: 20, y: 80, width: 300, height: 20)),
            OCRLine(text: "发送前复核也必须使用开始时的名称", box: CGRect(x: 20, y: 110, width: 240, height: 20))
        ], sourceImageSize: CGSize(width: 500, height: 400),
           identityCandidates: CustomerIdentityCandidates(axHeader: "tb263147182", axSessionList: "tb263147182", ocr: nil))
        let driver = NativeAutomationDriver(ui: ui, root: root)
        driver.serviceAliases = ["小丹"]

        let captureTask = Task { try await driver.captureBeforeDelivery(uid: "tb263147182") }
        for _ in 0..<50 {
            if ui.operations.contains("observeUnread:tb263147182") { break }
            await Task.yield()
        }
        driver.serviceAliases = ["小秦"]
        await gate.release()
        let capture = try await captureTask.value

        let senders = try capture.historyJSONL.split(separator: "\n").map { line in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(object["sender"] as? String)
        }
        XCTAssertEqual(senders, ["service"])
    }
    func testUnsafeOperatorCheckBlocksEveryUIEntry() async throws {
        let ui = UI(); ui.safetyError = AutomationDriverError.unsafeUI("old worker")
        let driver = NativeAutomationDriver(ui: ui, root: root)
        do { _ = try await driver.discover(); XCTFail() } catch {}
        do { _ = try await driver.capture(uid: "tb263147182"); XCTFail() } catch {}
        do { _ = try await driver.send(uid: "tb263147182", text: "reply"); XCTFail() } catch {}
        XCTAssertTrue(ui.operations.isEmpty)
    }
    func testBridgeRejectsConflictingAndPathUnsafeIdentityWithoutExport() async throws {
        let bridge = AutomationCaptureBridge(rootDirectory: root)
        for result in [fixture(session: "other"), fixture(header: "../escape", session: "../escape")] {
            do { _ = try await bridge.export(result: result, expectedUID: result.identityCandidates.axHeader!); XCTFail() } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testBridgeUsesConfirmedRoutedUIDInsteadOfChineseDisplayHeaderForStorage() async throws {
        let result = fixture(header: "优满仓进出口农资", session: nil)
        let receipt = try await AutomationCaptureBridge(rootDirectory: root).export(
            result: result,
            expectedUID: "tb235692326486",
            routedIdentityConfirmed: true
        )

        XCTAssertEqual(receipt.uid, "tb235692326486")
        XCTAssertEqual(receipt.historyURL.path, root.appendingPathComponent("用户/tb235692326486/history.jsonl").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("用户/优满仓进出口农资").path))
    }
    func testBridgeKeepsCustomerQueueWhenLatestParsedSpeakerIsService() async throws {
        let result = try await AutomationCaptureBridge(rootDirectory: root).export(result: fixture(service: true), expectedUID: "tb263147182")
        XCTAssertEqual(result.latestSpeaker, "service")
        XCTAssertEqual(result.historyURL.path, root.appendingPathComponent("用户/tb263147182/history.jsonl").path)
        XCTAssertNotNil(result.queueEntryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.historyURL.path))
    }
    func testReadStatusReExportReusesTheVisibleCustomerEvent() async throws {
        let bridge = AutomationCaptureBridge(rootDirectory: root)
        func observation(_ status: String) -> OCRRunResult {
            let base = fixture()
            return OCRRunResult(lines: base.lines.map { line in
                OCRLine(text: line.text.contains("怎么连接") ? line.text + status : line.text, box: line.box)
            }, sourceImageSize: base.sourceImageSize, identityCandidates: base.identityCandidates)
        }
        let first = try await bridge.export(result: observation("未读"), expectedUID: "tb263147182")
        let history = CapturedHistory(root: root)
        let before = try history.snapshot(uid: first.uid, latestSpeaker: first.latestSpeaker, newlyQueued: first.queueEntryURL != nil)
        let second = try await bridge.export(result: observation("已读"), expectedUID: "tb263147182")
        let pending = try XCTUnwrap(second.queueEntryURL)
        let observed = try history.snapshot(uid: second.uid, latestSpeaker: second.latestSpeaker, newlyQueued: true)
        XCTAssertEqual(observed.customerRevision, before.customerRevision)
        XCTAssertNoThrow(try history.complete(uid: first.uid, revision: before.customerRevision))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertTrue(try String(contentsOf: second.historyURL, encoding: .utf8).contains("已读"), "Keep exporter evidence verbatim")
    }
}
