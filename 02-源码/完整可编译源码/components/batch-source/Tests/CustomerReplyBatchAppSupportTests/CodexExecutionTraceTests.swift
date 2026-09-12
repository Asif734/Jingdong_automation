import XCTest
@testable import CustomerReplyBatchAppSupport

final class CodexExecutionTraceTests: XCTestCase {
    private func makeTrace() throws -> CodexExecutionTrace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return CodexExecutionTrace(directory: root, input: PromptInput(
            uid: "u1", historyVersion: "v1", historyJSONL: "", historyText: "", imagePaths: [],
            knowledgeBasePaths: ["/safe/KB.zip"]
        ), startedAt: Date(timeIntervalSince1970: 0))
    }

    // Catches attributing all gaps to model thinking, or double-counting parallel tools.
    func testPartitionsElapsedTimeAndMatchesOverlappingTools() throws {
        let trace = try makeTrace()
        trace.consume(Data("{\"type\":\"thread.started\"}\n".utf8), elapsed: 100)
        trace.consume(Data("{\"type\":\"turn.started\"}\n".utf8), elapsed: 200)
        trace.consume(Data("{\"type\":\"item.started\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"unzip -l /safe/KB.zip\"}}\n".utf8), elapsed: 1_000)
        trace.consume(Data("{\"type\":\"item.started\",\"item\":{\"id\":\"item_2\",\"type\":\"command_execution\"}}\n".utf8), elapsed: 1_100)
        trace.consume(Data("{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"exit_code\":0}}\n".utf8), elapsed: 1_300)
        trace.consume(Data("{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"command_execution\",\"exit_code\":0}}\n".utf8), elapsed: 1_500)
        trace.consume(Data("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":30,\"cached_input_tokens\":10,\"output_tokens\":5}}\n".utf8), elapsed: 2_000)
        trace.finish(elapsed: 2_100, exitCode: 0)

        let events = try rows(trace)
        let summary = try XCTUnwrap(events.last)
        XCTAssertEqual(summary["startup_ms"] as? Double, 100)
        XCTAssertEqual(summary["tool_active_ms"] as? Double, 500)
        XCTAssertEqual(summary["waiting_ms"] as? Double, 1_400)
        XCTAssertEqual(summary["shutdown_ms"] as? Double, 100)
        XCTAssertEqual(summary["elapsed_ms"] as? Double, 2_100)
        XCTAssertEqual(events.compactMap { $0["tool_duration_ms"] as? Double }, [300, 400])
        let text = try String(contentsOf: XCTUnwrap(trace.reportURL))
        XCTAssertTrue(text.contains("知识库"))
        XCTAssertTrue(text.contains("不能区分"))
        XCTAssertTrue(text.contains("缓存命中 10"))
    }

    // Catches dropped split UTF-8/JSON lines and accidentally retaining secrets or reasoning text.
    func testSplitStreamMalformedLineAndPrivacy() throws {
        let trace = try makeTrace()
        let event = Data("{\"type\":\"item.completed\",\"item\":{\"id\":\"item_9\",\"type\":\"command_execution\",\"command\":\"echo secret-password\",\"aggregated_output\":\"secret-password 客户私密信息\",\"exit_code\":1}}\n".utf8)
        trace.consume(event.prefix(35), elapsed: 10)
        trace.consume(event.dropFirst(35), elapsed: 20)
        trace.consume(Data("not-json secret-password\n{\"type\":\"item.completed\",\"item\":{\"id\":\"item_10\",\"type\":\"reasoning\",\"text\":\"secret-password\"}}".utf8), elapsed: 30)
        trace.finish(elapsed: 40, exitCode: 1)
        let events = try rows(trace)
        XCTAssertEqual(events.filter { ($0["event"] as? String) == "item.completed" }.count, 2)
        XCTAssertNil(events.first { ($0["item_id"] as? String) == "item_9" }?["tool_duration_ms"])
        let jsonl = try String(contentsOf: XCTUnwrap(trace.eventsURL))
        let txt = try String(contentsOf: XCTUnwrap(trace.reportURL))
        XCTAssertFalse((jsonl + txt).contains("secret-password"))
        XCTAssertFalse((jsonl + txt).contains("客户私密信息"))
        XCTAssertEqual(events.last?["invalid_lines"] as? Int, 1)
        XCTAssertEqual(events.last?["exit_code"] as? Int, 1)
    }

    func testConcurrentTasksHaveSeparateFilesAndLiveTextBeforeFinish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let input = PromptInput(uid: "../same", historyVersion: "same", historyJSONL: "", historyText: "", imagePaths: [])
        let first = CodexExecutionTrace(directory: root, input: input)
        let second = CodexExecutionTrace(directory: root, input: input)
        XCTAssertNotEqual(first.reportURL, second.reportURL)
        XCTAssertEqual(first.reportURL?.deletingLastPathComponent().path, root.path)
        first.consume(Data("{\"type\":\"turn.started\"}\n".utf8), elapsed: 100)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(first.reportURL)).contains("开始处理"))
        first.finish(elapsed: 200, exitCode: 1)
        second.finish(elapsed: 100, exitCode: 0)
    }

    func testUnwritableLogDirectoryDoesNotBreakProcessing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let trace = CodexExecutionTrace(directory: root, input: PromptInput(uid: "u", historyVersion: "v", historyJSONL: "", historyText: "", imagePaths: []))
        trace.consume(Data("{\"type\":\"turn.started\"}\n".utf8), elapsed: 1)
        trace.finish(elapsed: 2, exitCode: 0)
        XCTAssertNil(trace.reportURL)
    }

    private func rows(_ trace: CodexExecutionTrace) throws -> [[String: Any]] {
        try String(contentsOf: XCTUnwrap(trace.eventsURL)).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
