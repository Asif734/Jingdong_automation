import XCTest
@testable import AutoReplyCore
import CustomerReplyBatchAppSupport
import CustomerReplyBatchCore

private enum TestFailure: Error { case capture, send }

private actor ControlledGenerator: ReplyGenerating {
    private(set) var inputs: [PromptInput] = []
    private var pending: [String: [CheckedContinuation<GeneratedReply, Error>]] = [:]
    func generate(for input: PromptInput) async throws -> GeneratedReply {
        inputs.append(input)
        return try await withCheckedThrowingContinuation { pending[input.uid, default: []].append($0) }
    }
    var startedUIDs: [String] { inputs.map(\.uid) }
    func complete(
        _ uid: String,
        text: String? = nil,
        reply: ReplyEnvelope? = nil,
        cleanup: Task<Void, Never>? = nil,
        timing: ReplyGenerationTiming = ReplyGenerationTiming()
    ) {
        guard var waits = pending[uid], !waits.isEmpty else { return }
        let first = waits.removeFirst(); pending[uid] = waits
        first.resume(returning: GeneratedReply(reply: reply ?? ReplyEnvelope(decision: .autoSend, riskLevel: .low,
            replyText: text ?? "answer-\(uid)", reason: "fixture"), timing: timing, cleanupTask: cleanup))
    }
    func fail(_ uid: String, error: Error = TestFailure.capture) {
        guard var waits = pending[uid], !waits.isEmpty else { return }
        let first = waits.removeFirst(); pending[uid] = waits
        first.resume(throwing: error)
    }
    func finishAll() {
        for waits in pending.values { for wait in waits { wait.resume(throwing: CancellationError()) } }
        pending.removeAll()
    }
}

private actor Gate {
    var open = false
    var waits: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waits.append($0) }
    }
    func release() { open = true; waits.forEach { $0.resume() }; waits.removeAll() }
}

@MainActor private final class ControlledDriver: AutomationDriver {
    var unread: [String] = []
    var snapshots: [String: CaptureSnapshot] = [:]
    var captureGates: [String: Gate] = [:]
    var captureError = false
    var captureErrorsRemainingByUID: [String: Int] = [:]
    var unsafeCaptureError = false
    var unsafeCaptureMessage = "competing operator"
    var captureAutomationError: AutomationDriverError?
    var discoveryErrorsRemaining = 0
    var delivery: DeliveryResult = .sent
    var reconciliationObservations: [DeliveryObservation] = []
    var sendError = false
    var operations: [String] = []
    var captureImageFlags: [Bool] = []
    var active = 0
    var maximumActive = 0
    var sendCheck: (() throws -> Void)?
    var revokeCount = 0
    var transferPlaceholders: [(uid: String, revision: String, reason: TransferReason)] = []
    var transferPlaceholderError: Error?
    func revokeUIOperations() { revokeCount += 1 }
    func enter(_ operation: String) { operations.append(operation); active += 1; maximumActive = max(maximumActive, active) }
    func discover() async throws -> [String] {
        enter("discover"); defer { active -= 1 }
        if discoveryErrorsRemaining > 0 {
            discoveryErrorsRemaining -= 1
            throw AutomationDriverError.unsafeUI("conversation list changed")
        }
        let result = unread; unread = []; return result
    }
    func capture(uid: String, after cursor: CustomerCursor) async throws -> CaptureSnapshot {
        try await captureImpl(uid: uid)
    }
    func capture(uid: String, after cursor: CustomerCursor, includeImages: Bool) async throws -> CaptureSnapshot {
        captureImageFlags.append(includeImages)
        return try await captureImpl(uid: uid)
    }
    private func captureImpl(uid: String) async throws -> CaptureSnapshot {
        enter("capture:\(uid)"); defer { active -= 1 }
        if let gate = captureGates[uid] { await gate.wait() }
        if let captureAutomationError { throw captureAutomationError }
        if let remaining = captureErrorsRemainingByUID[uid], remaining > 0 {
            captureErrorsRemainingByUID[uid] = remaining - 1
            throw TestFailure.capture
        }
        if unsafeCaptureError { throw AutomationDriverError.unsafeUI(unsafeCaptureMessage) }
        if captureError { throw TestFailure.capture }
        return snapshots[uid] ?? Self.snapshot(uid)
    }
    func captureBeforeDelivery(uid: String, after cursor: CustomerCursor) async throws -> CaptureSnapshot {
        enter("captureBeforeDelivery:\(uid)"); defer { active -= 1 }
        if let gate = captureGates[uid] { await gate.wait() }
        if unsafeCaptureError { throw AutomationDriverError.unsafeUI(unsafeCaptureMessage) }
        if captureError { throw TestFailure.capture }
        return snapshots[uid] ?? Self.snapshot(uid)
    }
    func send(uid: String, text: String) async throws -> DeliveryResult {
        enter("send:\(uid):\(text)"); defer { active -= 1 }
        try sendCheck?()
        if sendError { throw TestFailure.send }
        return delivery
    }
    func recordTransferPlaceholder(uid: String, customerRevision: String, reply: ReplyEnvelope) async throws {
        if let transferPlaceholderError { throw transferPlaceholderError }
        operations.append("transfer:\(uid)")
        transferPlaceholders.append((uid, customerRevision, reply.transferReason))
    }
    func reconcile(uid: String, replyText: String, after cursor: CustomerCursor) async throws -> DeliveryObservation {
        enter("reconcile:\(uid):\(replyText)"); defer { active -= 1 }
        return reconciliationObservations.isEmpty ? .unavailable : reconciliationObservations.removeFirst()
    }
    static func snapshot(_ uid: String, revision: String = "r1", history: String = "customer question",
                         unanswered: Bool = true, generate: Bool = true) -> CaptureSnapshot {
        CaptureSnapshot(uid: uid, customerRevision: revision, historyJSONL: history,
            imagePaths: ["/frozen/\(uid).png"], knowledgeBasePaths: ["/kb.zip"],
            hasUnansweredCustomer: unanswered, shouldGenerate: generate)
    }
}

@MainActor private final class Clock {
    var value = Date(timeIntervalSince1970: 1_000)
}

