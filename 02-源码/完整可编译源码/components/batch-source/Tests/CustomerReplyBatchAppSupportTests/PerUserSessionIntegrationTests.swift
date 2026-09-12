import Foundation
import XCTest
@testable import CustomerReplyBatchAppSupport

final class PerUserSessionIntegrationTests: XCTestCase {
    func testFollowUpResumesSameUIDWithHistorySuffixOnly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await fixture.generator.generate(for: input(uid: "u1", version: "v1", history: "a\n"))
        _ = try await fixture.generator.generate(for: input(uid: "u1", version: "v2", history: "a\nb\n"))

        XCTAssertEqual(try fixture.call(1).mode, "create")
        XCTAssertEqual(try fixture.call(2).mode, "resume")
        XCTAssertEqual(try fixture.call(2).resumeID, try fixture.call(1).threadID)
        XCTAssertTrue(try fixture.call(2).prompt.contains("b\n"))
        XCTAssertFalse(try fixture.call(2).prompt.contains("a\nb\n"))
    }

    func testDifferentUIDsNeverShareSessions() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await fixture.generator.generate(for: input(uid: "u1", version: "v1", history: "a\n"))
        _ = try await fixture.generator.generate(for: input(uid: "u2", version: "v1", history: "x\n"))
        _ = try await fixture.generator.generate(for: input(uid: "u1", version: "v2", history: "a\nb\n"))
        _ = try await fixture.generator.generate(for: input(uid: "u2", version: "v2", history: "x\ny\n"))

        XCTAssertEqual(try fixture.call(3).resumeID, try fixture.call(1).threadID)
        XCTAssertEqual(try fixture.call(4).resumeID, try fixture.call(2).threadID)
        XCTAssertNotEqual(try fixture.call(3).resumeID, try fixture.call(4).resumeID)
    }

    func testVideoEvidenceResumesCustomerSessionWithoutReplacingOrdinaryHistoryCheckpoint() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await fixture.generator.generate(for: input(uid: "u1", version: "v1", history: "a\n"))
        _ = try await fixture.generator.generate(for: PromptInput(
            uid: "u1",
            historyVersion: "video-analysis:hash",
            historyJSONL: "{\"t\":\"video_evidence\"}\n",
            historyText: "",
            imagePaths: [],
            targetCustomerJSONL: "{\"t\":\"video_evidence\"}\n",
            preservesHistoryCheckpoint: true
        ))
        _ = try await fixture.generator.generate(for: input(uid: "u1", version: "v2", history: "a\nb\n"))

        XCTAssertEqual(try fixture.call(2).mode, "resume")
        XCTAssertEqual(try fixture.call(2).resumeID, try fixture.call(1).threadID)
        XCTAssertTrue(try fixture.call(2).prompt.contains("video_evidence"))
        XCTAssertEqual(try fixture.call(3).mode, "resume")
        XCTAssertEqual(try fixture.call(3).resumeID, try fixture.call(1).threadID)
        XCTAssertTrue(try fixture.call(3).prompt.contains("b\n"))
        XCTAssertFalse(try fixture.call(3).prompt.contains("a\nb\n"))
    }

    func testLongIdleStillResumesWhileHistoryRewriteCreatesFreshSession() async throws {
        let clock = TestDateSource(Date(timeIntervalSince1970: 1_800_000_000))
        let fixture = try makeFixture(clock: clock)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await fixture.generator.generate(for: input(uid: "expiry", version: "v1", history: "a\n"))
        clock.advance(by: 10 * 365 * 24 * 60 * 60)
        _ = try await fixture.generator.generate(for: input(uid: "expiry", version: "v2", history: "a\nb\n"))
        _ = try await fixture.generator.generate(for: input(uid: "rewrite", version: "v1", history: "old\n"))
        _ = try await fixture.generator.generate(for: input(uid: "rewrite", version: "v2", history: "changed\nnew\n"))

        XCTAssertEqual(try fixture.call(2).mode, "resume")
        XCTAssertTrue(try fixture.call(2).prompt.contains("b\n"))
        XCTAssertFalse(try fixture.call(2).prompt.contains("a\nb\n"))
        XCTAssertEqual(try fixture.call(4).mode, "create")
        XCTAssertTrue(try fixture.call(4).prompt.contains("changed\nnew\n"))
    }

    func testResumeFailureInvalidatesOnlyThatUIDAndRetriesOneFreshCreate() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.generator.generate(for: input(uid: "u1", version: "v1", history: "a\n"))
        try Data().write(to: fixture.root.appendingPathComponent("fail-next-resume"))

        let generated = try await fixture.generator.generate(
            for: input(uid: "u1", version: "v2", history: "a\nb\n")
        )

        XCTAssertEqual(try fixture.call(2).mode, "resume")
        XCTAssertEqual(try fixture.call(3).mode, "create")
        XCTAssertTrue(try fixture.call(3).prompt.contains("a\nb\n"))
        XCTAssertEqual(generated.timing.sessionRecoveryCount, 1)
    }

    private func input(uid: String, version: String, history: String) -> PromptInput {
        PromptInput(
            uid: uid,
            historyVersion: version,
            historyJSONL: history,
            historyText: "",
            imagePaths: []
        )
    }

    private func makeFixture(clock: TestDateSource = TestDateSource(Date())) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerUserSessionIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-codex.sh")
        let scriptText = fakeCLI(root: root.path)
        try Data(scriptText.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [FileAttributeKey.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: script.path
        )
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        let registry = CodexSessionRegistry(storageURL: root.appendingPathComponent("sessions.json"))
        let generator = CodexReplyGenerator(
            executableURL: script,
            schemaURL: schema,
            sessionRegistry: registry,
            generationGate: UIDGenerationGate(),
            now: { clock.now() }
        )
        return Fixture(root: root, generator: generator)
    }

    private func fakeCLI(root: String) -> String {
        """
        #!/bin/sh
        if [ "$1" = "login" ]; then echo 'Logged in using ChatGPT'; exit 0; fi
        mode=create
        resume_id=""
        while [ "$#" -gt 0 ] && [ "$1" != "exec" ]; do shift; done
        [ "$1" = "exec" ] && shift
        if [ "$1" = "resume" ]; then mode=resume; shift; fi
        out=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            -m|-c|-s|-C|--disable|--output-schema|-i) shift 2 ;;
            --json|--ignore-user-config|--ignore-rules|--skip-git-repo-check) shift ;;
            -) shift ;;
            *) if [ "$mode" = "resume" ]; then resume_id="$1"; fi; shift ;;
          esac
        done
        prompt=$(cat)
        counter_file="\(root)/counter"
        n=0
        if [ -f "$counter_file" ]; then n=$(cat "$counter_file"); fi
        n=$((n+1)); printf '%s' "$n" > "$counter_file"
        uid=$(printf '%s\n' "$prompt" | sed -n 's/^UID: //p' | head -1)
        if [ -z "$uid" ]; then uid=continued; fi
        if [ "$mode" = "create" ]; then thread_id="$uid-session-$n"; else thread_id="$resume_id"; fi
        printf '%s' "$mode" > "\(root)/call-$n.mode"
        printf '%s' "$resume_id" > "\(root)/call-$n.resume"
        printf '%s' "$thread_id" > "\(root)/call-$n.thread"
        printf '%s' "$prompt" > "\(root)/call-$n.prompt"
        if [ "$mode" = "resume" ] && [ -f "\(root)/fail-next-resume" ]; then
          rm "\(root)/fail-next-resume"
          echo 'forced resume failure' >&2
          exit 9
        fi
        printf '{"type":"thread.started","thread_id":"%s"}\n' "$thread_id"
        printf '%s' '{"decision":"auto_send","risk_level":"low","reply_text":"测试回复","reason":"普通咨询"}' > "$out"
        sleep 0.05
        """
    }
}

private struct Fixture {
    let root: URL
    let generator: CodexReplyGenerator

    func call(_ index: Int) throws -> (mode: String, resumeID: String, threadID: String, prompt: String) {
        func read(_ suffix: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("call-\(index).\(suffix)"), encoding: .utf8)
        }
        return (try read("mode"), try read("resume"), try read("thread"), try read("prompt"))
    }
}

private final class TestDateSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}
