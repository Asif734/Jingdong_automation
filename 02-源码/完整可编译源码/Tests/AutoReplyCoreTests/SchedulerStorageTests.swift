import XCTest
@testable import AutoReplyCore
import CustomerReplyBatchCore

final class SchedulerStorageTests: XCTestCase {
    func testConcurrentStaleSavesAreSerializedAndCheckpointRemainsValid() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        let storage = SchedulerStorage(store: store)
        let base = try await storage.load()

        func candidate(uid: String) -> SchedulerPersistentState {
            var state = base
            state.records.append(SchedulerRecord(uid: uid, sequence: 0))
            state.nextSequence = 1
            state.events.append(SchedulerEvent(date: Date(), uid: uid, message: "candidate-\(uid)"))
            return state
        }

        func save(_ state: SchedulerPersistentState) async -> Result<SchedulerPersistentState, Error> {
            do { return .success(try await storage.saveAndReload(state)) }
            catch { return .failure(error) }
        }
        async let first = save(candidate(uid: "A"))
        async let second = save(candidate(uid: "B"))
        let outcomes = await [first, second]

        XCTAssertEqual(outcomes.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(outcomes.filter { if case .failure = $0 { true } else { false } }.count, 1)
        let final = try await storage.load()
        XCTAssertEqual(final.records.count, 1)
        XCTAssertTrue(["A", "B"].contains(final.records[0].uid))
        XCTAssertEqual(try store.load(), final)
    }

    func testCommitKeepsHigherProgressExecutionAndMovesOtherWorkBackWithoutFailing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-storage-conflict-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        let snapshot = CaptureSnapshot(
            uid: "buyer", customerRevision: "r1", historyJSONL: "question",
            hasUnansweredCustomer: true, shouldGenerate: true
        )
        let firstAttempt = UUID()
        let secondAttempt = UUID()
        var initial = try store.load()
        initial.records = [
            SchedulerRecord(
                uid: "buyer", sequence: 0, state: .capturing,
                attemptID: firstAttempt
            ),
            SchedulerRecord(
                uid: "buyer", sequence: 1, state: .queued,
                snapshot: snapshot
            )
        ]
        initial.nextSequence = 2
        try store.save(initial)
        let storage = SchedulerStorage(store: store)

        let repaired = try await storage.commit(
            date: Date(timeIntervalSince1970: 2_000),
            message: "simulated overlapping transition",
            uid: "buyer"
        ) { state in
            state.records[1].state = .generating
            state.records[1].attemptID = secondAttempt
        }

        XCTAssertEqual(repaired.records.map(\.state), [.discovered, .generating])
        XCTAssertEqual(repaired.records.map(\.sequence), [2, 1])
        XCTAssertEqual(repaired.nextSequence, 3)
        XCTAssertNil(repaired.records[0].attemptID)
        XCTAssertEqual(repaired.records[1].attemptID, secondAttempt)
        XCTAssertTrue(repaired.events.contains {
            $0.message.contains("Automatically repaired overlapping customer execution")
        })
    }

    func testInvokedSendIsReleasedAsUncertainInsteadOfBeingQueuedAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-storage-invoked-send-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        let snapshot = CaptureSnapshot(
            uid: "buyer", customerRevision: "r1", historyJSONL: "question",
            hasUnansweredCustomer: true, shouldGenerate: true
        )
        let reply = ReplyEnvelope(
            decision: .autoSend, riskLevel: .low,
            replyText: "answer", reason: "fixture"
        )
        var initial = try store.load()
        initial.records = [
            SchedulerRecord(
                uid: "buyer", sequence: 0, state: .generating,
                snapshot: snapshot, attemptID: UUID()
            ),
            SchedulerRecord(
                uid: "buyer", sequence: 1, state: .queued,
                snapshot: snapshot, reply: reply
            )
        ]
        initial.nextSequence = 2
        try store.save(initial)
        let storage = SchedulerStorage(store: store)

        let repaired = try await storage.commit(
            date: Date(timeIntervalSince1970: 2_000),
            message: "simulated invoked send overlap",
            uid: "buyer"
        ) { state in
            state.records[1].state = .sending
            state.records[1].sendWasInvoked = true
        }

        XCTAssertEqual(repaired.records[0].state, .generating)
        XCTAssertEqual(repaired.records[1].state, .completed)
        XCTAssertEqual(repaired.records[1].deliveryOutcome, .uncertain)
        XCTAssertTrue(repaired.records[1].lastError?.contains("not automatically resent") == true)
    }
}
