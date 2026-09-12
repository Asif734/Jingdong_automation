import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport
@testable import CustomerReplyBatchCore

final class CodexInvocationTests: XCTestCase {
    func testCreatePersistsSessionAndKeepsReadOnlySandbox() {
        let invocation = CodexInvocation(
            mode: .create,
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            schemaURL: URL(fileURLWithPath: "/tmp/schema.json"),
            resultURL: URL(fileURLWithPath: "/tmp/result.json"),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/empty-customer-workspace"),
            imagePaths: ["/tmp/customer.jpg"]
        )

        XCTAssertEqual(Array(invocation.arguments.prefix(5)), ["-a", "never", "--disable", "shell_tool", "exec"])
        XCTAssertFalse(invocation.arguments.contains("--ephemeral"))
        XCTAssertTrue(invocation.arguments.containsSubsequence(["--disable", "shell_tool"]))
        XCTAssertTrue(invocation.arguments.containsSubsequence(["-C", "/tmp/empty-customer-workspace"]))
        XCTAssertTrue(invocation.arguments.contains("read-only"))
        XCTAssertTrue(invocation.arguments.contains("/tmp/customer.jpg"))
        XCTAssertEqual(invocation.arguments.last, "-")
    }

    func testResumeUsesOnlyTheExactPersistedSessionID() {
        let invocation = CodexInvocation(
            mode: .resume(sessionID: "session-for-exact-user"),
            model: "gpt-5.6-sol",
            reasoningEffort: "medium",
            schemaURL: URL(fileURLWithPath: "/tmp/schema.json"),
            resultURL: URL(fileURLWithPath: "/tmp/result.json"),
            workingDirectoryURL: URL(fileURLWithPath: "/tmp/empty-customer-workspace"),
            imagePaths: []
        )

        XCTAssertEqual(Array(invocation.arguments.prefix(6)), ["-a", "never", "--disable", "shell_tool", "exec", "resume"])
        XCTAssertTrue(invocation.arguments.contains("session-for-exact-user"))
        XCTAssertFalse(invocation.arguments.contains("--last"))
        XCTAssertFalse(invocation.arguments.contains("--ephemeral"))
        XCTAssertFalse(invocation.arguments.contains("-C"))
        XCTAssertFalse(invocation.arguments.contains("/tmp/empty-customer-workspace"))
        XCTAssertEqual(invocation.arguments.suffix(2), ["session-for-exact-user", "-"])
    }

    func testStreamCapturesThreadIDWithoutWeakeningReplyValidation() throws {
        let stream = CLIReplyStream()
        let reply = """
        {"decision":"auto_send","risk_level":"low","reply_text":"您好","reason":"普通咨询"}
        """
        var received: (ReplyEnvelope, String?)?
        let events = [
            "{\"type\":\"thread.started\",\"thread_id\":\"session-u1\"}",
            "{\"type\":\"turn.started\"}",
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"item-1\",\"type\":\"agent_message\",\"phase\":\"final_answer\",\"text\":\(try jsonString(reply))}}",
            "{\"type\":\"turn.completed\"}"
        ].joined(separator: "\n") + "\n"

        stream.consume(Data(events.utf8)) { envelope, threadID in
            received = (envelope, threadID)
        }

        XCTAssertEqual(stream.threadID, "session-u1")
        XCTAssertEqual(received?.0.replyText, "您好")
        XCTAssertEqual(received?.1, "session-u1")
    }

    private func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        return String(encoded.dropFirst().dropLast())
    }
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        return indices.dropLast(subsequence.count - 1).contains { start in
            Array(self[start..<(start + subsequence.count)]) == subsequence
        }
    }
}
