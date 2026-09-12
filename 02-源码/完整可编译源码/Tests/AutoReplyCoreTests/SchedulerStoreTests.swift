import XCTest
@testable import AutoReplyCore
import CustomerReplyBatchCore
import CryptoKit

@MainActor final class SchedulerStoreTests: XCTestCase {
    private enum OptionalWriteFailure: Error { case denied }

    func testReadableReplyFailureDoesNotRejectAuthoritativeCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("optional-reply-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root, readableReplyWriter: { _, _ in
            throw OptionalWriteFailure.denied
        })
        let terminal = SchedulerRecord(
            uid: "buyer", sequence: 0, state: .completed,
            snapshot: CaptureSnapshot(uid: "buyer", customerRevision: "revision", historyJSONL: "question",
                                      hasUnansweredCustomer: true, shouldGenerate: true),
            reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "answer", reason: "fixture"),
            deliveryOutcome: .sent
        )

        XCTAssertNoThrow(try store.save(SchedulerPersistentState(nextSequence: 1, records: [terminal])))
        XCTAssertEqual(try store.load().records.first?.state, .completed)
        XCTAssertNotNil(try store.load().records.first?.archiveReference)
        XCTAssertEqual(store.optionalWarnings.count, 1)
    }

    func testSchemaThreePersistsAnsweredCursorAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-restart-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cursor = CustomerCursor(count: 2, digest: String(repeating: "a", count: 64))
        let store = try SchedulerStore(rootURL: root)
        var state = try store.load()
        state.answeredCursors["buyer"] = cursor
        try store.save(state)

        let reopened = try SchedulerStore(rootURL: root)

        XCTAssertEqual(try reopened.load().schemaVersion, 5)
        XCTAssertEqual(try reopened.load().answeredCursors["buyer"], cursor)
    }

    func testSchemaThreeRejectsMalformedAndBackwardAnsweredCursor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        var state = try store.load()
        state.answeredCursors["buyer"] = CustomerCursor(count: 2, digest: String(repeating: "a", count: 64))
        try store.save(state)

        var backward = try store.load()
        backward.answeredCursors["buyer"] = CustomerCursor(count: 1, digest: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try store.save(backward))

        var malformed = try store.load()
        malformed.answeredCursors["other"] = CustomerCursor(count: -1, digest: "NOT-A-DIGEST")
        XCTAssertThrowsError(try store.save(malformed))
    }

    func testSchemaTwoMigrationRecoversLatestVerifiedSentEndCursor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let end = CustomerCursor(count: 3, digest: String(repeating: "c", count: 64))
        let store = try SchedulerStore(rootURL: root)
        let sent = SchedulerRecord(
            uid: "buyer",
            sequence: 0,
            state: .completed,
            snapshot: CaptureSnapshot(
                uid: "buyer",
                customerRevision: end.digest,
                historyJSONL: "history",
                hasUnansweredCustomer: true,
                shouldGenerate: true,
                targetCustomerJSONL: "target",
                startCursor: .empty,
                endCursor: end
            ),
            reply: ReplyEnvelope(
                decision: .autoSend,
                riskLevel: .low,
                replyText: "answer",
                reason: "fixture"
            ),
            deliveryOutcome: .sent
        )
        try store.save(SchedulerPersistentState(nextSequence: 1, records: [sent]))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any]
        )
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        let reference = try XCTUnwrap(records.first?["archiveReference"] as? [String: Any])
        let relativePath = try XCTUnwrap(reference["relativePath"] as? String)
        var legacyRecord = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent(relativePath))
            ) as? [String: Any]
        )
        var legacySnapshot = try XCTUnwrap(legacyRecord["snapshot"] as? [String: Any])
        legacySnapshot.removeValue(forKey: "startCursor")
        legacySnapshot.removeValue(forKey: "endCursor")
        legacySnapshot.removeValue(forKey: "targetCustomerJSONL")
        legacyRecord["snapshot"] = legacySnapshot
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyRecord,
            options: [.prettyPrinted, .sortedKeys]
        )
        let digest = SHA256.hash(data: legacyData).map { String(format: "%02x", $0) }.joined()
        let recordID = try XCTUnwrap(legacyRecord["id"] as? String)
        let legacyRelativePath = "archive/records/\(recordID)-\(digest).json"
        try legacyData.write(to: root.appendingPathComponent(legacyRelativePath), options: .atomic)
        var summary = try XCTUnwrap(records.first)
        summary["archiveReference"] = [
            "relativePath": legacyRelativePath,
            "sha256": digest,
            "byteCount": legacyData.count,
        ]
        object["records"] = [summary]
        object["schemaVersion"] = 2
        object.removeValue(forKey: "answeredCursors")
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL, options: .atomic)

        let migrated = try SchedulerStore(
            rootURL: root,
            legacySnapshotCursorResolver: { uid, history in
                XCTAssertEqual(uid, "buyer")
                XCTAssertEqual(history, "history")
                return end
            }
        )

        XCTAssertEqual(try migrated.load().schemaVersion, 5)
        XCTAssertEqual(try migrated.load().answeredCursors["buyer"], end)
    }

    func testSchemaTwoActiveReadyTaskIsRecapturedFromConservativeBaseline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-active-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        let legacySnapshot = CaptureSnapshot(
            uid: "buyer", customerRevision: "legacy", historyJSONL: "A\n",
            hasUnansweredCustomer: true, shouldGenerate: true
        )
        let ready = SchedulerRecord(
            uid: "buyer", sequence: 0, state: .ready, snapshot: legacySnapshot,
            reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "old draft", reason: "fixture")
        )
        try store.save(SchedulerPersistentState(nextSequence: 1, records: [ready]))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any]
        )
        object["schemaVersion"] = 2
        object.removeValue(forKey: "answeredCursors")
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL, options: .atomic)
        let baseline = CustomerCursor(count: 4, digest: String(repeating: "d", count: 64))

        let migrated = try SchedulerStore(rootURL: root) { uid in
            XCTAssertEqual(uid, "buyer")
            return baseline
        }
        let record = try XCTUnwrap(try migrated.load().records.first)

        XCTAssertEqual(try migrated.load().answeredCursors["buyer"], baseline)
        XCTAssertEqual(record.state, .discovered)
        XCTAssertNil(record.snapshot)
        XCTAssertNil(record.reply)
    }

    func testSchemaTwoSendingAndUncertainTasksRemainQuarantinedDuringMigration() throws {
        for originalState in [SchedulerJobState.sending, .uncertain] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cursor-quarantine-migration-\(originalState.rawValue)-\(UUID())"
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try SchedulerStore(rootURL: root)
            let snapshot = CaptureSnapshot(
                uid: "buyer", customerRevision: "legacy", historyJSONL: "A\n",
                hasUnansweredCustomer: true, shouldGenerate: true
            )
            let record = SchedulerRecord(
                uid: "buyer", sequence: 0, state: originalState, snapshot: snapshot,
                reply: ReplyEnvelope(
                    decision: .autoSend, riskLevel: .low,
                    replyText: "possibly delivered", reason: "fixture"
                ),
                lastError: originalState == .uncertain ? "old uncertainty" : nil,
                deliveryOutcome: originalState == .uncertain ? .uncertain : nil
            )
            try store.save(SchedulerPersistentState(nextSequence: 1, records: [record]))
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any]
            )
            object["schemaVersion"] = 2
            object.removeValue(forKey: "answeredCursors")
            try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL, options: .atomic)

            let migrated = try SchedulerStore(rootURL: root) { _ in .empty }
            let restored = try XCTUnwrap(try migrated.load().records.first)

            XCTAssertEqual(restored.state, .uncertain)
            XCTAssertEqual(restored.deliveryOutcome, .uncertain)
            XCTAssertEqual(restored.reply?.replyText, "possibly delivered")
            XCTAssertNotNil(restored.snapshot)
            XCTAssertEqual(try migrated.load().answeredCursors["buyer"], .empty)
        }
    }

    func testSchemaTwoMigrationBaselinesIdleUIDFromCurrentHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-idle-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        let completed = SchedulerRecord(uid: "idle-buyer", sequence: 0, state: .completed)
        try store.save(SchedulerPersistentState(nextSequence: 1, records: [completed]))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any]
        )
        object["schemaVersion"] = 2
        object.removeValue(forKey: "answeredCursors")
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL, options: .atomic)
        let current = CustomerCursor(count: 4, digest: String(repeating: "d", count: 64))

        let migrated = try SchedulerStore(rootURL: root) { uid in
            XCTAssertEqual(uid, "idle-buyer")
            return current
        }

        XCTAssertEqual(try migrated.load().answeredCursors["idle-buyer"], current)
    }

    func testSchemaTwoMigrationRequeuesIdleUIDWithDurablePendingPointer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-pending-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        try store.save(SchedulerPersistentState(
            nextSequence: 1,
            records: [SchedulerRecord(uid: "pending-buyer", sequence: 0, state: .completed)]
        ))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.stateURL)) as? [String: Any]
        )
        object["schemaVersion"] = 2
        object.removeValue(forKey: "answeredCursors")
        try JSONSerialization.data(withJSONObject: object).write(to: store.stateURL, options: .atomic)

        let migrated = try SchedulerStore(
            rootURL: root,
            idleCursorResolver: { _ in .empty },
            legacyPendingResolver: { $0 == "pending-buyer" }
        )

        XCTAssertEqual(
            try migrated.load().records.filter { !$0.state.isTerminal }.map(\.uid),
            ["pending-buyer"]
        )
    }

    func testCaptureSnapshotRoundTripsFrozenCustomerCursorBoundaries() throws {
        let start = CustomerCursor.empty
        let end = CustomerCursor(count: 2, digest: String(repeating: "a", count: 64))
        let snapshot = CaptureSnapshot(
            uid: "buyer",
            customerRevision: end.digest,
            historyJSONL: "full-history\n",
            hasUnansweredCustomer: true,
            shouldGenerate: true,
            targetCustomerJSONL: "{\"sender\":\"customer\",\"v\":\"B\"}\n",
            startCursor: start,
            endCursor: end
        )

        let decoded = try JSONDecoder().decode(
            CaptureSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded.startCursor, start)
        XCTAssertEqual(decoded.endCursor, end)
        XCTAssertEqual(decoded.targetCustomerJSONL, snapshot.targetCustomerJSONL)
    }

    func testSchemaTwoCheckpointFromBeforeSupplementFieldsStillDecodes() throws {
        let record = SchedulerRecord(uid: "legacy-buyer", sequence: 0, state: .discovered)
        let encoded = try JSONEncoder().encode(SchedulerPersistentState(nextSequence: 1, records: [record]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "pendingSupplement")
        records[0].removeValue(forKey: "supplementCapturePending")
        object["records"] = records

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SchedulerPersistentState.self, from: legacyData)

        XCTAssertNil(decoded.records.first?.pendingSupplement)
        XCTAssertNil(decoded.records.first?.supplementCapturePending)
    }

    private func seed(historyBytes: Int) throws -> (SchedulerStore, [SchedulerRecord]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-test-\(UUID())")
        let store = try SchedulerStore(rootURL: root)
        let jobs = (0..<8).map { index in
            SchedulerRecord(uid: "archive-\(index)", sequence: index, state: .completed,
                snapshot: CaptureSnapshot(uid: "archive-\(index)", customerRevision: "revision-\(index)",
                    historyJSONL: String(repeating: "x", count: historyBytes), imagePaths: ["/frozen/image.png"],
                    knowledgeBasePaths: ["/kb.zip"], hasUnansweredCustomer: true, shouldGenerate: true),
                reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "archived answer \(index)", reason: "complete"),
                createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000))
        }
        let events = (0..<2_000).map { SchedulerEvent(date: Date(timeIntervalSince1970: 1_000), uid: nil, message: "e\($0) " + String(repeating: "z", count: 256)) }
        try store.save(SchedulerPersistentState(nextSequence: 8, records: jobs, events: events))
        return (store, jobs)
    }

    // Removing archive separation makes checkpoint bytes and idle/transition latency scale with 32 MiB of histories.
    func testLargeArchiveKeepsIdlePollingAndOneTransitionIndependentOfPayloadSize() async throws {
        let (small, smallJobs) = try seed(historyBytes: 128)
        let (large, largeJobs) = try seed(historyBytes: 4 * 1_024 * 1_024)
        defer {
            try? FileManager.default.removeItem(at: small.rootURL)
            try? FileManager.default.removeItem(at: large.rootURL)
        }
        let smallBytes = try Data(contentsOf: small.stateURL).count
        let largeBytes = try Data(contentsOf: large.stateURL).count
        XCTAssertLessThan(largeBytes, 100_000)
        XCTAssertLessThan(abs(largeBytes - smallBytes), 1_024)
        XCTAssertEqual(try large.load().events.count, 100)
        XCTAssertTrue(try large.load().records.first?.snapshot == nil)
        XCTAssertEqual(try large.load().records.first?.customerRevision, "revision-0")
        XCTAssertTrue(try large.archivedRecord(id: largeJobs[0].id) == largeJobs[0])

        func idleTime(_ store: SchedulerStore) throws -> TimeInterval {
            let start = Date()
            for _ in 0..<50 { _ = try store.load() }
            return Date().timeIntervalSince(start)
        }
        let smallIdle = try idleTime(small)
        let largeIdle = try idleTime(large)
        XCTAssertLessThan(largeIdle, max(0.10, smallIdle * 10))
        func transitionTime(_ store: SchedulerStore) throws -> TimeInterval {
            var state = try store.load()
            state.records.append(SchedulerRecord(uid: "new-active", sequence: 8, state: .discovered))
            state.nextSequence = 9
            state.events.append(SchedulerEvent(date: Date(), uid: "new-active", message: "new discovery"))
            let start = Date(); try store.save(state); return Date().timeIntervalSince(start)
        }
        let smallTransition = try transitionTime(small)
        let largeTransition = try transitionTime(large)
        XCTAssertLessThan(largeTransition, max(0.10, smallTransition * 10))
        XCTAssertLessThan(try Data(contentsOf: large.stateURL).count, 100_000)
        XCTAssertTrue(try large.archivedRecord(id: largeJobs[0].id) == largeJobs[0])
        XCTAssertTrue(try small.archivedRecord(id: smallJobs[0].id) == smallJobs[0])
        print("Archive scaling evidence: small checkpoint=\(smallBytes)B, 32MiB archive checkpoint=\(largeBytes)B; 50 idle loads=\(smallIdle)s/\(largeIdle)s; transition=\(smallTransition)s/\(largeTransition)s")
    }

    func testArchivedEvidenceAndEventsSurviveRestartAndCoalescedSummaryUpdates() async throws {
        let (store, jobs) = try seed(historyBytes: 128)
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        var checkpoint = try store.load()
        let originalReference = checkpoint.records[0].archiveReference
        checkpoint.records[0].updatedAt += 10
        checkpoint.records[0].nextAttemptAt += 10
        checkpoint.events.append(SchedulerEvent(date: Date(), uid: jobs[0].uid, message: "Observation unchanged"))
        try store.save(checkpoint)
        let reopened = try SchedulerStore(rootURL: store.rootURL)
        XCTAssertEqual(try reopened.load().records[0].archiveReference, originalReference)
        XCTAssertEqual(try reopened.archivedRecord(id: jobs[0].id), jobs[0])
        XCTAssertEqual(try reopened.archivedEvents().count, 2_001)
        XCTAssertEqual(try reopened.archivedEvents().last?.message, "Observation unchanged")
    }

    func testChangedCheckpointAndCorruptArchiveAreRefusedWithoutDiscardingEvidence() async throws {
        let (store, jobs) = try seed(historyBytes: 128)
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        let reference = try XCTUnwrap(try store.load().records[0].archiveReference)
        let archiveURL = store.rootURL.appendingPathComponent(reference.relativePath)
        try Data("corrupt archive".utf8).write(to: archiveURL)
        XCTAssertThrowsError(try store.archivedRecord(id: jobs[0].id))
        // A changed checkpoint must never overwrite previously persisted data using a stale cache.
        let checkpoint = try store.load()
        try Data("corrupt checkpoint".utf8).write(to: store.stateURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(checkpoint))
        XCTAssertThrowsError(try SchedulerStore(rootURL: store.rootURL))
        XCTAssertEqual(try String(contentsOf: archiveURL), "corrupt archive")
    }

    // Removing the terminal readable sidecar would leave operators with only JSON
    // evidence and no safe, non-actionable record of the generated answer.
    func testTerminalGeneratedReplyWritesReadableSidecarWithSafeDeliveryOutcome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("readable-reply-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        let sent = SchedulerRecord(uid: "buyer-sent", sequence: 0, state: .completed,
            snapshot: CaptureSnapshot(uid: "buyer-sent", customerRevision: "rev-sent", historyJSONL: "question",
                hasUnansweredCustomer: true, shouldGenerate: true),
            reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "已为您登记", reason: "fixture"),
            deliveryOutcome: .sent)
        let superseded = SchedulerRecord(uid: "buyer-new-message", sequence: 1, state: .superseded,
            snapshot: CaptureSnapshot(uid: "buyer-new-message", customerRevision: "rev-new", historyJSONL: "question",
                hasUnansweredCustomer: true, shouldGenerate: true),
            reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "旧回复", reason: "fixture"),
            deliveryOutcome: .notSent)

        try store.save(SchedulerPersistentState(nextSequence: 2, records: [sent, superseded]))

        let sentText = try String(contentsOf: root.appendingPathComponent("archive/replies/\(sent.id.uuidString).txt"), encoding: .utf8)
        let supersededText = try String(contentsOf: root.appendingPathComponent("archive/replies/\(superseded.id.uuidString).txt"), encoding: .utf8)
        XCTAssertTrue(sentText.contains("任务 ID: \(sent.id.uuidString)"))
        XCTAssertTrue(sentText.contains("客户 UID: buyer-sent"))
        XCTAssertTrue(sentText.contains("终态: completed"))
        XCTAssertTrue(sentText.contains("回复内容:\n已为您登记"))
        XCTAssertTrue(sentText.contains("发送结果: 已确认发送"))
        XCTAssertTrue(supersededText.contains("终态: superseded"))
        XCTAssertTrue(supersededText.contains("发送结果: 未发送"))
        XCTAssertFalse(supersededText.contains("已确认发送"))
    }

    // A stale or externally corrupted terminal record must not make a
    // superseded answer look like a confirmed delivery in its text sidecar.
    func testSupersededRecordCannotClaimConfirmedDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-delivery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        let invalid = SchedulerRecord(uid: "buyer", sequence: 0, state: .superseded,
            snapshot: CaptureSnapshot(uid: "buyer", customerRevision: "revision", historyJSONL: "question",
                hasUnansweredCustomer: true, shouldGenerate: true),
            reply: ReplyEnvelope(decision: .autoSend, riskLevel: .low, replyText: "stale answer", reason: "fixture"),
            deliveryOutcome: .sent)

        XCTAssertThrowsError(try store.save(SchedulerPersistentState(nextSequence: 1, records: [invalid]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("delivery outcome"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("archive/replies/\(invalid.id.uuidString).txt").path))
    }

    func testParkedRecordIsTerminalAndArchivesFailureEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parked-record-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SchedulerStore(rootURL: root)
        let record = SchedulerRecord(
            uid: "buyer", sequence: 0, state: .parked,
            retries: 2, lastError: "open failed twice", parkedReason: "open failed twice"
        )

        try store.save(SchedulerPersistentState(nextSequence: 1, records: [record]))

        let summary = try XCTUnwrap(try store.load().records.first)
        XCTAssertTrue(summary.state.isTerminal)
        XCTAssertNotNil(summary.archiveReference)
        XCTAssertEqual(try store.archivedRecord(id: record.id)?.parkedReason, "open failed twice")
    }
}
