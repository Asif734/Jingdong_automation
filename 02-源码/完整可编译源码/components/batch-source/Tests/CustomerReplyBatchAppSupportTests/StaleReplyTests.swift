import Foundation
import XCTest
@testable import CustomerReplyBatchCore
@testable import CustomerReplyBatchAppSupport

final class StaleReplyTests: XCTestCase {
    func testGeneratedReplyIsStillAutoSentWhenHistoryAdvancesBeforePublish() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-reply-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try QueueStore(root: root)
        let user = root.appendingPathComponent("用户/u1", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data("{\"sender\":\"customer\",\"v\":\"第一条\"}\n".utf8)
            .write(to: user.appendingPathComponent("history.jsonl"))
        try store.writePending(pointer(user: user, historyVersion: "v1"))
        let generator = SuspendingReplyGenerator()
        let coordinator = BatchCoordinator(store: store, generator: generator)

        async let result = coordinator.runOnce()
        await generator.waitUntilStarted()
        try store.writePending(pointer(user: user, historyVersion: "v2"))
        await generator.resume()
        let summary = await result

        XCTAssertEqual(summary.autoSend, 1)
        XCTAssertEqual(summary.noAction, 0)
        XCTAssertTrue(store.hasPendingTasks())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.layout.outgoing.path)
                .filter { $0.hasSuffix(".json") }.count,
            1
        )
    }

    func testInProcessTriggerCoalescesConcurrentDrainRequests() async {
        let drain = DrainRecorder()
        let trigger = InProcessSenderTrigger {
            await drain.run()
        }

        let first = Task { await trigger.trigger() }
        await drain.waitUntilFirstDrainStarted()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await trigger.trigger() }
            }
        }
        await drain.releaseFirstDrain()
        await first.value

        let stats = await drain.stats()
        XCTAssertEqual(stats.peak, 1)
        XCTAssertEqual(stats.count, 2)
    }

    private func pointer(user: URL, historyVersion: String) -> QueuePointer {
        QueuePointer(
            uid: "u1",
            userDirectory: user.path,
            historyVersion: historyVersion,
            queuedAt: "2026-08-25T00:00:00Z"
        )
    }
}

private actor SuspendingReplyGenerator: ReplyGenerating {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationContinuation: CheckedContinuation<Void, Never>?
    private var didSuspend = false

    func generate(for input: PromptInput) async throws -> GeneratedReply {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !didSuspend {
            didSuspend = true
            await withCheckedContinuation { continuation in
                generationContinuation = continuation
            }
        }
        return GeneratedReply(
            reply: ReplyEnvelope(
                decision: .autoSend,
                riskLevel: .low,
                replyText: "旧回复",
                reason: "测试"
            )
        )
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        generationContinuation?.resume()
        generationContinuation = nil
    }
}

private actor DrainRecorder {
    private var count = 0
    private var active = 0
    private var peak = 0
    private var firstStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func run() async {
        count += 1
        active += 1
        peak = max(peak, active)
        if count == 1 {
            firstStarted = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        active -= 1
    }

    func waitUntilFirstDrainStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstDrain() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    func stats() -> (count: Int, peak: Int) { (count, peak) }
}
