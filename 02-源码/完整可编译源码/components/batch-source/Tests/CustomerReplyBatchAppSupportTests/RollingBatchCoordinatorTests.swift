import XCTest
@testable import CustomerReplyBatchCore
@testable import CustomerReplyBatchAppSupport

final class RollingBatchCoordinatorTests: XCTestCase {
    func testMoreThanFiveDistinctUIDsStartWhenMemoryAllows() async throws {
        let store = try makeStore(count: 10)
        let generator = ControlledSlotGenerator()
        let coordinator = BatchCoordinator(
            store: store,
            generator: generator,
            availableMemoryBytes: { 40 << 30 }
        )
        let run = Task { await coordinator.runOnce() }

        let allStarted = await eventually { await generator.startedCount() == 10 }
        XCTAssertTrue(allStarted)
        let maximum = await generator.maximumActiveCount()
        XCTAssertEqual(maximum, 10)

        await generator.releaseAll()
        let summary = await run.value
        XCTAssertEqual(summary.autoSend, 10)
    }

    func testHardMemoryPressureLeavesPendingTasksUnclaimed() async throws {
        let store = try makeStore(count: 7)
        let generator = ControlledSlotGenerator()
        let coordinator = BatchCoordinator(
            store: store,
            generator: generator,
            availableMemoryBytes: { 512 << 20 }
        )

        let summary = await coordinator.runOnce()

        let startedCount = await generator.startedCount()
        XCTAssertEqual(startedCount, 0)
        XCTAssertEqual(summary.total, 7)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(store.hasPendingTasks())
    }

