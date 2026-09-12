import XCTest
@testable import CustomerReplyBatchCore
@testable import CustomerReplyBatchAppSupport

final class BatchCoordinatorTests: XCTestCase {
    func testRecordsExactSortedImagePathsPassedToCodexForEachTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try QueueStore(root: root)
        let uid = "image-user"
        try makeUserAndQueue(uid: uid, root: root, store: store, queuedAt: "2026-08-24T10:00:00Z")
        let images = root.appendingPathComponent("用户/\(uid)/images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let first = images.appendingPathComponent("20260825-1701-1.jpg")
        let second = images.appendingPathComponent("20260825-1702-2.png")
        try Data([1]).write(to: second)
        try Data([2]).write(to: first)
        try Data([3]).write(to: images.appendingPathComponent("ignore.txt"))
        let expectedPaths = try FileManager.default.contentsOfDirectory(
            at: images,
            includingPropertiesForKeys: nil
        )
        .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map(\.path)
        let coordinator = BatchCoordinator(store: store, generator: TimedFixtureGenerator())

        let summary = await coordinator.runOnce()

        XCTAssertEqual(summary.autoSend, 1)
        let taskID = TaskIdentity.make(uid: uid, historyVersion: "v1")
        let recordURL = store.layout.runtime
            .appendingPathComponent("Codex图片", isDirectory: true)
            .appendingPathComponent("\(taskID).json")
        let data = try Data(contentsOf: recordURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["uid"] as? String, uid)
        XCTAssertEqual(object["task_id"] as? String, taskID)
        XCTAssertEqual(
            object["image_paths"] as? [String],
            expectedPaths
        )
        let readable = try String(
            contentsOf: store.layout.runtime.appendingPathComponent("最近一次Codex图片.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(readable.contains(expectedPaths[0]))
        XCTAssertTrue(readable.contains(expectedPaths[1]))
    }

    func testSuccessfulTaskPublishesMachineAndHumanTimingLogs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try QueueStore(root: root)
        try makeUserAndQueue(uid: "timed", root: root, store: store, queuedAt: "2026-08-24T10:00:00Z")
        let logger = BatchTimingLogger(runtimeDirectory: store.layout.runtime)
        let coordinator = BatchCoordinator(
            store: store,
            generator: TimedFixtureGenerator(),
            onTiming: { record in logger.record(record) }
        )

        let summary = await coordinator.runOnce()

        XCTAssertEqual(summary.autoSend, 1)
        let jsonl = try String(contentsOf: store.layout.runtime.appendingPathComponent("耗时日志.jsonl"))
        let line = try XCTUnwrap(jsonl.split(separator: "\n").last)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["uid"] as? String, "timed")
        XCTAssertEqual(object["login_check_ms"] as? Double, 12.5)
        XCTAssertEqual(object["codex_exec_ms"] as? Double, 345.0)
        XCTAssertEqual(object["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(object["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(object["cli_trace_report_path"] as? String, "/test/CLI明细/example.txt")
        XCTAssertEqual(object["session_mode"] as? String, "resumed")
        XCTAssertEqual(object["submitted_history_bytes"] as? Int, 42)
        XCTAssertEqual(object["submitted_image_count"] as? Int, 1)
        XCTAssertEqual(object["session_recovery_count"] as? Int, 0)
        XCTAssertNotNil(object["prompt_load_ms"] as? Double)
        XCTAssertNotNil(object["publish_ms"] as? Double)
        XCTAssertNotNil(object["task_processing_ms"] as? Double)

        let text = try String(contentsOf: store.layout.runtime.appendingPathComponent("最近一次耗时.txt"))
        XCTAssertTrue(text.contains("UID：timed"))
        XCTAssertTrue(text.contains("模型：gpt-5.6-sol"))
        XCTAssertTrue(text.contains("推理强度：medium"))
        XCTAssertTrue(text.contains("登录检查：12.5 ms"))
        XCTAssertTrue(text.contains("Codex 执行（至结果可用）：345.0 ms"))
        XCTAssertTrue(text.contains("/test/CLI明细/example.txt"))
        XCTAssertTrue(text.contains("会话模式：resumed"))
        XCTAssertTrue(text.contains("本轮提交历史：42 bytes"))
    }

    func testRunProcessesEntireStartupSnapshotAndContinuesAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try QueueStore(root: root)
        for (index, uid) in ["auto", "review", "fail"].enumerated() {
            let user = root.appendingPathComponent("用户/\(uid)", isDirectory: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            try Data("{\"sender\":\"customer\",\"v\":\"你好\"}\n".utf8).write(to: user.appendingPathComponent("history.jsonl"))
            try Data("客户：你好".utf8).write(to: user.appendingPathComponent("history.txt"))
            try store.writePending(QueuePointer(uid: uid, userDirectory: user.path, historyVersion: "v1", queuedAt: "2026-08-24T10:0\(index):00Z"))
        }
        let coordinator = BatchCoordinator(store: store, generator: FixtureGenerator())

        let summary = await coordinator.runOnce()

        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.autoSend, 2)
        XCTAssertEqual(summary.humanReview, 0)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.layout.outgoing.path).filter { $0.hasSuffix(".json") }.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.layout.humanReview.path).filter { $0.hasSuffix(".json") }.count, 0)
    }

    func testRunContinuesWhenAnotherTaskIsQueuedDuringTheFirstPass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try QueueStore(root: root)
        try makeUserAndQueue(uid: "first", root: root, store: store, queuedAt: "2026-08-24T10:00:00Z")
        let generator = EnqueuingGenerator(root: root, store: store)
        let coordinator = BatchCoordinator(store: store, generator: generator)

        let summary = await coordinator.runOnce()

        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.autoSend, 2)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertFalse(store.hasRunRequest())
        XCTAssertFalse(store.hasPendingTasks())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.layout.outgoing.path)
                .filter { $0.hasSuffix(".json") }.count,
            2
        )
    }

    func testEachAutoSendPublicationTriggersSenderOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try QueueStore(root: root)
        for uid in ["auto", "review"] {
            try makeUserAndQueue(uid: uid, root: root, store: store, queuedAt: "2026-08-24T10:00:00Z")
        }
        let trigger = RecordingSenderTrigger()
        let coordinator = BatchCoordinator(store: store, generator: FixtureGenerator(), senderTrigger: trigger)

        let summary = await coordinator.runOnce()

        XCTAssertEqual(summary.autoSend, 2)
        let triggerCount = await trigger.currentCount()
        XCTAssertEqual(triggerCount, 2)
    }

    func testRunStartsEveryDistinctCustomerWithoutFixedFive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try QueueStore(root: root)
        for index in 0..<9 {
            try makeUserAndQueue(
                uid: "parallel-\(index)",
                root: root,
                store: store,
                queuedAt: "2026-08-24T10:00:\(String(format: "%02d", index))Z"
            )
        }
        let generator = ConcurrencyTrackingGenerator()
        let coordinator = BatchCoordinator(
            store: store,
            generator: generator,
            availableMemoryBytes: { 8 << 30 }
        )

        let summary = await coordinator.runOnce()

        XCTAssertEqual(summary.total, 9)
        XCTAssertEqual(summary.autoSend, 9)
        XCTAssertEqual(summary.failed, 0)
        let maximumObservedConcurrency = await generator.maximumObservedConcurrency()
        XCTAssertEqual(maximumObservedConcurrency, 9)
    }

    private func makeUserAndQueue(
        uid: String,
        root: URL,
        store: QueueStore,
        queuedAt: String
    ) throws {
        let user = root.appendingPathComponent("用户/\(uid)", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data("{\"sender\":\"customer\",\"v\":\"你好\"}\n".utf8)
            .write(to: user.appendingPathComponent("history.jsonl"))
        try store.writePending(
            QueuePointer(
                uid: uid,
                userDirectory: user.path,
                historyVersion: "v1",
                queuedAt: queuedAt
            )
        )
    }
}