@MainActor private final class Fixture {
    let root: URL
    let driver = ControlledDriver()
    let generator = ControlledGenerator()
    let store: SchedulerStore
    let scheduler: AutoReplyScheduler
    let clock = Clock()
    init(
        availableMemoryBytes: UInt64 = 40 << 30,
        initial: SchedulerPersistentState? = nil,
        stageDeadlines: SchedulerStageDeadlines = .production,
        onTerminalDelivery: @escaping @MainActor @Sendable (
            String, String, SchedulerDeliveryOutcome
        ) async -> Void = { _, _, _ in }
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("scheduler-test-\(UUID())")
        store = try SchedulerStore(rootURL: root)
        if let initial { try store.save(initial) }
        let clock = self.clock
        scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: store,
                                           availableMemoryBytes: { availableMemoryBytes },
                                           now: { clock.value }, stageDeadlines: stageDeadlines,
                                           onTerminalDelivery: onTerminalDelivery)
    }
    func drive(_ count: Int = 15) async {
        for _ in 0..<count {
            await scheduler.tick()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    func advanceAndTick(_ count: Int = 1) async {
        for _ in 0..<count {
            clock.value = clock.value.addingTimeInterval(1)
            await scheduler.tick()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    func start(_ uids: [String]) async { driver.unread = uids; scheduler.start(); await drive(30) }
    func shutdown() async { scheduler.stop(); await generator.finishAll(); await drive(2); try? FileManager.default.removeItem(at: root) }
}

private struct TerminalDeliveryValue: Equatable, Sendable {
    let uid: String
    let revision: String
    let outcome: SchedulerDeliveryOutcome
}

private actor TerminalDeliveryRecorder {
    private(set) var values: [TerminalDeliveryValue] = []
    func record(uid: String, revision: String, outcome: SchedulerDeliveryOutcome) {
        values.append(TerminalDeliveryValue(uid: uid, revision: revision, outcome: outcome))
    }
}

@MainActor final class SchedulerTests: XCTestCase {
    func testPermanentCodexFailuresTransferImmediately() async throws {
        let failures: [(String, CodexGeneratorError)] = [
            ("401", .commandFailed(1, "unexpected status 401 Unauthorized")),
            ("403", .commandFailed(1, "HTTP 403 Forbidden")),
            ("429", .commandFailed(1, "HTTP 429 Too Many Requests")),
            ("credit", .commandFailed(1, "credit_balance_exhausted")),
            ("usage", .commandFailed(1, "organization_usage_limit_exceeded")),
            ("org spend", .commandFailed(1, "organization_spend_limit_exceeded")),
            ("project spend", .commandFailed(1, "project_spend_limit_exceeded")),
            ("quota", .commandFailed(1, "insufficient_quota")),
            ("model missing", .commandFailed(1, "model_not_found")),
            ("model unsupported", .commandFailed(1, "unsupported model")),
            ("400", .commandFailed(1, "HTTP 400 invalid_request_error")),
            ("413", .commandFailed(1, "HTTP 413 Payload Too Large")),
            ("422", .commandFailed(1, "HTTP 422 Unprocessable Entity")),
            ("context", .commandFailed(1, "maximum context length exceeded")),
            ("context code", .commandFailed(1, "context_length_exceeded")),
            ("missing CLI", .executableMissing),
            ("login", .chatGPTLoginRequired("尚未登录"))
        ]

        for (label, failure) in failures {
            let f = try Fixture()
            await f.start(["buyer"])
            await f.generator.fail("buyer", error: failure)
            await f.drive(60)
            let started = await f.generator.startedUIDs
            XCTAssertEqual(started, ["buyer"], label)
            XCTAssertEqual(f.driver.transferPlaceholders.count, 1, label)
            await f.shutdown()
        }
    }

    func testTransientCodexFailuresRetryOnceThenTransfer() async throws {
        let failures: [(String, CodexGeneratorError)] = [
            ("404", .commandFailed(1, "unexpected status 404 Not Found")),
            ("408", .commandFailed(1, "HTTP 408 Request Timeout")),
            ("500", .commandFailed(1, "HTTP 500 Internal Server Error")),
            ("502", .commandFailed(1, "HTTP 502 Bad Gateway")),
            ("503", .commandFailed(1, "HTTP 503 Service Unavailable")),
            ("504", .commandFailed(1, "HTTP 504 Gateway Timeout")),
            ("reset", .commandFailed(1, "connection reset by peer")),
            ("DNS", .commandFailed(1, "DNS lookup failed")),
            ("TLS", .commandFailed(1, "TLS handshake failed")),
            ("deadline", .commandFailed(124, "超过 Codex 硬时限")),
            ("crash", .commandFailed(139, "process crashed")),
            ("turn failed", .invalidReply("CLI 本轮生成失败")),
            ("malformed", .invalidReply("The data couldn’t be read because it isn’t in the correct format"))
        ]

        for (label, error) in failures {
            let f = try Fixture()
            await f.start(["buyer"])
            await f.generator.fail("buyer", error: error)
            await f.drive(20)
            XCTAssertTrue(f.driver.transferPlaceholders.isEmpty, label)

            f.clock.value = f.clock.value.addingTimeInterval(3)
            await f.drive(30)
            await f.generator.fail("buyer", error: error)
            await f.drive(60)

            let started = await f.generator.startedUIDs
            XCTAssertEqual(started, ["buyer", "buyer"], label)
            XCTAssertEqual(f.driver.transferPlaceholders.count, 1, label)
            await f.shutdown()
        }
    }

    func testConfirmed429CreatesCourtesyReplyAndIndependentTransferWithoutRetry() async throws {
        let f = try Fixture()
        await f.start(["buyer"])

        await f.generator.fail("buyer", error: CodexGeneratorError.commandFailed(
            1, "unexpected status 429 Too Many Requests"
        ))
        await f.drive(60)

        let startedUIDs = await f.generator.startedUIDs
        XCTAssertEqual(startedUIDs, ["buyer"])
        XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:buyer:") }.count, 1)
        XCTAssertEqual(f.driver.transferPlaceholders.count, 1)
        XCTAssertTrue(f.scheduler.isRunning)
        await f.shutdown()
    }

    func testContextTooLongTransfersImmediatelyWithoutShorteningOrRetryingHistory() async throws {
        let f = try Fixture()
        await f.start(["buyer"])

        await f.generator.fail("buyer", error: CodexGeneratorError.commandFailed(
            1, "maximum context length exceeded"
        ))
        await f.drive(60)

        let startedUIDs = await f.generator.startedUIDs
        XCTAssertEqual(startedUIDs, ["buyer"])
        XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:buyer:") }.count, 1)
        XCTAssertEqual(f.driver.transferPlaceholders.count, 1)
        await f.shutdown()
    }

    func testConfirmed404RetriesOnceThenCreatesCourtesyReplyAndTransfer() async throws {
        let f = try Fixture()
        let notFound = CodexGeneratorError.commandFailed(1, "unexpected status 404 Not Found")
        await f.start(["buyer"])

        await f.generator.fail("buyer", error: notFound)
        await f.drive(20)
        var startedUIDs = await f.generator.startedUIDs
        XCTAssertEqual(startedUIDs, ["buyer"])
        XCTAssertTrue(f.driver.transferPlaceholders.isEmpty)

        f.clock.value = f.clock.value.addingTimeInterval(3)
        await f.drive(30)
        startedUIDs = await f.generator.startedUIDs
        XCTAssertEqual(startedUIDs, ["buyer", "buyer"])

        await f.generator.fail("buyer", error: notFound)
        await f.drive(60)

        startedUIDs = await f.generator.startedUIDs
        XCTAssertEqual(startedUIDs, ["buyer", "buyer"])
        XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:buyer:") }.count, 1)
        XCTAssertEqual(f.driver.transferPlaceholders.count, 1)
        await f.shutdown()
    }

    func testReplyThenTransferSendsReplyAndCreatesOneNoOpPlaceholder() async throws {
        let f = try Fixture()
        await f.start(["buyer"])
        await f.generator.complete("buyer", reply: ReplyEnvelope(
            action: .replyThenTransfer,
            replyText: "好的亲，我这边为您转人工处理。",
            transferReason: .customerExplicitlyRequestedHuman,
            reason: "客户明确要求人工"
        ))

        await f.drive(30)

        XCTAssertTrue(f.driver.operations.contains("send:buyer:好的亲，我这边为您转人工处理。"))
        XCTAssertEqual(f.driver.transferPlaceholders.count, 1)
        XCTAssertEqual(f.driver.transferPlaceholders.first?.uid, "buyer")
        XCTAssertEqual(f.driver.transferPlaceholders.first?.revision, "r1")
        XCTAssertEqual(f.driver.transferPlaceholders.first?.reason, .customerExplicitlyRequestedHuman)
        XCTAssertEqual(f.scheduler.records.first?.state, .completed)
        await f.shutdown()
    }

    func testReplyThenTransferCreatesTwoDurableQueueRecordsBeforeUIWork() async throws {
        let f = try Fixture()
        await f.start(["buyer"])

        await f.generator.complete("buyer", reply: ReplyEnvelope(
            action: .replyThenTransfer,
            replyText: "好的亲，我这边为您转人工处理。",
            transferReason: .customerExplicitlyRequestedHuman,
            reason: "客户明确要求人工"
        ))

        for _ in 0..<30 {
            if f.scheduler.records.count == 2 { break }
            await f.scheduler.tick()
            await Task.yield()
        }

        XCTAssertEqual(f.scheduler.records.count, 2)
        XCTAssertEqual(f.scheduler.records.map(\.uid), ["buyer", "buyer"])
        XCTAssertEqual(f.scheduler.records.map(\.effectiveTaskKind), [.customerReply, .transfer])
        await f.shutdown()
    }

    func testReplyThenTransferStillTransfersWhenReplyFailsBeforeSend() async throws {
        let f = try Fixture()
        f.driver.delivery = .failedBeforeSend("button unavailable")
        await f.start(["buyer"])
        await f.generator.complete("buyer", reply: ReplyEnvelope(
            action: .replyThenTransfer,
            replyText: "好的亲，我这边为您转人工处理。",
            transferReason: .customerExplicitlyRequestedHuman,
            reason: "客户明确要求人工"
        ))

        await f.drive(60)

        XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:buyer:") }.count, 1)
        XCTAssertEqual(f.driver.transferPlaceholders.count, 1)
        XCTAssertLessThan(
            try XCTUnwrap(f.driver.operations.firstIndex(where: { $0.hasPrefix("send:buyer:") })),
            try XCTUnwrap(f.driver.operations.firstIndex(of: "transfer:buyer"))
        )
        XCTAssertTrue(f.scheduler.isRunning)
        await f.shutdown()
    }

    func testReplyThenTransferStillTransfersWhenReplyResultIsUncertain() async throws {
        let f = try Fixture()
        f.driver.delivery = .uncertain("bubble confirmation unavailable")
        await f.start(["buyer"])
        await f.generator.complete("buyer", reply: ReplyEnvelope(
            action: .replyThenTransfer,
            replyText: "好的亲，我这边为您转人工处理。",
            transferReason: .customerExplicitlyRequestedHuman,
            reason: "客户明确要求人工"
        ))

        await f.drive(60)

        XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:buyer:") }.count, 1)
        XCTAssertEqual(f.driver.transferPlaceholders.count, 1)
        XCTAssertLessThan(
            try XCTUnwrap(f.driver.operations.firstIndex(where: { $0.hasPrefix("send:buyer:") })),
            try XCTUnwrap(f.driver.operations.firstIndex(of: "transfer:buyer"))
        )
        XCTAssertTrue(f.scheduler.isRunning)
        await f.shutdown()
    }

    func testNormalReplyDoesNotCreateTransferPlaceholder() async throws {
        let f = try Fixture()
        await f.start(["buyer"])
        await f.generator.complete("buyer", reply: ReplyEnvelope(
            action: .reply,
            replyText: "您好，请先检查电源线。",
            transferReason: .none,
            reason: "普通排障"
        ))

        await f.drive(30)

        XCTAssertTrue(f.driver.operations.contains("send:buyer:您好，请先检查电源线。"))
        XCTAssertTrue(f.driver.transferPlaceholders.isEmpty)
        XCTAssertEqual(f.scheduler.records.first?.state, .completed)
        await f.shutdown()
    }

    func testPlaceholderWriteFailureNeverBlocksOrResendsReply() async throws {
        let f = try Fixture()
        f.driver.transferPlaceholderError = TestFailure.send
        await f.start(["buyer"])
        await f.generator.complete("buyer", reply: ReplyEnvelope(
            action: .replyThenTransfer,
            replyText: "好的亲，我这边为您转人工处理。",
            transferReason: .customerExplicitlyRequestedHuman,
            reason: "客户明确要求人工"
        ))

        await f.drive(30)

        XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:buyer:") }.count, 1)
        XCTAssertEqual(f.scheduler.records.first?.state, .completed)
        await f.shutdown()
    }
    func testPreparedReplyIsAdmittedOnceAndSendsWithoutCallingGenerator() async throws {
        let f = try Fixture()
        let revision = "video-download-fallback:safe-hash"
        let history = #"{"sender":"customer","t":"video","v":"download_failed"}"#
        let reply = ReplyEnvelope(
            decision: .autoSend,
            riskLevel: .low,
            replyText: "请重新发送视频",
            reason: "视频下载暂时失败"
        )

        let first = await f.scheduler.admitPreparedReply(
            uid: "buyer",
            customerRevision: revision,
            historyJSONL: history,
            reply: reply
        )
        let second = await f.scheduler.admitPreparedReply(
            uid: "buyer",
            customerRevision: revision,
            historyJSONL: history,
            reply: reply
        )

        XCTAssertEqual(first, .inserted)
        XCTAssertEqual(second, .alreadyPresent)
        XCTAssertEqual(f.scheduler.records.count, 1)
        XCTAssertEqual(f.scheduler.records.first?.state, .ready)
        XCTAssertNotNil(f.scheduler.records.first?.snapshot)
        f.scheduler.start()
        await f.drive(20)
        XCTAssertTrue(f.driver.operations.contains("send:buyer:请重新发送视频"))
        let generatorInputs = await f.generator.inputs
        XCTAssertTrue(generatorInputs.isEmpty)
        await f.shutdown()
    }

    func testExternalDiscoveryIsDeduplicatedAndDoesNotGenerateBeforeCapture() async throws {
        let f = try Fixture()

        let first = await f.scheduler.admitExternalDiscovery(
            uid: "buyer",
            sourceRevision: "video-address-refresh:hash"
        )
        let second = await f.scheduler.admitExternalDiscovery(
            uid: "buyer",
            sourceRevision: "video-address-refresh:hash"
        )

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(f.scheduler.records.count, 1)
        XCTAssertEqual(f.scheduler.records.first?.state, .discovered)
        XCTAssertEqual(f.scheduler.records.first?.sourceRevision, "video-address-refresh:hash")
        let generatorInputs = await f.generator.inputs
        XCTAssertTrue(generatorInputs.isEmpty)
        await f.shutdown()
    }

    func testConfirmedPreparedDeliveryNotifiesTerminalObserverAfterDurableCompletion() async throws {
        let observer = TerminalDeliveryRecorder()
        let f = try Fixture(onTerminalDelivery: { uid, revision, outcome in
            await observer.record(uid: uid, revision: revision, outcome: outcome)
        })
        _ = await f.scheduler.admitPreparedReply(
            uid: "buyer",
            customerRevision: "video-analysis:hash",
            historyJSONL: #"{"sender":"customer","t":"video","v":"ready"}"#,
            reply: ReplyEnvelope(
                decision: .autoSend,
                riskLevel: .low,
                replyText: "视频回复",
                reason: "fixture"
            )
        )
        f.scheduler.start()

        await f.drive(30)

        let values = await observer.values
        XCTAssertEqual(values, [TerminalDeliveryValue(
            uid: "buyer",
            revision: "video-analysis:hash",
            outcome: .sent
        )])
        XCTAssertEqual(f.scheduler.records.first?.state, .completed)
        await f.shutdown()
    }

    func testExternalSnapshotIsQueuedOnceWithoutUsingTheUILane() async throws {
        let f = try Fixture()
        let snapshot = ControlledDriver.snapshot("video-buyer", revision: "video-analysis:abc")

        await f.scheduler.admitExternalSnapshot(snapshot)
        await f.scheduler.admitExternalSnapshot(snapshot)

        XCTAssertEqual(f.scheduler.records.count, 1)
        XCTAssertEqual(f.scheduler.records.first?.state, .queued)
        XCTAssertTrue(f.driver.operations.isEmpty)
        await f.shutdown()
    }

    func testExternalVideoSnapshotRunsThroughGenerationAndSending() async throws {
        let f = try Fixture()
        f.scheduler.start()
        let snapshot = ControlledDriver.snapshot("video-buyer", revision: "video-analysis:def")

        await f.scheduler.admitExternalSnapshot(snapshot)
        for _ in 0..<60 {
            if (await f.generator.startedUIDs) == ["video-buyer"] { break }
            await f.scheduler.tick(); await Task.yield()
        }
        await f.generator.complete("video-buyer", text: "我看到了视频里的现象")
        for _ in 0..<80 {
            if f.scheduler.records.first?.deliveryOutcome == .sent { break }
            await f.scheduler.tick(); try? await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertTrue(f.driver.operations.contains("send:video-buyer:我看到了视频里的现象"))
        XCTAssertEqual(f.scheduler.records.first?.deliveryOutcome, .sent)
        await f.shutdown()
    }

    func testExternalVideoForBusyCustomerWaitsBehindExistingJobWithoutStoppingScheduler() async throws {
        let f = try Fixture()
        await f.start(["buyer"])
        var startedUIDs = await f.generator.startedUIDs
        XCTAssertEqual(startedUIDs, ["buyer"])

        let video = ControlledDriver.snapshot(
            "buyer",
            revision: "video-analysis:busy-customer",
            history: "customer video evidence"
        )
        await f.scheduler.admitExternalSnapshot(video)

        XCTAssertTrue(f.scheduler.isRunning, f.scheduler.status)
        XCTAssertEqual(f.scheduler.records.map(\.state), [.generating, .queued])
        startedUIDs = await f.generator.startedUIDs
        XCTAssertEqual(startedUIDs, ["buyer"])

        await f.generator.complete("buyer", text: "answer-existing")
        for _ in 0..<100 {
            await f.scheduler.tick()
            if await f.generator.startedUIDs == ["buyer", "buyer"] { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(f.driver.operations.contains("send:buyer:answer-existing"))
        startedUIDs = await f.generator.startedUIDs
        XCTAssertEqual(startedUIDs, ["buyer", "buyer"])

        await f.generator.complete("buyer", text: "answer-video")
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.driver.operations.contains("send:buyer:answer-video") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let firstSend = try XCTUnwrap(f.driver.operations.firstIndex(of: "send:buyer:answer-existing"))
        let videoSend = try XCTUnwrap(f.driver.operations.firstIndex(of: "send:buyer:answer-video"))
        XCTAssertLessThan(firstSend, videoSend)
        XCTAssertTrue(f.scheduler.isRunning, f.scheduler.status)
        await f.shutdown()
    }

    func testVideoMarkerWithSameHashDoesNotCreateDuplicateJobOrStopFollowingVideo() async throws {
        let hash = "same-video-hash"
        let first = SchedulerRecord(
            uid: "buyer",
            sequence: 0,
            state: .ready,
            snapshot: ControlledDriver.snapshot(
                "buyer", revision: "video-analysis:\(hash)", history: "analyzed video"
            ),
            pendingSupplement: ControlledDriver.snapshot(
                "buyer", revision: "video:\(hash)", history: "visible video marker",
                unanswered: false, generate: false
            ),
            reply: ReplyEnvelope(
                decision: .autoSend, riskLevel: .low,
                replyText: "answer-first-video", reason: "fixture"
            )
        )
        let second = SchedulerRecord(
            uid: "buyer",
            sequence: 1,
            state: .queued,
            snapshot: ControlledDriver.snapshot(
                "buyer", revision: "video-analysis:second-video-hash", history: "second video"
            )
        )
        let f = try Fixture(initial: SchedulerPersistentState(
            nextSequence: 2, records: [first, second]
        ))

        f.scheduler.start()
        for _ in 0..<100 {
            await f.scheduler.tick()
            if await f.generator.startedUIDs == ["buyer"] { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertTrue(f.driver.operations.contains("send:buyer:answer-first-video"))
        XCTAssertTrue(f.scheduler.isRunning, f.scheduler.status)
        XCTAssertEqual(f.scheduler.records.count, 2, "The second observation of one video must not create a third job")
        let startedUIDs = await f.generator.startedUIDs
        XCTAssertEqual(startedUIDs, ["buyer"], "The already queued second video must continue normally")
        await f.shutdown()
    }

    func testVisibleVideoMarkerIsIgnoredWhileMatchingAnalysisIsGenerating() async throws {
        let f = try Fixture()
        let hash = "live-video-hash"
        await f.scheduler.admitExternalSnapshot(ControlledDriver.snapshot(
            "buyer", revision: "video-analysis:\(hash)", history: "analyzed video"
        ))
        f.scheduler.start()
        for _ in 0..<60 {
            if await f.generator.startedUIDs == ["buyer"] { break }
            await f.scheduler.tick()
            try await Task.sleep(for: .milliseconds(1))
        }

        f.driver.snapshots["buyer"] = ControlledDriver.snapshot(
            "buyer", revision: "video:\(hash)", history: "visible video marker",
            unanswered: false, generate: false
        )
        f.driver.unread = ["buyer"]
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.driver.operations.filter({ $0 == "capture:buyer" }).count == 1,
               f.scheduler.records.first?.supplementCapturePending == nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertNil(f.scheduler.records.first?.pendingSupplement)
        XCTAssertTrue(f.scheduler.events.contains { $0.message == "Duplicate video marker ignored by hash" })
        XCTAssertTrue(f.scheduler.isRunning, f.scheduler.status)
        await f.shutdown()
    }

    func testRestartSupersedesLegacyNoDotReadyReplyWithoutLosingAnsweredCursor() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let cursor = CustomerCursor(count: 16, digest: String(repeating: "a", count: 64))
        let legacy = SchedulerRecord(
            uid: "buyer", sequence: 12, state: .ready,
            snapshot: CaptureSnapshot(
                uid: "buyer", customerRevision: cursor.digest, historyJSONL: "bad sidebar OCR",
                hasUnansweredCustomer: true, shouldGenerate: true,
                startCursor: cursor, endCursor: cursor
            ),
            reply: ReplyEnvelope(
                decision: .autoSend, riskLevel: .low,
                replyText: "wrong no-dot follow-up", reason: "fixture"
            ),
            createdAt: now, updatedAt: now, nextAttemptAt: now,
            automaticFollowUpCount: 2
        )
        let initial = SchedulerPersistentState(
            nextSequence: 13,
            records: [legacy],
            answeredCursors: ["buyer": cursor]
        )

        let f = try Fixture(initial: initial)

        XCTAssertEqual(f.scheduler.records.first?.state, .superseded)
        XCTAssertEqual(try f.store.load().answeredCursors["buyer"], cursor)
        await f.shutdown()
    }

    func testRestartClearsOrphanedAttemptOwnershipFromQueuedGeneration() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let queued = SchedulerRecord(
            uid: "A",
            sequence: 0,
            state: .queued,
            snapshot: ControlledDriver.snapshot("A"),
            attemptID: UUID(),
            createdAt: now,
            updatedAt: now,
            nextAttemptAt: now
        )
        let f = try Fixture(initial: SchedulerPersistentState(nextSequence: 1, records: [queued]))
        f.scheduler.start()
        await f.drive()

        let started = await f.generator.startedUIDs
        XCTAssertEqual(started, ["A"])
        await f.shutdown()
    }

    func testGenerationFailureClearsAttemptOwnershipAndRetriesAfterBackoff() async throws {
        let f = try Fixture()
        await f.start(["A"])
        var started = await f.generator.startedUIDs
        XCTAssertEqual(started, ["A"])

        await f.generator.fail("A")
        await f.drive()
        XCTAssertEqual(f.scheduler.records.first?.state, .queued)

        f.clock.value += 2
        await f.drive()
        started = await f.generator.startedUIDs
        XCTAssertEqual(started, ["A", "A"])
        await f.shutdown()
    }

    func testReadySendBurstYieldsToDiscoveryBeforeFourthSend() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let records = (0..<4).map { index in
            SchedulerRecord(
                uid: "U\(index)",
                sequence: index,
                state: .ready,
                snapshot: ControlledDriver.snapshot("U\(index)"),
                reply: ReplyEnvelope(
                    decision: .autoSend,
                    riskLevel: .low,
                    replyText: "answer-U\(index)",
                    reason: "fixture"
                ),
                createdAt: now,
                updatedAt: now,
                nextAttemptAt: now
            )
        }
        let f = try Fixture(initial: SchedulerPersistentState(nextSequence: 4, records: records))
        f.scheduler.start()
        await f.drive(30)

        let relevant = f.driver.operations.filter {
            $0 == "discover" || $0.hasPrefix("send:")
        }
        XCTAssertGreaterThanOrEqual(relevant.count, 5)
        XCTAssertEqual(Array(relevant.prefix(5)), [
            "send:U0:answer-U0",
            "send:U1:answer-U1",
            "send:U2:answer-U2",
            "discover",
            "send:U3:answer-U3",
        ])
        await f.shutdown()
    }

    func testFirstCaptureFailureMovesBehindFreshCustomerThenSecondParksOnlyThatAttempt() async throws {
        let f = try Fixture()
        f.driver.captureErrorsRemainingByUID["A"] = 2
        await f.start(["A", "B"])

        let captureA = try XCTUnwrap(f.driver.operations.firstIndex(of: "capture:A"))
        let captureB = try XCTUnwrap(f.driver.operations.firstIndex(of: "capture:B"))
        XCTAssertLessThan(captureA, captureB)
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 1)
        let started = await f.generator.startedUIDs
        XCTAssertEqual(started, ["B"])
        XCTAssertEqual(f.scheduler.records.first { $0.uid == "A" }?.state, .discovered)

        f.clock.value += 1
        await f.drive()
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 2)
        XCTAssertEqual(f.scheduler.records.first { $0.uid == "A" }?.state, .parked)
        XCTAssertEqual(f.scheduler.records.first { $0.uid == "B" }?.state, .generating)
        await f.shutdown()
    }

    func testHungCaptureTimesOutAndReadyReplyContinuesWithoutReleasingGate() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let captureRecord = SchedulerRecord(
            uid: "A", sequence: 0, state: .discovered,
            createdAt: now, updatedAt: now, nextAttemptAt: now
        )
        let queuedRecord = SchedulerRecord(
            uid: "B", sequence: 1, state: .queued,
            snapshot: ControlledDriver.snapshot("B"),
            createdAt: now, updatedAt: now, nextAttemptAt: now
        )
        let initial = SchedulerPersistentState(
            nextSequence: 2,
            records: [captureRecord, queuedRecord]
        )
        let f = try Fixture(
            initial: initial,
            stageDeadlines: SchedulerStageDeadlines(
                discovery: .milliseconds(50),
                capture: .milliseconds(50),
                supplementCapture: .milliseconds(50),
                delivery: .milliseconds(50)
            )
        )
        let captureGate = Gate()
        f.driver.captureGates["A"] = captureGate
        f.scheduler.start()

        await f.scheduler.tick()
        for _ in 0..<100 {
            if f.driver.operations.contains("capture:A") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(f.driver.operations.contains("capture:A"))
        XCTAssertTrue(f.scheduler.hasActiveUIOperation)

        await f.generator.complete("B", text: "answer-B")
        for _ in 0..<200 {
            await f.scheduler.tick()
            if f.driver.operations.contains("send:B:answer-B") { break }
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertTrue(
            f.driver.operations.contains("send:B:answer-B"),
            "A timed out, so B's already-generated reply must use the next UI turn without waiting for A's gate"
        )

        await captureGate.release()
        await f.shutdown()
    }

    func testUncertainAfterClickCompletesWithoutReconcileOrResendAndNextUIDRuns() async throws {
        let end = CustomerCursor(count: 1, digest: String(repeating: "a", count: 64))
        let f = try Fixture()
        f.driver.snapshots["A"] = CaptureSnapshot(uid: "A", customerRevision: end.digest,
            historyJSONL: "question", hasUnansweredCustomer: true, shouldGenerate: true,
            startCursor: .empty, endCursor: end)
        f.driver.delivery = .uncertain("fixture")
        await f.start(["A", "B"]); await f.generator.complete("A"); await f.drive()
        XCTAssertEqual(f.scheduler.records.first { $0.uid == "A" }?.state, .completed)
        XCTAssertEqual(f.scheduler.records.first { $0.uid == "A" }?.deliveryOutcome, .uncertain)
        XCTAssertEqual(try f.store.load().answeredCursors["A"], end)
        XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:A:") }.count, 1)
        XCTAssertFalse(f.driver.operations.contains { $0.hasPrefix("reconcile:A:") })
        f.driver.delivery = .sent
        await f.generator.complete("B"); await f.drive()
        XCTAssertTrue(f.driver.operations.contains("send:B:answer-B"))
        await f.shutdown()
    }
    func testAnswerAThenFreshUnreadGeneratesBandCAndAdvancesOnlyAfterEachSend() async throws {
        let cursorA = CustomerCursor(count: 1, digest: String(repeating: "a", count: 64))
        let cursorC = CustomerCursor(count: 3, digest: String(repeating: "c", count: 64))
        let f = try Fixture()
        f.driver.snapshots["buyer"] = CaptureSnapshot(
            uid: "buyer",
            customerRevision: cursorA.digest,
            historyJSONL: "A\n",
            hasUnansweredCustomer: true,
            shouldGenerate: true,
            targetCustomerJSONL: "A\n",
            startCursor: .empty,
            endCursor: cursorA
        )
        await f.start(["buyer"])
        f.driver.snapshots["buyer"] = CaptureSnapshot(
            uid: "buyer",
            customerRevision: cursorC.digest,
            historyJSONL: "A\nB\nC\nservice-answer-A\n",
            hasUnansweredCustomer: true,
            shouldGenerate: true,
            targetCustomerJSONL: "B\nC\n",
            startCursor: cursorA,
            endCursor: cursorC
        )

        await f.generator.complete("buyer", text: "answer-A")
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.scheduler.records.first(where: { $0.uid == "buyer" })?.state == .completed { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        f.clock.value = f.clock.value.addingTimeInterval(1)
        f.driver.unread = ["buyer"]
        for _ in 0..<100 {
            await f.scheduler.tick()
            if (await f.generator.inputs).count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertTrue(f.driver.operations.contains("send:buyer:answer-A"))
        XCTAssertEqual(try f.store.load().answeredCursors["buyer"], cursorA)
        let generatedInputs = await f.generator.inputs
        XCTAssertEqual(generatedInputs.map(\.targetCustomerJSONL), ["A\n", "B\nC\n"])

        f.driver.snapshots["buyer"] = CaptureSnapshot(
            uid: "buyer",
            customerRevision: cursorC.digest,
            historyJSONL: "A\nB\nC\nservice-answer-A\n",
            hasUnansweredCustomer: false,
            shouldGenerate: false,
            targetCustomerJSONL: "",
            startCursor: cursorC,
            endCursor: cursorC
        )
        await f.generator.complete("buyer", text: "answer-B+C")
        await f.drive(20)

        XCTAssertTrue(f.driver.operations.contains("send:buyer:answer-B+C"))
        XCTAssertEqual(try f.store.load().answeredCursors["buyer"], cursorC)
        await f.shutdown()
    }

    func testFailedAndUncertainSendNeverAdvanceAnsweredCursor() async throws {
        let end = CustomerCursor(count: 1, digest: String(repeating: "e", count: 64))
        func run(_ delivery: DeliveryResult) async throws -> CustomerCursor? {
            let f = try Fixture()
            f.driver.delivery = delivery
            f.driver.snapshots["buyer"] = CaptureSnapshot(
                uid: "buyer", customerRevision: end.digest, historyJSONL: "A\n",
                hasUnansweredCustomer: true, shouldGenerate: true,
                targetCustomerJSONL: "A\n", startCursor: .empty, endCursor: end
            )
            await f.start(["buyer"])
            f.driver.snapshots["buyer"] = CaptureSnapshot(
                uid: "buyer", customerRevision: end.digest, historyJSONL: "A\n",
                hasUnansweredCustomer: false, shouldGenerate: false,
                targetCustomerJSONL: "", startCursor: end, endCursor: end
            )
            await f.generator.complete("buyer", text: "answer-A")
            await f.drive(20)
            let cursor = try f.store.load().answeredCursors["buyer"]
            await f.shutdown()
            return cursor
        }

        let failedCursor = try await run(.failedBeforeSend("composer unavailable"))
        let uncertainCursor = try await run(.uncertain("confirmation unavailable"))
        XCTAssertNil(failedCursor)
        XCTAssertEqual(uncertainCursor, end)
    }

    func testCustomerArrivingDuringSendIsCapturedAfterItsFreshUnreadDiscovery() async throws {
        let cursorA = CustomerCursor(count: 1, digest: String(repeating: "a", count: 64))
        let cursorB = CustomerCursor(count: 2, digest: String(repeating: "b", count: 64))
        let f = try Fixture()
        f.driver.snapshots["buyer"] = CaptureSnapshot(
            uid: "buyer", customerRevision: cursorA.digest, historyJSONL: "A\n",
            hasUnansweredCustomer: true, shouldGenerate: true,
            targetCustomerJSONL: "A\n", startCursor: .empty, endCursor: cursorA
        )
        await f.start(["buyer"])
        f.driver.snapshots["buyer"] = CaptureSnapshot(
            uid: "buyer", customerRevision: cursorA.digest, historyJSONL: "A\n",
            hasUnansweredCustomer: false, shouldGenerate: false,
            targetCustomerJSONL: "", startCursor: cursorA, endCursor: cursorA
        )
        f.driver.sendCheck = {
            f.driver.snapshots["buyer"] = CaptureSnapshot(
                uid: "buyer", customerRevision: cursorB.digest,
                historyJSONL: "A\nB\nservice-answer-A\n",
                hasUnansweredCustomer: true, shouldGenerate: true,
                targetCustomerJSONL: "B\n", startCursor: cursorA, endCursor: cursorB
            )
            f.driver.unread = ["buyer"]
        }

        await f.generator.complete("buyer", text: "answer-A")
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.scheduler.records.first(where: { $0.uid == "buyer" })?.state == .completed { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        f.clock.value = f.clock.value.addingTimeInterval(1)
        f.driver.unread = ["buyer"]
        for _ in 0..<100 {
            await f.scheduler.tick()
            if (await f.generator.inputs).count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let inputs = await f.generator.inputs
        XCTAssertEqual(inputs.map(\.targetCustomerJSONL), ["A\n", "B\n"])
        XCTAssertEqual(try f.store.load().answeredCursors["buyer"], cursorA)
        await f.shutdown()
    }

    func testCompletedDeliveryWaitsForFreshUnreadDiscoveryBeforeAnotherOCR() async throws {
        let f = try Fixture()
        let c0 = CustomerCursor.empty
        let c1 = CustomerCursor(count: 1, digest: String(repeating: "a", count: 64))
        let c2 = CustomerCursor(count: 2, digest: String(repeating: "b", count: 64))
        f.driver.snapshots["buyer"] = CaptureSnapshot(
            uid: "buyer", customerRevision: c1.digest, historyJSONL: "A",
            hasUnansweredCustomer: true, shouldGenerate: true,
            targetCustomerJSONL: "A", startCursor: c0, endCursor: c1
        )
        await f.start(["buyer"])

        f.driver.snapshots["buyer"] = CaptureSnapshot(
            uid: "buyer", customerRevision: c2.digest, historyJSONL: "A\nB",
            hasUnansweredCustomer: true, shouldGenerate: true,
            targetCustomerJSONL: "B", startCursor: c1, endCursor: c2
        )
        await f.generator.complete("buyer", text: "answer-A")
        await f.drive(30)

        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:buyer" }.count, 1)
        var generatedInputs = await f.generator.inputs
        XCTAssertEqual(generatedInputs.map(\.targetCustomerJSONL), ["A"])
        XCTAssertEqual(try f.store.load().answeredCursors["buyer"], c1)

        f.clock.value = f.clock.value.addingTimeInterval(1)
        f.driver.unread = ["buyer"]
        await f.drive(30)
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:buyer" }.count, 2)
        generatedInputs = await f.generator.inputs
        XCTAssertEqual(generatedInputs.map(\.targetCustomerJSONL), ["A", "B"])
        await f.shutdown()
    }

    // Each assertion below crosses the real scheduler/store boundary. Doubles replace only UI and CLI.
    func testNewCustomerStartsWhileFirstGenerationIsBlocked() async throws {
        let f = try Fixture(); await f.start(["A"])
        f.driver.unread = ["B"]; await f.drive()
        let started = await f.generator.startedUIDs
        XCTAssertEqual(started, ["A", "B"])
        XCTAssertEqual(f.scheduler.records.filter { $0.state == .generating }.count, 2)
        await f.shutdown()
    }

    func testHardMemoryPressureLeavesEveryGenerationQueuedRatherThanFailed() async throws {
        let f = try Fixture(availableMemoryBytes: 512 << 20)
        await f.start(["A", "B"])

        let started = await f.generator.startedUIDs
        XCTAssertEqual(started, [])
        XCTAssertEqual(f.scheduler.records.map(\.state), [.queued, .queued])
        XCTAssertFalse(f.scheduler.records.contains { $0.state == .failed })
        await f.shutdown()
    }

    // Sending already performs exact UID checks before and after filling the
    // composer. Do not run another full OCR pass before that transaction.
    func testDeliverySkipsFullPreSendCaptureAndReliesOnSenderUIDChecks() async throws {
        let f = try Fixture()
        await f.start(["A"])

        await f.generator.complete("A")
        await f.drive()

        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 1)
        XCTAssertEqual(f.driver.operations.filter { $0 == "captureBeforeDelivery:A" }.count, 0)
        XCTAssertTrue(f.driver.operations.contains("send:A:answer-A"))
        await f.shutdown()
    }

    func testTenCustomersUseDynamicCapacityAndCleanupStillOwnsSlot() async throws {
        let customers = (0..<10).map { "U\($0)" }
        let f = try Fixture(); await f.start(customers)
        var started = await f.generator.startedUIDs
        XCTAssertEqual(started, customers)
        XCTAssertEqual(f.scheduler.generationCapacity, 10)
        let gate = Gate(); let cleanup = Task { await gate.wait() }
        await f.generator.complete("U0", cleanup: cleanup); await f.drive()
        XCTAssertTrue(f.driver.operations.contains("send:U0:answer-U0"))
        started = await f.generator.startedUIDs; XCTAssertEqual(started.count, 10)
        await gate.release(); await f.drive()
        started = await f.generator.startedUIDs; XCTAssertEqual(started, customers)
        await f.shutdown()
    }

    func testOneHundredCustomersRemainDistinctAndStartWithoutNumericLimit() async throws {
        let customers = (0..<100).map { "U\($0)" }
        let f = try Fixture()
        await f.start(customers)
        await f.drive(240)

        XCTAssertEqual(f.scheduler.records.map(\.uid), customers)
        XCTAssertEqual(Set(f.scheduler.records.map(\.uid)).count, 100)
        let initiallyStarted = await f.generator.startedUIDs
        let capacity = initiallyStarted.count
        XCTAssertEqual(capacity, 100)
        XCTAssertEqual(initiallyStarted, customers)

        for uid in customers.prefix(capacity) {
            await f.generator.complete(uid)
        }
        await f.drive(40)

        let started = await f.generator.startedUIDs
        XCTAssertEqual(Set(started).count, started.count)
        XCTAssertEqual(started, customers)
        await f.shutdown()
    }

    func testResumedSessionLifecycleIsPersistedWithoutSessionIDOrChatText() async throws {
        let f = try Fixture(); await f.start(["A"])
        await f.generator.complete("A", timing: ReplyGenerationTiming(
            sessionMode: "resumed",
            submittedHistoryBytes: 48,
            submittedImageCount: 1
        ))
        await f.drive()

        let record = try XCTUnwrap(f.scheduler.records.first { $0.uid == "A" })
        XCTAssertEqual(record.sessionStage, "恢复客户会话 · 增量提交 48 bytes · 图片 1")
        XCTAssertTrue(f.scheduler.events.contains { $0.message.contains("恢复客户会话") })
        XCTAssertFalse(f.scheduler.events.contains { $0.message.contains("session-") })
        await f.shutdown()
    }

    func testDuplicateRedDotsAndReorderPreserveFirstSeenFIFO() async throws {
        let f = try Fixture(); await f.start(["A", "B", "C", "A"])
        f.driver.unread = ["C", "B", "A", "D"]; await f.drive()
        XCTAssertEqual(f.scheduler.records.map(\.uid), ["A", "B", "C", "D"])
        let started = await f.generator.startedUIDs; XCTAssertEqual(started, ["A", "B", "C", "D"])
        await f.shutdown()
    }

    func testReadySendWinsAtSafeBoundaryAndReentrantTicksNeverOverlapUI() async throws {
        let f = try Fixture(); await f.start(["A"])
        f.driver.unread = ["B", "C"]; await f.scheduler.tick()
        let gate = Gate(); f.driver.captureGates["B"] = gate
        let capturing = Task { await f.scheduler.tick() }
        for _ in 0..<30 { await Task.yield() }
        await f.generator.complete("A")
        for _ in 0..<10 { await f.scheduler.tick() }
        XCTAssertEqual(f.driver.maximumActive, 1)
        await gate.release(); await capturing.value; await f.drive()
        let send = f.driver.operations.firstIndex(of: "send:A:answer-A")
        let captureC = f.driver.operations.firstIndex(of: "capture:C")
        XCTAssertNotNil(send); XCTAssertNotNil(captureC)
        if let send, let captureC { XCTAssertLessThan(send, captureC) }
        XCTAssertEqual(f.driver.maximumActive, 1)
        await f.shutdown()
    }

    func testReplyAlreadyReadyIsSentBeforeNewerCustomerRevisionIsGenerated() async throws {
        let cursorA = CustomerCursor(count: 1, digest: String(repeating: "a", count: 64))
        let cursorB = CustomerCursor(count: 2, digest: String(repeating: "b", count: 64))
        let f = try Fixture()
        f.driver.snapshots["A"] = CaptureSnapshot(
            uid: "A", customerRevision: cursorA.digest, historyJSONL: "question A",
            hasUnansweredCustomer: true, shouldGenerate: true,
            targetCustomerJSONL: "question A", startCursor: .empty, endCursor: cursorA
        )
        await f.start(["A"])
        f.driver.sendCheck = {
            f.driver.snapshots["A"] = CaptureSnapshot(
                uid: "A", customerRevision: cursorB.digest,
                historyJSONL: "question A then question B",
                hasUnansweredCustomer: true, shouldGenerate: true,
                targetCustomerJSONL: "question B", startCursor: cursorA, endCursor: cursorB
            )
            f.driver.unread = ["A"]
        }
        await f.generator.complete("A", text: "answer-A")
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.scheduler.records.first(where: { $0.uid == "A" })?.state == .completed { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        f.clock.value = f.clock.value.addingTimeInterval(1)
        f.driver.unread = ["A"]
        for _ in 0..<100 {
            await f.scheduler.tick()
            if (await f.generator.inputs).count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let readyDiagnostics = "running=\(f.scheduler.isRunning) activeUI=\(f.scheduler.hasActiveUIOperation) status=\(f.scheduler.status) operations=\(f.driver.operations) records=\(f.scheduler.records.map { $0.state.rawValue + ":" + ($0.customerRevision ?? "nil") }) events=\(f.scheduler.events.map(\.message))"
        XCTAssertTrue(f.driver.operations.contains("send:A:answer-A"), readyDiagnostics)
        let inputs = await f.generator.inputs
        XCTAssertEqual(inputs.map(\.historyVersion), [cursorA.digest, cursorB.digest])
        XCTAssertEqual(inputs.last?.historyJSONL, "question A then question B")
        await f.shutdown()
    }

    func testSupplementObservedDuringGenerationWaitsBehindOriginalReply() async throws {
        let f = try Fixture(); await f.start(["A"])
        f.driver.snapshots["A"] = ControlledDriver.snapshot("A", revision: "r2", history: "question A then question B")
        f.driver.unread = ["A"]
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.scheduler.records.first(where: { $0.uid == "A" })?.pendingSupplement != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let supplementDiagnostics = "running=\(f.scheduler.isRunning) activeUI=\(f.scheduler.hasActiveUIOperation) unread=\(f.driver.unread) status=\(f.scheduler.status) operations=\(f.driver.operations) records=\(f.scheduler.records.map { $0.state.rawValue + ":" + ($0.customerRevision ?? "nil") }) events=\(f.scheduler.events.map(\.message))"
        XCTAssertEqual(f.scheduler.records.filter { $0.uid == "A" && !$0.state.isTerminal }.count, 1,
                       supplementDiagnostics)
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 2, supplementDiagnostics)

        await f.generator.complete("A", text: "answer-A"); await f.drive()
        XCTAssertTrue(f.driver.operations.contains("send:A:answer-A"),
                      "The frozen A batch must be sent before generating the later B batch")
        let inputs = await f.generator.inputs
        XCTAssertEqual(inputs.map(\.historyVersion), ["r1", "r2"])
        XCTAssertEqual(inputs.last?.historyJSONL, "question A then question B")
        XCTAssertFalse(f.scheduler.records.contains {
            $0.uid == "A" && $0.sequence == 0 && $0.state == .superseded
        })
        await f.shutdown()
    }

    func testNextBatchIsRecapturedAfterOriginalReplyIsSent() async throws {
        let f = try Fixture(); await f.start(["A"])
        f.driver.snapshots["A"] = ControlledDriver.snapshot(
            "A", revision: "r2", history: "question A then supplement B before answer A"
        )
        f.driver.unread = ["A"]
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.scheduler.records.first(where: { $0.uid == "A" })?.pendingSupplement != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        f.driver.sendCheck = {
            f.driver.snapshots["A"] = ControlledDriver.snapshot(
                "A", revision: "r3", history: "question A, delivered answer A, then supplements B C image link"
            )
        }

        await f.generator.complete("A", text: "answer-A")
        for _ in 0..<100 {
            await f.scheduler.tick()
            if (await f.generator.inputs).count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertTrue(f.driver.operations.contains("send:A:answer-A"))
        let inputs = await f.generator.inputs
        XCTAssertEqual(inputs.map(\.historyVersion), ["r1", "r3"],
                       "The next batch must be rebuilt after the previous reply is visibly delivered")
        let sendIndex = try XCTUnwrap(f.driver.operations.firstIndex(of: "send:A:answer-A"))
        let recaptures = f.driver.operations.enumerated().filter { $0.element == "capture:A" }.map(\.offset)
        XCTAssertTrue(recaptures.contains { $0 > sendIndex },
                      "Later messages must be recaptured after sending instead of reusing the pre-send snapshot")
        await f.shutdown()
    }

    func testFrozenBatchOrderingAppliesIndependentlyToEveryActiveCustomer() async throws {
        let customers = (0..<5).map { "U\($0)" }
        let f = try Fixture(); await f.start(customers)
        for uid in customers {
            f.driver.snapshots[uid] = ControlledDriver.snapshot(
                uid, revision: "supplement-\(uid)", history: "original plus later text image or link for \(uid)"
            )
        }
        f.driver.unread = customers
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.scheduler.records.filter({ $0.pendingSupplement != nil }).count == customers.count { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        for uid in customers {
            f.driver.snapshots[uid] = ControlledDriver.snapshot(
                uid, revision: "delivered-then-latest-\(uid)", history: "delivered original reply then every later message for \(uid)"
            )
            await f.generator.complete(uid, text: "original-answer-\(uid)")
        }
        for _ in 0..<200 {
            await f.scheduler.tick()
            if (await f.generator.inputs).count == customers.count * 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let inputs = await f.generator.inputs
        for uid in customers {
            XCTAssertTrue(f.driver.operations.contains("send:\(uid):original-answer-\(uid)"))
            XCTAssertEqual(inputs.filter { $0.uid == uid }.map(\.historyVersion), [
                "r1", "delivered-then-latest-\(uid)",
            ])
        }
        XCTAssertFalse(f.scheduler.records.contains { $0.state == .superseded })
        await f.shutdown()
    }

    func testFailedSupplementCaptureStopsAfterTwoAttemptsAndKeepsOriginalReplyFirst() async throws {
        let f = try Fixture(); await f.start(["A"])
        f.driver.snapshots["A"] = ControlledDriver.snapshot("A", revision: "r2", history: "question A then question B")
        f.driver.captureError = true
        f.driver.unread = ["A"]

        await f.drive(6)
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 2)
        XCTAssertTrue(f.driver.unread.isEmpty, "Discovery consumed the only unread observation")
        XCTAssertTrue(f.scheduler.status.contains("补充消息采集失败"),
                      "Do not immediately hide a durable supplement retry failure as healthy")

        f.clock.value = f.clock.value.addingTimeInterval(2)
        await f.drive()
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 3,
                       "The initial capture plus two bounded supplement attempts must run")
        XCTAssertEqual(f.scheduler.records.first(where: { $0.uid == "A" })?.supplementCaptureAbandoned, true)

        f.driver.captureError = false
        f.driver.unread = ["A"]
        f.clock.value = f.clock.value.addingTimeInterval(2)
        await f.drive()
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 3,
                       "Discovery must not re-arm an abandoned supplement capture")

        await f.generator.complete("A", text: "answer-A")
        await f.drive()
        XCTAssertTrue(f.driver.operations.contains("send:A:answer-A"))
        let inputs = await f.generator.inputs
        XCTAssertEqual(inputs.map(\.historyVersion), ["r1"])
        await f.shutdown()
    }

    func testPendingSupplementRetryDoesNotStarveAnotherCustomersReadyReply() async throws {
        let f = try Fixture(); await f.start(["A", "B"])
        f.driver.snapshots["A"] = ControlledDriver.snapshot("A", revision: "r2", history: "question A then question B")
        f.driver.captureError = true
        f.driver.unread = ["A"]
        await f.drive(6)
        f.driver.captureError = false

        await f.generator.complete("B", text: "ready-B")
        for _ in 0..<50 {
            if f.scheduler.records.first(where: { $0.uid == "B" })?.state == .ready { break }
            await Task.yield()
        }
        f.clock.value = f.clock.value.addingTimeInterval(2)
        f.driver.operations.removeAll()

        await f.scheduler.tick()
        for _ in 0..<100 {
            if f.driver.operations.contains("send:B:ready-B") { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(f.driver.operations.first, "send:B:ready-B")
        XCTAssertFalse(f.driver.operations.contains("captureBeforeDelivery:B"))
        XCTAssertTrue(f.driver.operations.contains("send:B:ready-B"))
        XCTAssertFalse(f.driver.operations.contains("capture:A"))
        await f.shutdown()
    }

    func testStopAfterPersistingSupplementIntentPreventsTheOCRUIAction() async throws {
        let f = try Fixture(); await f.start(["A"])
        f.driver.snapshots["A"] = ControlledDriver.snapshot("A", revision: "r2", history: "question A then question B")
        var stopped = false
        f.scheduler.onChange = {
            if !stopped, f.scheduler.records.first(where: { $0.uid == "A" })?.supplementCapturePending == true {
                stopped = true
                f.scheduler.stop()
            }
        }
        f.driver.unread = ["A"]

        for _ in 0..<20 {
            await f.scheduler.tick()
            if !f.scheduler.isRunning { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(f.scheduler.isRunning)
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 1,
                       "Stop after the durable marker must prevent the next UI action")
        await f.shutdown()
    }

    func testSupplementCaptureStartedDuringGenerationStillQueuesBehindReplyIfDraftFinishesFirst() async throws {
        let f = try Fixture(); await f.start(["A"])
        let supplementGate = Gate()
        f.driver.captureGates["A"] = supplementGate
        f.driver.snapshots["A"] = ControlledDriver.snapshot("A", revision: "r2", history: "question A then question B")
        f.driver.unread = ["A"]

        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.driver.operations.filter({ $0 == "capture:A" }).count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 2)
        await f.generator.complete("A", text: "answer-A")
        for _ in 0..<100 {
            if f.scheduler.records.first?.state == .ready { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(f.scheduler.records.first?.state, .ready)

        await supplementGate.release()
        for _ in 0..<100 {
            if !f.scheduler.hasActiveUIOperation { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<100 {
            await f.scheduler.tick()
            if (await f.generator.inputs).count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertTrue(f.driver.operations.contains("send:A:answer-A"))
        let inputs = await f.generator.inputs
        XCTAssertEqual(inputs.map(\.historyVersion), ["r1", "r2"])
        XCTAssertEqual(inputs.last?.historyJSONL, "question A then question B")
        await f.shutdown()
    }

    func testServiceReadStatusDoesNotInvalidateCustomerRevision() async throws {
        let f = try Fixture(); await f.start(["A"])
        f.driver.snapshots["A"] = ControlledDriver.snapshot("A", history: "customer question plus read status", generate: false)
        await f.generator.complete("A"); await f.drive()
        XCTAssertTrue(f.driver.operations.contains("send:A:answer-A"))
        let inputs = await f.generator.inputs; XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.historyJSONL, "customer question")
        await f.shutdown()
    }

    func testFrozenReadyReplyIsNotSuppressedByALaterObservation() async throws {
        let f = try Fixture(); await f.start(["A"])
        f.driver.snapshots["A"] = ControlledDriver.snapshot("A", unanswered: false, generate: false)
        await f.generator.complete("A"); await f.drive()
        XCTAssertTrue(f.driver.operations.contains("send:A:answer-A"))
        XCTAssertEqual(f.scheduler.records.first?.state, .completed)
        await f.shutdown()
    }

    func testNoNewCaptureCompletesObservationWithoutGeneration() async throws {
        let f = try Fixture(); f.driver.snapshots["A"] = ControlledDriver.snapshot("A", generate: false)
        await f.start(["A"])
        XCTAssertEqual(f.scheduler.records.first?.state, .completed)
        let inputs = await f.generator.inputs; XCTAssertTrue(inputs.isEmpty)
        f.driver.unread = ["A"]; await f.drive()
        XCTAssertEqual(f.scheduler.records.count, 1)
        await f.shutdown()
    }

    func testStopDuringCapturePreventsGenerationUntilRestart() async throws {
        let f = try Fixture(); let gate = Gate(); f.driver.captureGates["A"] = gate
        f.driver.unread = ["A"]; f.scheduler.start()
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.driver.operations.contains("capture:A") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        f.scheduler.stop(); await gate.release()
        for _ in 0..<100 {
            if !f.scheduler.hasActiveUIOperation { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await f.drive()
        var inputs = await f.generator.inputs; XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(f.scheduler.records.first?.state, .discovered)
        f.scheduler.start(); await f.drive()
        inputs = await f.generator.inputs; XCTAssertEqual(inputs.map(\.uid), ["A"])
        await f.shutdown()
    }

    func testStopPersistsInflightReplyButDoesNotSend() async throws {
        let f = try Fixture(); await f.start(["A"]); f.scheduler.stop()
        await f.generator.complete("A"); await f.drive()
        XCTAssertEqual(try f.store.load().records.first?.state, .ready)
        XCTAssertFalse(f.driver.operations.contains { $0.hasPrefix("send:") })
        f.scheduler.start(); await f.drive()
        XCTAssertTrue(f.driver.operations.contains("send:A:answer-A"))
        await f.shutdown()
    }

    func testSendingStateIsDurableBeforeSendAndCompletedDoesNotReplay() async throws {
        let f = try Fixture(); await f.start(["A"])
        f.driver.sendCheck = { XCTAssertEqual(try f.store.load().records.first?.state, .sending) }
        await f.generator.complete("A"); await f.drive()
        let saved = try f.store.load()
        XCTAssertEqual(saved.records.first?.state, .completed)
        let archived = try f.store.archivedRecord(id: XCTUnwrap(saved.records.first?.id))
        XCTAssertEqual(archived?.reply?.replyText, "answer-A")
        XCTAssertEqual(archived?.snapshot?.historyJSONL, "customer question")
        XCTAssertEqual(archived?.snapshot?.imagePaths, ["/frozen/A.png"])
        let restored = try AutoReplyScheduler(driver: f.driver, generator: f.generator, store: f.store)
        XCTAssertEqual(restored.records, saved.records)
        restored.start(); f.driver.unread = ["A"]; for _ in 0..<10 { await restored.tick() }
        XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:") }.count, 1)
        restored.stop(); f.driver.sendCheck = nil; await f.shutdown()
    }

    func testRestartReleasesInterruptedSendingWithoutReplayAndQueuesInterruptedGeneration() async throws {
        let records = [
            SchedulerRecord(uid: "A", sequence: 0, state: .sending, snapshot: ControlledDriver.snapshot("A")),
            SchedulerRecord(uid: "B", sequence: 1, state: .generating, snapshot: ControlledDriver.snapshot("B"), attemptID: UUID()),
            SchedulerRecord(uid: "C", sequence: 2, state: .capturing)
        ]
        let f = try Fixture(initial: SchedulerPersistentState(nextSequence: 3, records: records))
        XCTAssertEqual(f.scheduler.records.map(\.state), [.completed, .queued, .discovered])
        XCTAssertEqual(f.scheduler.records.first?.deliveryOutcome, .uncertain)
        XCTAssertNil(f.scheduler.records.first { $0.uid == "B" }?.attemptID)
        XCTAssertEqual(try f.store.load().records.map(\.state), [.completed, .queued, .discovered])
        await f.start(["A"])
        XCTAssertFalse(f.driver.operations.contains { $0.hasPrefix("send:A:") },
                       "The interrupted reply must never be replayed; a fresh red dot may still be captured")
        await f.shutdown()
    }

    func testRestartRetriesOnlyASendThatNeverReachedDriverInvocation() throws {
        let notInvoked = SchedulerRecord(
            uid: "pre-send", sequence: 0, state: .sending,
            snapshot: ControlledDriver.snapshot("pre-send"),
            reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "reply", reason: "fixture"),
            sendWasInvoked: false
        )
        let invoked = SchedulerRecord(
            uid: "invoked", sequence: 1, state: .sending,
            snapshot: ControlledDriver.snapshot("invoked"),
            reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "reply", reason: "fixture"),
            sendWasInvoked: true
        )
        let f = try Fixture(initial: SchedulerPersistentState(nextSequence: 2, records: [notInvoked, invoked]))

        XCTAssertEqual(f.scheduler.records.map(\.state), [.ready, .completed])
        XCTAssertNil(f.scheduler.records[0].deliveryOutcome)
        XCTAssertEqual(f.scheduler.records[1].deliveryOutcome, .uncertain)
    }

    func testStopSynchronouslyRevokesUIBeforeLateCaptureCanCommit() async throws {
        let f = try Fixture()
        let gate = Gate(); f.driver.captureGates["A"] = gate
        f.driver.unread = ["A"]; f.scheduler.start()
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.driver.operations.contains("capture:A") { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        let started = ContinuousClock.now
        f.scheduler.stop()
        let elapsed = ContinuousClock.now - started
        XCTAssertEqual(f.driver.revokeCount, 1)
        XCTAssertLessThan(elapsed, .milliseconds(200))

        await gate.release()
        for _ in 0..<100 {
            if !f.scheduler.hasActiveUIOperation { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let stoppedRecord = try XCTUnwrap(f.store.load().records.first)
        XCTAssertEqual(stoppedRecord.state, .discovered)
        XCTAssertNil(stoppedRecord.snapshot)
        let generatedInputs = await f.generator.inputs
        XCTAssertTrue(generatedInputs.isEmpty)
        await f.shutdown()
    }

    func testWriteFailureFailsClosedBeforeAnyFurtherUI() async throws {
        let f = try Fixture(); await f.start(["A"])
        try? FileManager.default.removeItem(at: f.store.stateURL)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.store.stateURL, withIntermediateDirectories: false)
        let before = f.driver.operations.count
        await f.generator.complete("A"); await f.drive()
        XCTAssertFalse(f.scheduler.isRunning)
        XCTAssertEqual(f.driver.operations.count, before)
        XCTAssertTrue(f.scheduler.status.lowercased().contains("persist"))
        await f.shutdown()
    }

    func testWrongUIDCaptureRejectsOnlyThatJobAndSchedulerContinues() async throws {
        let f = try Fixture(); f.driver.snapshots["A"] = ControlledDriver.snapshot("OTHER")
        await f.start(["A", "B"])
        let inputs = await f.generator.inputs; XCTAssertEqual(inputs.map(\.uid), ["B"])
        XCTAssertNotNil(f.scheduler.records.first { $0.uid == "A" }?.lastError)
        XCTAssertEqual(f.scheduler.records.first { $0.uid == "A" }?.state, .discovered)
        XCTAssertTrue(f.scheduler.isRunning)
        XCTAssertTrue(f.driver.operations.contains("capture:B"))
        await f.shutdown()
    }

    func testDiscoveryErrorIsLoggedAndNextTickRetriesWithoutStoppingScheduler() async throws {
        let f = try Fixture(); f.driver.discoveryErrorsRemaining = 1; f.driver.unread = ["A"]
        f.scheduler.start(); await f.scheduler.tick()
        for _ in 0..<100 {
            if f.scheduler.status.contains("conversation list changed") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(f.scheduler.isRunning)
        XCTAssertTrue(f.scheduler.status.contains("conversation list changed"))
        XCTAssertTrue(f.scheduler.events.contains { $0.message.contains("conversation list changed") })
        await f.drive()
        XCTAssertTrue(f.driver.operations.contains("capture:A"))
        XCTAssertTrue(f.scheduler.isRunning)
        XCTAssertEqual(f.scheduler.status, "Running")
        XCTAssertTrue(f.scheduler.events.contains { $0.message.contains("Scheduler recovered") })
        await f.shutdown()
    }

    func testCaptureFailureBacksOffAndOtherUIDAdvances() async throws {
        let f = try Fixture(); f.driver.captureError = true
        await f.start(["A", "B"])
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 1)
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:B" }.count, 1)
        XCTAssertTrue(f.scheduler.records.allSatisfy { $0.lastError != nil && $0.nextAttemptAt > Date(timeIntervalSince1970: 1_000) })
        await f.shutdown()
    }

    func testCaptureRetryCannotAttemptImageCopyTwiceForSameTask() async throws {
        let f = try Fixture()
        f.driver.captureError = true
        await f.start(["A"])
        f.driver.captureError = false
        f.clock.value += 2
        await f.drive()

        XCTAssertEqual(f.driver.captureImageFlags, [true, false])
        await f.shutdown()
    }

    func testFailureBeforeMediaDetectionDoesNotConsumeTheMediaAttempt() async throws {
        let f = try Fixture()
        f.driver.captureAutomationError = .captureFailedBeforeMedia("reception window not frontmost")
        await f.start(["A"])

        f.driver.captureAutomationError = nil
        f.clock.value += 2
        await f.drive()

        XCTAssertEqual(f.driver.captureImageFlags, [true, true])
        await f.shutdown()
    }

    func testUncertainAndThrownSendsAreNeverAutomaticallyRetried() async throws {
        for throwsSend in [false, true] {
            let f = try Fixture(); f.driver.sendError = throwsSend; f.driver.delivery = .uncertain("no acknowledgement")
            await f.start(["A"]); await f.generator.complete("A"); await f.drive()
            XCTAssertEqual(f.scheduler.records.first?.state, .completed)
            XCTAssertEqual(f.scheduler.records.first?.deliveryOutcome, .uncertain)
            f.driver.unread = ["A"]; await f.drive()
            XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:") }.count, 1)
            await f.shutdown()
        }
    }

    func testStoreRefusesMissingOrCorruptExistingState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheduler-corrupt-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SchedulerStore(rootURL: root))
        try Data("not json".utf8).write(to: root.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try SchedulerStore(rootURL: root))
    }

    func testCompletedCustomerIsNotRecapturedWithoutAnotherRedDot() async throws {
        let f = try Fixture(); await f.start(["A"])
        await f.generator.complete("A"); await f.drive()
        f.driver.snapshots["A"] = ControlledDriver.snapshot("A", revision: "r2", history: "new supplement without dot")
        f.clock.value += 6; await f.drive()
        let inputs = await f.generator.inputs
        XCTAssertEqual(inputs.map(\.historyVersion), ["r1"])
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 1)
        XCTAssertEqual(f.driver.operations.filter { $0 == "captureBeforeDelivery:A" }.count, 0)
        XCTAssertEqual(f.scheduler.records.filter { $0.state == .generating }.count, 0)
        await f.shutdown()
    }

    func testCompletedObservationIsNotRecapturedWithoutAnotherRedDot() async throws {
        let f = try Fixture(); f.driver.snapshots["A"] = ControlledDriver.snapshot("A", generate: false)
        await f.start(["A"])
        for _ in 0..<4 { f.clock.value += 6; await f.drive() }
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 1)
        XCTAssertEqual(f.scheduler.records.count, 1)
        let inputs = await f.generator.inputs; XCTAssertTrue(inputs.isEmpty)
        await f.shutdown()
    }

    func testTerminalObservationRearmsAfterHalfSecondInsteadOfBlindFiveSecondSleep() async throws {
        let f = try Fixture(); f.driver.snapshots["A"] = ControlledDriver.snapshot("A", generate: false)
        await f.start(["A"])

        let completed = try XCTUnwrap(f.scheduler.records.first)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.nextAttemptAt.timeIntervalSince(f.clock.value), 0.5, accuracy: 0.001)
        await f.shutdown()
    }

    func testUnsafeCaptureBacksOffThatJobAndOtherUIDAdvancesWithoutStoppingScheduler() async throws {
        let f = try Fixture(); f.driver.unsafeCaptureError = true
        await f.start(["A", "B"])
        XCTAssertTrue(f.scheduler.isRunning)
        XCTAssertTrue(f.driver.operations.contains("capture:B"))
        XCTAssertTrue(f.scheduler.events.contains { $0.message.contains("competing operator") })
        XCTAssertNotNil(f.scheduler.records.first?.lastError)
        await f.shutdown()
    }

    func testForegroundActivationFailureParksAfterOneBoundedRetry() async throws {
        let f = try Fixture()
        f.driver.unsafeCaptureError = true
        f.driver.unsafeCaptureMessage = "千牛控件操作失败：千牛未成功置前"
        await f.start(["A"])

        XCTAssertEqual(f.scheduler.records.first?.nextAttemptAt, f.clock.value.addingTimeInterval(1))
        f.clock.value += 1
        await f.drive()
        XCTAssertEqual(f.scheduler.records.first?.state, .parked)
        XCTAssertEqual(f.scheduler.records.first?.retries, 2)
        await f.shutdown()
    }

    func testOpenConversationIdentityFailureIsReleasedAfterTwoAttemptsAndScanningContinues() async throws {
        let f = try Fixture()
        f.driver.unsafeCaptureError = true
        f.driver.unsafeCaptureMessage = "打开聊天后完整 UID 核对失败"
        await f.start(["A"])

        f.clock.value += 2
        await f.drive()
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 2)
        XCTAssertEqual(f.scheduler.records.first { $0.uid == "A" }?.state, .parked)

        f.driver.unsafeCaptureError = false
        f.driver.unread = ["B"]
        await f.drive()
        XCTAssertTrue(f.driver.operations.contains("capture:B"))
        await f.shutdown()
    }

    func testUncertainDeliveryQuarantinesOnlyThatJobAndSchedulerKeepsDiscovering() async throws {
        let f = try Fixture(); f.driver.delivery = .uncertain("no acknowledgement")
        await f.start(["A"]); await f.generator.complete("A"); await f.drive()
        XCTAssertEqual(f.scheduler.records.first?.state, .completed)
        XCTAssertTrue(f.scheduler.isRunning)
        f.driver.unread = ["B"]; await f.drive()
        XCTAssertTrue(f.driver.operations.contains("capture:B"))
        XCTAssertTrue(f.scheduler.isRunning)
        await f.shutdown()
    }

    func testStartPumpsWithoutManualTicks() async throws {
        let f = try Fixture(); f.driver.unread = ["A"]; f.scheduler.start()
        for _ in 0..<150 {
            if await f.generator.startedUIDs == ["A"] { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await f.generator.startedUIDs; XCTAssertEqual(started, ["A"])
        await f.shutdown()
    }

    func testSafePreSendFailureRetainsReplyAndRetriesWithCooldown() async throws {
        let f = try Fixture(); f.driver.delivery = .failedBeforeSend("composer not ready")
        await f.start(["A"]); await f.generator.complete("A"); await f.drive()
        XCTAssertEqual(f.scheduler.records.first?.state, .ready)
        XCTAssertEqual(f.scheduler.records.first?.retries, 1)
        XCTAssertEqual(f.driver.operations.filter { $0.hasPrefix("send:") }.count, 1)
        f.driver.delivery = .sent; f.clock.value += 3; await f.drive()
        XCTAssertEqual(f.scheduler.records.first?.state, .completed)
        XCTAssertEqual(f.driver.operations.filter { $0 == "send:A:answer-A" }.count, 2)
        let inputs = await f.generator.inputs; XCTAssertEqual(inputs.count, 1)
        await f.shutdown()
    }

    func testRepeatedPreSendFailuresRetainReplyAndYieldToAnotherUID() async throws {
        let f = try Fixture()
        f.driver.delivery = .failedBeforeSend("composer not ready")
        await f.start(["A"])
        await f.generator.complete("A")
        await f.drive()

        XCTAssertEqual(f.scheduler.records.first { $0.uid == "A" }?.state, .ready)
        XCTAssertEqual(f.driver.operations.filter { $0 == "send:A:answer-A" }.count, 1)

        f.driver.unread = ["B"]
        await f.drive()
        let firstSend = try XCTUnwrap(f.driver.operations.firstIndex(of: "send:A:answer-A"))
        let captureB = try XCTUnwrap(f.driver.operations.firstIndex(of: "capture:B"))
        XCTAssertGreaterThan(captureB, firstSend)

        f.clock.value += 2
        await f.drive()
        let recordA = try XCTUnwrap(f.scheduler.records.first { $0.uid == "A" })
        XCTAssertEqual(f.driver.operations.filter { $0 == "send:A:answer-A" }.count, 2)
        XCTAssertEqual(recordA.state, .ready)
        XCTAssertNil(recordA.deliveryOutcome)
        XCTAssertNil(recordA.archiveReference)
        XCTAssertEqual(recordA.reply?.replyText, "answer-A")

        f.driver.delivery = .sent
        f.driver.unread = ["C"]
        await f.drive()
        f.clock.value += 5
        await f.drive()
        XCTAssertTrue(f.driver.operations.contains("capture:C"))
        XCTAssertEqual(f.scheduler.records.first { $0.uid == "A" }?.state, .completed)
        await f.shutdown()
    }

    func testRuntimeIssueCannotOverwriteARealPersistenceStop() async throws {
        let f = try Fixture(); f.driver.delivery = .failedBeforeSend("composer not ready")
        await f.start(["A"])
        f.driver.sendCheck = {
            try FileManager.default.removeItem(at: f.store.stateURL)
            try FileManager.default.createDirectory(at: f.store.stateURL, withIntermediateDirectories: false)
        }
        await f.generator.complete("A"); await f.drive()
        XCTAssertFalse(f.scheduler.isRunning)
        XCTAssertTrue(f.scheduler.status.lowercased().contains("persistence"))
        XCTAssertFalse(f.scheduler.status.hasPrefix("Running"))
        await f.shutdown()
    }

    func testCaptureParksAfterSecondFailureAndNewRedDotCreatesFreshAttempt() async throws {
        let f = try Fixture(); f.driver.captureError = true; await f.start(["A"])
        f.clock.value += 1; await f.drive()
        XCTAssertEqual(f.driver.operations.filter { $0 == "capture:A" }.count, 2)
        XCTAssertEqual(f.scheduler.records.first?.state, .parked)
        XCTAssertEqual(f.scheduler.records.count, 1)
        XCTAssertNotNil(f.scheduler.records.first?.lastError)
        f.driver.captureError = false
        f.driver.unread = ["A"]
        await f.drive()
        let inputs = await f.generator.inputs
        XCTAssertEqual(inputs.map(\.uid), ["A"])
        XCTAssertEqual(f.scheduler.records.filter { $0.uid == "A" }.count, 2)
        XCTAssertEqual(f.scheduler.records.first?.state, .parked)
        await f.shutdown()
    }

    func testRepeatedPreSendFailuresNeverArchiveOrRegenerateTheReply() async throws {
        let f = try Fixture(); f.driver.delivery = .failedBeforeSend("composer not ready")
        await f.start(["A"]); await f.generator.complete("A"); await f.drive()
        f.clock.value += 3; await f.drive()
        XCTAssertEqual(f.scheduler.records.first?.state, .ready)
        XCTAssertNil(f.scheduler.records.first?.deliveryOutcome)
        XCTAssertEqual(f.scheduler.records.count, 1)
        var inputs = await f.generator.inputs; XCTAssertEqual(inputs.count, 1)
        f.driver.delivery = .sent; f.clock.value += 30; await f.drive()
        XCTAssertEqual(f.scheduler.records.first?.state, .completed)
        XCTAssertEqual(f.driver.operations.filter { $0 == "send:A:answer-A" }.count, 3)
        inputs = await f.generator.inputs; XCTAssertEqual(inputs.count, 1)
        await f.shutdown()
    }

    func testStaleCleanupCannotReleaseNewGenerationOfSameUID() async throws {
        let cursorA = CustomerCursor(count: 1, digest: String(repeating: "a", count: 64))
        let cursorB = CustomerCursor(count: 2, digest: String(repeating: "b", count: 64))
        let f = try Fixture()
        f.driver.snapshots["A"] = CaptureSnapshot(
            uid: "A", customerRevision: cursorA.digest, historyJSONL: "question A",
            hasUnansweredCustomer: true, shouldGenerate: true,
            targetCustomerJSONL: "question A", startCursor: .empty, endCursor: cursorA
        )
        await f.start(["A"])
        let gate = Gate(); let cleanup = Task { await gate.wait() }
        f.driver.snapshots["A"] = CaptureSnapshot(
            uid: "A", customerRevision: cursorB.digest, historyJSONL: "question A then B",
            hasUnansweredCustomer: true, shouldGenerate: true,
            targetCustomerJSONL: "question B", startCursor: cursorA, endCursor: cursorB
        )
        await f.generator.complete("A", text: "stale", cleanup: cleanup); await f.drive()
        f.scheduler.stop(); f.scheduler.start(); await f.drive()
        var inputs = await f.generator.inputs; XCTAssertEqual(inputs.count, 1)
        await gate.release()
        f.clock.value = f.clock.value.addingTimeInterval(1)
        f.driver.unread = ["A"]
        await f.drive()
        inputs = await f.generator.inputs; XCTAssertEqual(inputs.map(\.historyVersion), [cursorA.digest, cursorB.digest])
        f.driver.unread = ["A", "B"]; await f.drive()
        inputs = await f.generator.inputs
        XCTAssertEqual(inputs.filter { $0.uid == "A" }.map(\.historyVersion), [cursorA.digest, cursorB.digest])
        XCTAssertEqual(inputs.filter { $0.uid == "B" }.count, 1)
        XCTAssertEqual(f.scheduler.liveGenerationCount, 2)
        XCTAssertEqual(f.scheduler.records.filter { $0.uid == "A" && !$0.state.isTerminal }.count, 1)
        await f.shutdown()
    }

    func testObserverStopPreventsNextOperationAfterPersistedStateChange() async throws {
        let boundaries: [(SchedulerJobState, SchedulerJobState)] = [
            (.capturing, .discovered), (.generating, .queued), (.sending, .ready)
        ]
        for (boundary, resumable) in boundaries {
            let f = try Fixture()
            f.scheduler.onChange = {
                if f.scheduler.isRunning && f.scheduler.records.first?.state == boundary {
                    f.scheduler.stop()
                }
            }
            await f.start(["A"])
            if boundary == .sending { await f.generator.complete("A"); await f.drive() }
            XCTAssertFalse(f.scheduler.isRunning, "\(boundary)")
            XCTAssertEqual(try f.store.load().records.first?.state, resumable, "\(boundary)")
            XCTAssertFalse(f.driver.operations.contains { $0.hasPrefix("send:") }, "\(boundary)")
            let inputs = await f.generator.inputs
            XCTAssertEqual(inputs.count, boundary == .sending ? 1 : 0, "\(boundary)")
            if boundary == .capturing { XCTAssertFalse(f.driver.operations.contains("capture:A")) }

            f.scheduler.onChange = nil
            f.scheduler.start(); await f.drive()
            if boundary != .sending { await f.generator.complete("A"); await f.drive() }
            XCTAssertEqual(f.scheduler.records.first?.state, .completed, "\(boundary)")
            XCTAssertEqual(f.driver.operations.filter { $0 == "send:A:answer-A" }.count, 1, "\(boundary)")
            await f.shutdown()
        }
    }

    func testObserverSeesLiveSlotImmediatelyAfterGenerationRegistration() async throws {
        let f = try Fixture()
        var observedLiveCounts: [Int] = []
        f.scheduler.onChange = { observedLiveCounts.append(f.scheduler.liveGenerationCount) }
        await f.start(["A"])
        XCTAssertTrue(observedLiveCounts.contains(1))
        XCTAssertEqual(observedLiveCounts.last, 1)
        f.scheduler.onChange = nil
        await f.shutdown()
    }

    func testQuitOwnershipRemainsWhileStoppedCaptureIsSuspended() async throws {
        let f = try Fixture()
        let gate = Gate(); f.driver.captureGates["A"] = gate
        f.driver.unread = ["A"]; f.scheduler.start()
        for _ in 0..<100 {
            await f.scheduler.tick()
            if f.driver.operations.contains("capture:A") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(f.scheduler.hasActiveUIOperation)
        f.scheduler.stop()
        XCTAssertTrue(f.scheduler.hasActiveUIOperation)
        await gate.release()
        for _ in 0..<100 {
            if !f.scheduler.hasActiveUIOperation { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(f.scheduler.hasActiveUIOperation)
        await f.shutdown()
    }
}