    func testExistingOutputDoesNotConsumeOrStallTheOnlySlot() async throws {
        let store = try makeStore(count: 3)
        let taskID = TaskIdentity.make(uid: "task-0", historyVersion: "v1")
        let originalOutput = Data("existing output must not be overwritten".utf8)
        let outputURL = store.layout.outgoing.appendingPathComponent("\(taskID).json")
        try originalOutput.write(to: outputURL)
        let generator = ControlledSlotGenerator()
        let coordinator = BatchCoordinator(store: store, generator: generator)
        let run = Task { await coordinator.runOnce() }
        let secondStarted = await eventually { await generator.hasStarted("task-1") }
        XCTAssertTrue(secondStarted)
        await generator.releaseAll()
        let summary = await run.value
        let firstStarted = await generator.hasStarted("task-0")
        XCTAssertFalse(firstStarted)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.noAction, 1)
        XCTAssertEqual(summary.autoSend, 2)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(try Data(contentsOf: outputURL), originalOutput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.layout.processing.appendingPathComponent("\(taskID).json").path))
    }

    func testReadyRepliesPublishBeforeIndependentCleanupCompletes() async throws {
        let store = try makeStore(count: 6)
        let generator = ControlledSlotGenerator(cleanupUIDs: Set((0..<6).map { "task-\($0)" }))
        let sender = RollingSenderTrigger()
        let coordinator = BatchCoordinator(
            store: store,
            generator: generator,
            senderTrigger: sender,
            availableMemoryBytes: { 8 << 30 }
        )
        let run = Task { await coordinator.runOnce() }
        let allStarted = await eventually { await generator.startedCount() == 6 }
        XCTAssertTrue(allStarted)
        for index in 0..<6 { await generator.release("task-\(index)") }

        let repliesPublished = await eventually { await sender.count() == 6 }
        XCTAssertTrue(repliesPublished, "Publication and sender triggering must not wait for CLI cleanup")
        for index in 0..<6 {
            XCTAssertTrue(store.outputExists(taskID: TaskIdentity.make(uid: "task-\(index)", historyVersion: "v1")))
        }
        let firstStillActive = await generator.isActive("task-0")
        XCTAssertTrue(firstStillActive)
        await generator.releaseAll()
        let summary = await run.value
        let maximumActive = await generator.maximumActiveCount()
        XCTAssertEqual(maximumActive, 6)
        XCTAssertEqual(summary.autoSend, 6)
        let triggerCount = await sender.count()
        XCTAssertEqual(triggerCount, 6)
    }

    func testRunKeepsBatchLockAndWaitsForFinalCleanupAfterPublishing() async throws {
        let store = try makeStore(count: 1)
        let generator = ControlledSlotGenerator(cleanupUIDs: ["task-0"])
        let sender = RollingSenderTrigger()
        let completion = RollingCompletionFlag()
        let coordinator = BatchCoordinator(store: store, generator: generator, senderTrigger: sender)
        let run = Task {
            let summary = await coordinator.runOnce()
            await completion.finish()
            return summary
        }
        await generator.release("task-0")
        let published = await eventually { await sender.count() == 1 }
        XCTAssertTrue(published)
        try await Task.sleep(for: .milliseconds(100))
        let finishedBeforeCleanup = await completion.isFinished()
        XCTAssertFalse(finishedBeforeCleanup, "runOnce must not let the application exit with a live CLI")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.layout.runtime.appendingPathComponent("batch.lock").path))

        await generator.releaseAll()
        let summary = await run.value
        XCTAssertEqual(summary.autoSend, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.layout.runtime.appendingPathComponent("batch.lock").path))
    }

    func testAllTasksStartWithoutWaitingForTheFirstTask() async throws {
        let store = try makeStore(count: 9)
        let generator = ControlledSlotGenerator()
        let coordinator = BatchCoordinator(
            store: store,
            generator: generator,
            availableMemoryBytes: { 8 << 30 }
        )
        let run = Task { await coordinator.runOnce() }
        let allStarted = await eventually { await generator.startedCount() == 9 }
        let firstStillRunning = await generator.isActive("task-0")
        XCTAssertTrue(allStarted)
        XCTAssertTrue(firstStillRunning)

        await generator.releaseAll()
        let summary = await run.value
        let maximumActive = await generator.maximumActiveCount()
        XCTAssertEqual(summary.total, 9)
        XCTAssertEqual(summary.autoSend, 9)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(maximumActive, 9)
    }

    func testFailedSlotStartsNextTaskWithoutWaitingForOtherSlots() async throws {
        let store = try makeStore(count: 6)
        let generator = ControlledSlotGenerator(failingUIDs: ["task-1"])
        let coordinator = BatchCoordinator(
            store: store,
            generator: generator,
            availableMemoryBytes: { 8 << 30 }
        )
        let run = Task { await coordinator.runOnce() }
        let allStarted = await eventually { await generator.startedCount() == 6 }
        XCTAssertTrue(allStarted)

        await generator.release("task-1")

        await generator.releaseAll()
        let summary = await run.value
        XCTAssertEqual(summary.autoSend, 5)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.layout.failed
            .appendingPathComponent("\(TaskIdentity.make(uid: "task-1", historyVersion: "v1")).json").path))
    }

    private func makeStore(count: Int) throws -> QueueStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try QueueStore(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for index in 0..<count {
            let uid = "task-\(index)"
            let user = root.appendingPathComponent("用户/\(uid)", isDirectory: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            try Data("{\"sender\":\"customer\",\"v\":\"你好\"}\n".utf8)
                .write(to: user.appendingPathComponent("history.jsonl"))
            try store.writePending(QueuePointer(
                uid: uid,
                userDirectory: user.path,
                historyVersion: "v1",
                queuedAt: "2026-08-24T10:00:\(String(format: "%02d", index))Z"
            ))
        }
        return store
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

private actor ControlledSlotGenerator: ReplyGenerating {
    private let failingUIDs: Set<String>
    private let cleanupUIDs: Set<String>
    private var started: Set<String> = []
    private var active: Set<String> = []
    private var maximumActive = 0
    private var released: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var cleanupReleased: Set<String> = []
    private var cleanupWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var allReleased = false

    init(failingUIDs: Set<String> = [], cleanupUIDs: Set<String> = []) {
        self.failingUIDs = failingUIDs
        self.cleanupUIDs = cleanupUIDs
    }

    func generate(for input: PromptInput) async throws -> GeneratedReply {
        started.insert(input.uid)
        active.insert(input.uid)
        maximumActive = max(maximumActive, active.count)
        if !allReleased && !released.contains(input.uid) {
            await withCheckedContinuation { waiters[input.uid] = $0 }
        }
        if failingUIDs.contains(input.uid) {
            active.remove(input.uid)
            throw NSError(domain: "ControlledSlotGenerator", code: 1)
        }
        let cleanupTask: Task<Void, Never>?
        if cleanupUIDs.contains(input.uid) {
            cleanupTask = Task { await self.finishCleanup(input.uid) }
        } else {
            active.remove(input.uid)
            cleanupTask = nil
        }
        return GeneratedReply(reply: ReplyEnvelope(
            decision: .autoSend,
            riskLevel: .low,
            replyText: "您好",
            reason: "普通咨询"
        ), cleanupTask: cleanupTask)
    }

    func release(_ uid: String) {
        released.insert(uid)
        waiters.removeValue(forKey: uid)?.resume()
    }

    func releaseAll() {
        allReleased = true
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
        let pendingCleanup = cleanupWaiters.values
        cleanupWaiters.removeAll()
        for waiter in pendingCleanup { waiter.resume() }
    }

    func releaseCleanup(_ uid: String) {
        cleanupReleased.insert(uid)
        cleanupWaiters.removeValue(forKey: uid)?.resume()
    }

    private func finishCleanup(_ uid: String) async {
        if !allReleased && !cleanupReleased.contains(uid) {
            await withCheckedContinuation { cleanupWaiters[uid] = $0 }
        }
        active.remove(uid)
    }

    func startedCount() -> Int { started.count }
    func hasStarted(_ uid: String) -> Bool { started.contains(uid) }
    func isActive(_ uid: String) -> Bool { active.contains(uid) }
    func maximumActiveCount() -> Int { maximumActive }
}

private actor RollingSenderTrigger: SenderTriggering {
    private var triggers = 0
    func trigger() async { triggers += 1 }
    func count() -> Int { triggers }
}

private actor RollingCompletionFlag {
    private var finished = false
    func finish() { finished = true }
    func isFinished() -> Bool { finished }
}