private actor RecordingSenderTrigger: SenderTriggering {
    private var count = 0
    func trigger() async { count += 1 }
    func currentCount() -> Int { count }
}

private struct FixtureGenerator: ReplyGenerating {
    func generate(for input: PromptInput) async throws -> GeneratedReply {
        switch input.uid {
        case "auto": return GeneratedReply(reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "您好", reason: "普通咨询"))
        case "review": return GeneratedReply(reply: ReplyEnvelope(decision: .humanReview, riskLevel: .medium, replyText: "您好，这个问题正在为您处理。", reason: "需人工"))
        default: throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "模拟失败"])
        }
    }
}

private struct TimedFixtureGenerator: ReplyGenerating {
    func generate(for input: PromptInput) async throws -> GeneratedReply {
        GeneratedReply(
            reply: ReplyEnvelope(
                decision: .autoSend,
                riskLevel: .low,
                replyText: "您好",
                reason: "普通咨询"
            ),
            timing: ReplyGenerationTiming(
                model: "gpt-5.6-sol",
                reasoningEffort: "medium",
                loginCheckMilliseconds: 12.5,
                codexExecMilliseconds: 345.0,
                decodeMilliseconds: 1.5,
                totalMilliseconds: 359.0,
                cliTraceReportPath: "/test/CLI明细/example.txt",
                sessionMode: "resumed",
                submittedHistoryBytes: 42,
                submittedImageCount: 1,
                sessionLeaseAgeMilliseconds: 500,
                sessionRecoveryCount: 0
            )
        )
    }
}

private actor EnqueuingGenerator: ReplyGenerating {
    private let root: URL
    private let store: QueueStore
    private var didEnqueue = false

    init(root: URL, store: QueueStore) {
        self.root = root
        self.store = store
    }

    func generate(for input: PromptInput) async throws -> GeneratedReply {
        if !didEnqueue {
            didEnqueue = true
            let user = root.appendingPathComponent("用户/second", isDirectory: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            try Data("{\"sender\":\"customer\",\"v\":\"第二条\"}\n".utf8)
                .write(to: user.appendingPathComponent("history.jsonl"))
            try store.writePending(
                QueuePointer(
                    uid: "second",
                    userDirectory: user.path,
                    historyVersion: "v1",
                    queuedAt: "2026-08-24T10:01:00Z"
                )
            )
            try store.requestRun()
        }
        return GeneratedReply(
            reply: ReplyEnvelope(
                decision: .autoSend,
                riskLevel: .low,
                replyText: "您好",
                reason: "普通咨询"
            )
        )
    }
}

private actor ConcurrencyTrackingGenerator: ReplyGenerating {
    private var active = 0
    private var maximumActive = 0

    func generate(for input: PromptInput) async throws -> GeneratedReply {
        active += 1
        maximumActive = max(maximumActive, active)
        try await Task.sleep(for: .milliseconds(100))
        active -= 1
        return GeneratedReply(
            reply: ReplyEnvelope(
                decision: .autoSend,
                riskLevel: .low,
                replyText: "并发测试回复",
                reason: "并发测试"
            )
        )
    }

    func maximumObservedConcurrency() -> Int { maximumActive }
}
