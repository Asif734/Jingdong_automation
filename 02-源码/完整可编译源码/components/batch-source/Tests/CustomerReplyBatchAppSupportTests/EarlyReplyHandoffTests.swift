import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport
import CustomerReplyBatchCore

final class EarlyReplyHandoffTests: XCTestCase {
    // Break caught: waiting for process exit even after a valid completed turn.
    func testValidCompletedTurnReturnsBeforeProcessExitAndOutputFile() async throws {
        let fixture = try makeFixture(events: completedEvents)
        let generated = try await fixture.generator.generate(for: input)
        XCTAssertEqual(generated.reply.replyText, "您好")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.exited.path), "完整答案应在 CLI 收尾前交接")
        await generated.cleanupTask?.value
        try await waitForExit(fixture.exited)
    }

    func testLateNonzeroExitDoesNotReplaceAcceptedReplyAndCleanupStillCompletes() async throws {
        let fixture = try makeFixture(events: completedEvents, exitCode: 7)
        let generated = try await fixture.generator.generate(for: input)
        XCTAssertEqual(generated.reply.replyText, "您好")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.exited.path))
        await generated.cleanupTask?.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.exited.path))
        let report = try String(contentsOfFile: XCTUnwrap(generated.timing.cliTraceReportPath))
        XCTAssertTrue(report.contains("退出码 7"))
    }

    func testDescendantHoldingStdoutDoesNotHoldCompletedCLISlot() async throws {
        let fixture = try makeFixture(events:completedEvents,tail:0.01,inheritedStdout:true)
        let generated = try await fixture.generator.generate(for:input)
        let done=expectation(description:"direct CLI exit releases cleanup despite inherited pipe")
        let cleanup=Task { await generated.cleanupTask?.value; done.fulfill() }
        await fulfillment(of:[done],timeout:0.8)
        await cleanup.value
    }

    func testSplitUTF8JSONLinesAndDuplicateTerminalEventDeliverOnlyOnce() throws {
        let stream = CLIReplyStream()
        let bytes = Data((completedEvents.joined(separator:"\n") + "\n" + completedEvents.last! + "\n").utf8)
        var replies: [String] = []
        for byte in bytes { stream.consume(Data([byte])) { replies.append($0.replyText) } }
        XCTAssertEqual(replies, ["您好"])
    }

    func testReplyThenTransferWaitsForCompletedTurnAndPreservesAction() throws {
        let stream = CLIReplyStream()
        let rows = [
            #"{"type":"thread.started","thread_id":"fixture"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{\"action\":\"reply_then_transfer\",\"reply_text\":\"好的亲，我这边为您转人工处理。\",\"transfer_reason\":\"customer_explicitly_requested_human\",\"reason\":\"客户明确要求人工\"}"}}"#
        ]
        var replies: [ReplyEnvelope] = []
        stream.consume(Data((rows.joined(separator: "\n") + "\n").utf8)) { replies.append($0) }
        XCTAssertTrue(replies.isEmpty)

        stream.consume(Data((#"{"type":"turn.completed"}"# + "\n").utf8)) { replies.append($0) }

        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.action, .replyThenTransfer)
        XCTAssertEqual(replies.first?.transferReason, .customerExplicitlyRequestedHuman)
    }

    func testInvalidSchemaCandidatesNeverEarlyHandoff() throws {
        let bodies: [[String:Any]] = [
            ["decision":"auto_send","risk_level":"low","reply_text":" ","reason":""],
            ["decision":"auto_send","risk_level":"low","reply_text":"您好"],
            ["decision":"auto_send","risk_level":"invalid","reply_text":"您好","reason":""],
            ["decision":"auto_send","risk_level":"low","reply_text":123,"reason":""],
            ["decision":"auto_send","risk_level":"low","reply_text":"您好","reason":"","extra":"x"],
            ["decision":"human_review","risk_level":"low","reply_text":"您好","reason":""]
        ]
        for body in bodies {
            let stream = CLIReplyStream()
            let text=String(data:try JSONSerialization.data(withJSONObject:body),encoding:.utf8)!
            let event=try JSONSerialization.data(withJSONObject:["type":"item.completed","item":["type":"agent_message","text":text]])
            var bytes=Data((completedEvents[0]+"\n"+completedEvents[1]+"\n").utf8)
            bytes.append(event); bytes.append(Data(("\n"+completedEvents.last!+"\n").utf8))
            var count=0
            stream.consume(bytes) { _ in count += 1 }
            XCTAssertEqual(count,0,"invalid schema must use reaped fallback")
        }
    }

    func testToolStillRunningOrCommentaryOrProtocolErrorPreventsEarlyHandoff() {
        for prefix in [
            #"{"type":"item.started","item":{"id":"tool_1","type":"command_execution"}}"#,
            #"{"type":"error","message":"transport retry"}"#,
            "not-json"
        ] {
            let stream=CLIReplyStream()
            let rows=[completedEvents[0],completedEvents[1],prefix,completedEvents[2],completedEvents[3]]
            var count=0
            stream.consume(Data((rows.joined(separator:"\n")+"\n").utf8)) { _ in count += 1 }
            XCTAssertEqual(count,0)
        }
        let stream=CLIReplyStream()
        let commentary=completedEvents[2].replacingOccurrences(of:"\"type\":\"agent_message\"",with:"\"type\":\"agent_message\",\"phase\":\"commentary\"")
        var count=0
        stream.consume(Data(([completedEvents[1],commentary,completedEvents[3]].joined(separator:"\n")+"\n").utf8)) { _ in count += 1 }
        XCTAssertEqual(count,0)
    }

    // Break caught: treating commentary/a candidate without turn.completed as final.
    func testCandidateWithoutCompletedTurnWaitsForNormalExitFallback() async throws {
        let fixture = try makeFixture(events: Array(completedEvents.dropLast()))
        let generated = try await fixture.generator.generate(for: input)
        XCTAssertEqual(generated.reply.replyText, "您好")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.exited.path))
    }

    // Break caught: trusting a stale result file after an explicit failed turn.
    func testFailedTurnNeverPublishesEvenIfOutputFileExistsAndExitIsZero() async throws {
        let fixture = try makeFixture(events: Array(completedEvents.dropLast()) + [#"{"type":"turn.failed","error":{"message":"fixture failure"}}"#], tail: 0.05)
        do {
            _ = try await fixture.generator.generate(for: input)
            XCTFail("turn.failed 不应成为可发送结果")
        } catch { }
        try await waitForExit(fixture.exited)
    }

    func testFailedTurnAtEOFEvenWithoutNewlineRejectsFallbackFile() async throws {
        let fixture = try makeFixture(events: Array(completedEvents.dropLast()) + [#"{"type":"turn.failed","error":{"message":"fixture failure"}}"#], tail:0.05, finalNewline:false)
        do {
            _ = try await fixture.generator.generate(for:input)
            XCTFail("EOF 的失败事件不能被遗漏")
        } catch { }
        try await waitForExit(fixture.exited)
    }

    // Break caught: advancing on incomplete/invalid JSON instead of retaining fallback.
    func testMalformedCandidateDoesNotReturnEarly() async throws {
        let fixture = try makeFixture(events: [#"{"type":"thread.started","thread_id":"fixture"}"#, #"{"type":"turn.started"}"#, #"{"type":"item.completed","item":{"type":"agent_message","text":"{broken"}}"#, #"{"type":"turn.completed"}"#])
        let generated = try await fixture.generator.generate(for: input)
        XCTAssertEqual(generated.reply.replyText, "您好")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.exited.path))
    }

    private let input = PromptInput(uid:"early-test",historyVersion:"v1",historyJSONL:"[]",historyText:"",imagePaths:[])
    private var completedEvents: [String] {
        [#"{"type":"thread.started","thread_id":"fixture"}"#,
         #"{"type":"turn.started"}"#,
         #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{\"decision\":\"auto_send\",\"risk_level\":\"low\",\"reply_text\":\"您好\",\"reason\":\"普通咨询\"}"}}"#,
         #"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":10}}"#]
    }

    private func makeFixture(events:[String], tail: Double = 0.6, exitCode: Int = 0, finalNewline:Bool = true, inheritedStdout:Bool = false) throws -> (generator:CodexReplyGenerator,exited:URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let script = root.appendingPathComponent("fake-cli.sh")
        let exited = root.appendingPathComponent("exited")
        let emit = events.enumerated().map { index, event in
            "printf '\(index == events.count-1 && !finalNewline ? "%s" : "%s\\n")' '\(event)'"
        }.joined(separator:"\n")
        let source = """
        #!/bin/sh
        if [ "$1" = "login" ]; then echo 'Logged in using ChatGPT'; exit 0; fi
        out=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
        done
        cat >/dev/null
        \(emit)
        \(inheritedStdout ? "sleep 2 &" : "")
        sleep \(tail)
        printf '%s' '{"decision":"auto_send","risk_level":"low","reply_text":"您好","reason":"普通咨询"}' > "$out"
        touch '\(exited.path)'
        exit \(exitCode)
        """
        try Data(source.utf8).write(to:script)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
        let schema=root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to:schema)
        return (CodexReplyGenerator(executableURL:script,schemaURL:schema,traceDirectory:root.appendingPathComponent("trace")),exited)
    }

    private func waitForExit(_ url:URL) async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath:url.path) { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("fixture did not exit")
    }
}
