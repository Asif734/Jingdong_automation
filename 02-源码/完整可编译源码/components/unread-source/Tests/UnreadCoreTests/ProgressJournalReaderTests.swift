import CryptoKit
import Foundation
import XCTest
@testable import UnreadCore

final class ProgressJournalReaderTests: XCTestCase {
    // Whole seconds avoid a fixture event at `since` rounding below it in ISO millisecond encoding.
    private let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 - 10))
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("progress-reader-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    // Catches trusting a hash filename as UID, and splitting one task across queue transitions.
    func testHashNamedQueuePointerUsesUIDAndStableTaskIdentity() throws {
        let id = identity("中文-buyer", "v1")
        try json("待处理/" + String(repeating: "a", count: 64) + ".json", ["uid": "中文-buyer", "history_version": "v1"])
        let reader = ProgressJournalReader(root: root, since: start)
        let pending = try XCTUnwrap(reader.read().tasks.first)
        XCTAssertEqual(pending.id, id)
        XCTAssertEqual(pending.uid, "中文-buyer")
        XCTAssertEqual(pending.stage, "待处理")
        try FileManager.default.removeItem(at: root.appendingPathComponent("待处理"))
        try json("处理中/\(id).json", ["uid": "中文-buyer", "history_version": "v1"])
        let snapshot = reader.read()
        XCTAssertEqual(snapshot.tasks.count, 1)
        XCTAssertEqual(snapshot.tasks.first?.stage, "处理中")
        XCTAssertEqual(snapshot.tasks.first?.events.map(\.title), ["待处理", "处理中"])
    }

    // Catches conflating reply availability/CLI exit with delivery, or cleanup regressing sent.
    func testEarlyReplyAndLateCLIExitDoNotClaimOrRegressDelivery() throws {
        let id = String(repeating: "b", count: 64)
        let path = try trace(id, uid: "buyer", rows: [row("process.started", 0), row("reply.ready", 1000)])
        let reader = ProgressJournalReader(root: root, since: start)
        var task = try XCTUnwrap(reader.read().tasks.first)
        XCTAssertFalse(task.isTerminal)
        XCTAssertTrue(task.cliActive)
        XCTAssertNotEqual(task.stage, "已发送")
        try json("已完成/buyer/\(id).json", ["task_id": id, "uid": "buyer", "send_status": "sent", "sent_at": stamp(2)])
        task = try XCTUnwrap(reader.read().tasks.first)
        XCTAssertEqual(task.stage, "已发送")
        XCTAssertTrue(task.isTerminal)
        XCTAssertTrue(task.cliActive)
        try append(path, row("process.completed", 3000))
        let snapshot = reader.read()
        XCTAssertEqual(snapshot.tasks.first?.stage, "已发送")
        XCTAssertEqual(snapshot.activeCLICount, 0)
        XCTAssertFalse(try XCTUnwrap(snapshot.tasks.first).cliActive)
    }

    func testCLIExitAloneRemainsUnconfirmedAndFailureCannotBeOverridden() throws {
        let id = String(repeating: "c", count: 64)
        let path = try trace(id, uid: "buyer", rows: [row("process.started", 0), row("process.completed", 1000)])
        let reader = ProgressJournalReader(root: root, since: start)
        XCTAssertFalse(try XCTUnwrap(reader.read().tasks.first).isTerminal)
        try json("发送失败/\(id).json", ["task_id": id, "uid": "buyer", "send_status": "failed_before_send", "failed_at": stamp(2)])
        _ = reader.read()
        try append(path, row("reply.ready", 3000))
        XCTAssertEqual(reader.read().tasks.first?.stage, "发送失败")
    }

    // Catches leaking raw tool strings, command/prompt/reasoning/reply text into the panel.
    func testCLIShowsOnlyAllowlistedMetadataAndTiming() throws {
        let id = String(repeating: "d", count: 64)
        var event = row("item.completed", 2500)
        event.merge(["item_type": "command_execution", "programs": ["rg", "secret-command"], "delta_ms": 1500,
                     "tool_duration_ms": 1200, "command": "TOP_SECRET", "prompt": "TOP_SECRET", "reasoning": "TOP_SECRET",
                     "response": "TOP_SECRET", "interval_category": "tool_active"], uniquingKeysWith: { _, new in new })
        _ = try trace(id, uid: "buyer", rows: [row("process.started", 0), event])
        let task = try XCTUnwrap(ProgressJournalReader(root: root, since: start).read().tasks.first)
        let display = task.events.map { $0.title + $0.detail }.joined()
        XCTAssertTrue(display.contains("rg"))
        XCTAssertTrue(display.contains("2.500"))
        XCTAssertTrue(display.contains("1.500"))
        XCTAssertTrue(display.contains("1.200"))
        XCTAssertFalse(display.contains("secret"))
        XCTAssertFalse(display.contains("TOP_SECRET"))
        XCTAssertEqual(try XCTUnwrap(task.events.last).date.timeIntervalSince(start), 2.5, accuracy: 0.002)
    }

    // Catches parsing partial UTF-8/JSON prematurely, duplicating polls, and missing rotations.
    func testPartialUTF8DedupTruncationAndReplacement() throws {
        let id = String(repeating: "e", count: 64)
        let path = try trace(id, uid: "buyer", rows: [row("process.started", 0)])
        let reader = ProgressJournalReader(root: root, since: start)
        XCTAssertEqual(reader.read().tasks.first?.events.count, 1)
        var event = row("item.started", 1000)
        event["item_type"] = "reasoning"
        event["ignored"] = "中"
        var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        let split = try XCTUnwrap(data.range(of: Data("中".utf8))).lowerBound + 1
        try appendData(path, data.prefix(split))
        XCTAssertEqual(reader.read().tasks.first?.events.count, 1)
        try appendData(path, data.suffix(from: split))
        XCTAssertEqual(reader.read().tasks.first?.events.count, 2)
        XCTAssertEqual(reader.read().tasks.first?.events.count, 2)
        try Data().write(to: root.appendingPathComponent(path))
        _ = reader.read()
        try append(path, row("turn.completed", 2000))
        XCTAssertEqual(reader.read().tasks.first?.events.count, 3)
        let replacement = try line(row("process.completed", 3000))
        try replacement.write(to: root.appendingPathComponent(path), options: .atomic)
        XCTAssertEqual(reader.read().tasks.first?.events.count, 4)
        try replacement.write(to: root.appendingPathComponent(path), options: .atomic)
        XCTAssertEqual(reader.read().tasks.first?.events.count, 4)
    }

    func testOldTerminalAndOldMalformedLogsAreExcludedButActiveQueueSurvives() throws {
        let old = stamp(-3600)
        try json("已完成/old/old.json", ["task_id": "old", "uid": "old", "send_status": "sent", "sent_at": old])
        let bad = "运行状态/CLI明细/" + String(repeating: "f", count: 64) + "-old.jsonl"
        try write(bad, Data("garbage\n".utf8))
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-3600)], ofItemAtPath: root.appendingPathComponent(bad).path)
        try json("处理中/live.json", ["task_id": "live", "uid": "live", "queued_at": old])
        let snapshot = ProgressJournalReader(root: root, since: start).read()
        XCTAssertEqual(snapshot.tasks.map(\.uid), ["live"])
        XCTAssertFalse(snapshot.warnings.contains { $0.contains("解析") })
    }

    func testMalformedAndMissingLogsNeverMeanCompletionAndDoNotWrite() throws {
        let id = String(repeating: "1", count: 64)
        let path = try trace(id, uid: "buyer", rows: [row("process.started", 0)])
        try appendData(path, Data("not json\n".utf8))
        let reader = ProgressJournalReader(root: root, since: start)
        var snapshot = reader.read()
        XCTAssertFalse(snapshot.warnings.isEmpty)
        XCTAssertFalse(try XCTUnwrap(snapshot.tasks.first).isTerminal)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        snapshot = reader.read()
        XCTAssertFalse(snapshot.warnings.isEmpty)
        XCTAssertFalse(try XCTUnwrap(snapshot.tasks.first).isTerminal)
        let absent = root.appendingPathComponent("does-not-exist")
        XCTAssertFalse(ProgressJournalReader(root: absent, since: start).read().warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testTimingAndSendAttemptAreObservedWithoutInventingDelivery() throws {
        let id = String(repeating: "2", count: 64)
        try json("发送中/\(id).json", ["task_id": id, "uid": "buyer", "created_at": stamp(1)])
        try json("运行状态/发送尝试/\(id).json", ["uid": "buyer", "phase": "immediately_before_send_action", "marked_at": stamp(2), "text": "PRIVATE_REPLY"])
        try write("运行状态/耗时日志.jsonl", line(["task_id": id, "uid": "buyer", "created_at": stamp(1), "queue_wait_ms": 200, "prompt_load_ms": 100, "login_check_ms": 300, "codex_exec_ms": 400, "decode_ms": 2, "publish_ms": 3, "task_processing_ms": 805]))
        let snapshot = ProgressJournalReader(root: root, since: start).read()
        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertEqual(task.stage, "发送中")
        XCTAssertFalse(task.isTerminal)
        XCTAssertTrue(task.events.contains { $0.title.contains("发送动作前") })
        XCTAssertTrue(task.events.contains { $0.title.contains("提示词读取") && $0.detail.contains("0.100") })
        XCTAssertTrue(task.events.contains { $0.title.contains("登录检查") })
    }

    func testNoActionAndUncertainAreNotSent() throws {
        try json("已完成/quiet/q.json", ["task_id": "q", "uid": "quiet", "decision": "no_action", "created_at": stamp(1)])
        try json("待人工确认/u.json", ["task_id": "u", "uid": "unsure", "send_status": "uncertain_after_send", "attempted_at": stamp(1)])
        let tasks = ProgressJournalReader(root: root, since: start).read().tasks
        XCTAssertEqual(tasks.count, 2)
        XCTAssertTrue(tasks.allSatisfy(\.isTerminal))
        XCTAssertFalse(tasks.contains { $0.stage == "已发送" })
        XCTAssertTrue(tasks.contains { $0.stage.contains("不需回复") })
        XCTAssertTrue(tasks.contains { $0.stage.contains("待人工确认") })
    }

    func testRetentionBoundsPreserveFiveActiveTasksAndRecentEvents() throws {
        for index in 0..<35 {
            try json("已完成/user\(index)/task\(index).json", ["task_id": "task\(index)", "uid": "user\(index)", "send_status": "sent", "sent_at": stamp(Double(index))])
        }
        for index in 0..<5 {
            try json("处理中/active\(index).json", ["task_id": "active\(index)", "uid": "active\(index)"])
        }
        let id = String(repeating: "3", count: 64)
        _ = try trace(id, uid: "cli", rows: (0..<260).map { row($0 == 0 ? "process.started" : "turn.started", Double($0)) })
        let reader = ProgressJournalReader(root: root, since: start)
        let snapshot = reader.read()
        XCTAssertLessThanOrEqual(snapshot.tasks.count, 20)
        XCTAssertEqual(snapshot.tasks.filter { $0.uid.hasPrefix("active") }.count, 5)
        XCTAssertLessThanOrEqual(try XCTUnwrap(snapshot.tasks.first { $0.uid == "cli" }).events.count, 200)
        XCTAssertEqual(reader.read().tasks.count, snapshot.tasks.count)
    }

    // Catches replaying terminal history when only the filesystem mtime is recent.
    func testTouchedOldCLILogDoesNotCreateAnEmptyActiveTask() throws {
        let id = String(repeating: "4", count: 64)
        _ = try trace(id, uid: "old", rows: [row("process.started", -100000), row("process.completed", -90000)])
        let snapshot = ProgressJournalReader(root: root, since: start).read()
        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertEqual(snapshot.activeCLICount, 0)
    }

    // Catches retaining a previous process-completed bit after a new invocation replaces a log.
    func testReplacementWithNewProcessStartReactivatesCLI() throws {
        let id = String(repeating: "5", count: 64)
        let path = try trace(id, uid: "buyer", rows: [row("process.started", 0), row("process.completed", 1000)])
        let reader = ProgressJournalReader(root: root, since: start)
        XCTAssertEqual(reader.read().activeCLICount, 0)
        try line(row("process.started", 2000)).write(to: root.appendingPathComponent(path), options: .atomic)
        XCTAssertEqual(reader.read().activeCLICount, 1)
    }

    // Catches suppressing uncertainty when an in-progress queue record has no CLI diagnostics.
    func testProcessingWithoutAnyCLILogWarnsButDoesNotInventCompletion() throws {
        try json("处理中/task.json", ["task_id": "task", "uid": "buyer"])
        let snapshot = ProgressJournalReader(root: root, since: start).read()
        XCTAssertFalse(snapshot.warnings.isEmpty)
        XCTAssertFalse(try XCTUnwrap(snapshot.tasks.first).isTerminal)
    }

    // Catches retaining unbounded pending data, or failing to resume after a discarded line.
    func testOversizeLineIsDiscardedAndNextValidLineIsRead() throws {
        let id = String(repeating: "6", count: 64)
        let path = try trace(id, uid: "buyer", rows: [row("process.started", 0)])
        let reader = ProgressJournalReader(root: root, since: start)
        _ = reader.read()
        try appendData(path, Data(repeating: 65, count: 150000))
        XCTAssertFalse(reader.read().warnings.isEmpty)
        try appendData(path, Data("\n".utf8))
        try append(path, row("process.completed", 1000))
        let snapshot = reader.read()
        XCTAssertEqual(snapshot.tasks.first?.events.count, 2)
        XCTAssertEqual(snapshot.activeCLICount, 0)
        XCTAssertFalse(snapshot.warnings.isEmpty)
    }

    func testExactPairedReportAndMultipleInvocationsCountIndividually() throws {
        let id = String(repeating: "7", count: 64)
        let first = try trace(id, uid: "first", rows: [row("process.started", 0)])
        let second = first.replacingOccurrences(of: "12345678-", with: "87654321-")
        try write(second, line(row("process.started", 1000)))
        try write(second.replacingOccurrences(of: ".jsonl", with: ".txt"), Data("UID：first\n".utf8))
        // An unrelated report must never supply the UID for a missing exact-stem report.
        try write("运行状态/CLI明细/other.txt", Data("UID：wrong\n".utf8))
        let reader = ProgressJournalReader(root: root, since: start)
        XCTAssertEqual(reader.read().activeCLICount, 2)
        try append(first, row("process.completed", 2000))
        let snapshot = reader.read()
        XCTAssertEqual(snapshot.activeCLICount, 1)
        XCTAssertEqual(snapshot.tasks.first?.uid, "first")
        XCTAssertTrue(try XCTUnwrap(snapshot.tasks.first).cliActive)
    }

    func testLateCLIEventDoesNotPreventNewerTerminalSenderCorrection() throws {
        let id = String(repeating: "8", count: 64)
        let path = try trace(id, uid: "buyer", rows: [row("process.started", 0)])
        try json("待人工确认/\(id).json", ["task_id": id, "uid": "buyer", "attempted_at": stamp(1), "send_status": "uncertain_after_send"])
        let reader = ProgressJournalReader(root: root, since: start)
        _ = reader.read()
        try append(path, row("process.completed", 5000))
        _ = reader.read()
        try FileManager.default.removeItem(at: root.appendingPathComponent("待人工确认/\(id).json"))
        try json("已完成/buyer/\(id).json", ["task_id": id, "uid": "buyer", "sent_at": stamp(2), "send_status": "sent"])
        XCTAssertEqual(reader.read().tasks.first?.stage, "已发送")
    }

    func testLargeArchiveCannotStarveLiveCLIUpdatesAcrossPolls() throws {
        for index in 0..<650 {
            try json("已完成/user/\(index).json", ["task_id": "old\(index)", "uid": "user", "sent_at": stamp(-3600), "send_status": "sent", "reply_text": String(repeating: "x", count: 3500)])
        }
        try json("已完成/user/z-late.json", ["task_id": "late", "uid": "late", "sent_at": stamp(2), "send_status": "sent"])
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-3600)], ofItemAtPath: root.appendingPathComponent("已完成/user/z-late.json").path)
        let id = String(repeating: "9", count: 64)
        let path = try trace(id, uid: "live", rows: [row("process.started", 0)])
        let reader = ProgressJournalReader(root: root, since: start)
        var snapshot = reader.read()
        for _ in 0..<3 { snapshot = reader.read() }
        XCTAssertTrue(snapshot.tasks.contains { $0.uid == "live" })
        XCTAssertTrue(snapshot.tasks.contains { $0.uid == "late" && $0.stage == "已发送" })
        try append(path, row("reply.ready", 1000))
        snapshot = reader.read()
        XCTAssertTrue(snapshot.tasks.contains { $0.events.contains { $0.title.contains("回复已验证") } })
    }

    func testOldActiveCLIIsNotEvictedByManyNewerFinishedTraces() throws {
        let id = String(repeating: "a", count: 64)
        _ = try trace(id, uid: "active", rows: [row("process.started", 0)])
        for index in 0..<70 {
            let other = String(format: "%064x", index)
            _ = try trace(other, uid: "done\(index)", rows: [row("process.started", 1000), row("process.completed", Double(2000 + index))])
        }
        let snapshot = ProgressJournalReader(root: root, since: start).read()
        XCTAssertEqual(snapshot.activeCLICount, 1)
        XCTAssertTrue(snapshot.tasks.contains { $0.uid == "active" && $0.cliActive })
    }

    func testLargeTraceMissingStartWarnsThatActivityCountIsIncomplete() throws {
        let id = String(repeating: "b", count: 64)
        let path = try trace(id, uid: "buyer", rows: (0..<10000).map { row($0 == 0 ? "process.started" : "turn.started", Double($0)) })
        XCTAssertGreaterThan(try Data(contentsOf: root.appendingPathComponent(path)).count, 524288)
        let snapshot = ProgressJournalReader(root: root, since: start).read()
        XCTAssertTrue(snapshot.warnings.contains { $0.contains("活动数量") }, "warnings=\(snapshot.warnings); active=\(snapshot.activeCLICount); events=\(snapshot.tasks.first?.events.count ?? 0)")
    }

    private func identity(_ uid: String, _ version: String) -> String {
        SHA256.hash(data: Data("\(uid):\(version)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func stamp(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: start.addingTimeInterval(seconds))
    }
    private func row(_ event: String, _ ms: Double) -> [String: Any] {
        ["event": event, "at": stamp(ms / 1000), "elapsed_ms": ms]
    }
    @discardableResult private func trace(_ id: String, uid: String, rows: [[String: Any]]) throws -> String {
        let stem = "运行状态/CLI明细/\(id)-12345678-1234-1234-1234-123456789012"
        try write(stem + ".txt", Data("CLI 内部步骤耗时\nUID：\(uid)\n任务 ID：\(id)\n".utf8))
        var data = Data()
        for row in rows { data.append(try line(row)) }
        try write(stem + ".jsonl", data)
        return stem + ".jsonl"
    }
    private func json(_ path: String, _ object: [String: Any]) throws { try write(path, JSONSerialization.data(withJSONObject: object)) }
    private func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]); data.append(10); return data
    }
    private func write(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func append(_ path: String, _ row: [String: Any]) throws { try appendData(path, line(row)) }
    private func appendData(_ path: String, _ data: Data) throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(path))
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
}
