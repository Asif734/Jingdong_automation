import XCTest
@testable import CustomerReplyBatchAppSupport
@testable import CustomerReplyBatchCore

final class CodexReplyGeneratorTests: XCTestCase {
    func testProductionCodexDeadlineAllowsSlowKnowledgeBaseRuns() {
        XCTAssertGreaterThan(CodexDeadlinePolicy.production.hard, .seconds(100))
        XCTAssertEqual(CodexDeadlinePolicy.production.hard, .seconds(300))
    }
    func testHangingLoginCheckReleasesWithinHardDeadline() async throws {
        let fixture = try makeHangingFixture(loginHangs: true)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await fixture.generator.generate(for: fixture.input)
            XCTFail("hanging login check must fail")
        } catch { }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
    }

    func testHangingCodexTurnReleasesWithinHardDeadline() async throws {
        let fixture = try makeHangingFixture(loginHangs: false)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await fixture.generator.generate(for: fixture.input)
            XCTFail("hanging Codex turn must fail")
        } catch { }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
    }

    func testDefaultSchemaPrefersInstalledAppResourceWithoutLoadingBundleModule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent("Demo.app/Contents/MacOS/Demo")
        let schema = root.appendingPathComponent(
            "Demo.app/Contents/Resources/QianniuCodexBatchRunner_CustomerReplyBatchAppSupport.bundle/reply-output.schema.json"
        )
        try FileManager.default.createDirectory(
            at: schema.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: schema)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var fallbackWasLoaded = false

        let resolved = CodexReplyGenerator.resolveDefaultSchemaURL(
            executablePath: executable.path,
            fallback: {
                fallbackWasLoaded = true
                return nil
            }
        )

        XCTAssertEqual(resolved.standardizedFileURL, schema.standardizedFileURL)
        XCTAssertFalse(fallbackWasLoaded)
    }

    func testGeneratorRunsExecutableAndDecodesStructuredReply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-codex.sh")
        try Data(fakeScript.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        let generator = CodexReplyGenerator(executableURL: script, schemaURL: schema)
        let input = PromptInput(uid: "u1", historyVersion: "v1", historyJSONL: "[]", historyText: "你好", imagePaths: [])

        let result = try await generator.generate(for: input)

        XCTAssertEqual(result.reply.decision, .autoSend)
        XCTAssertEqual(result.reply.replyText, "您好")
        XCTAssertEqual(result.sessionID, "session-u1")
        XCTAssertGreaterThanOrEqual(result.timing.loginCheckMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(result.timing.codexExecMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(result.timing.decodeMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(result.timing.totalMilliseconds, 0)
    }

    func testGeneratorUsesDedicatedCodexHomeForLoginAndTurnAndEmptyWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let codexHome = root.appendingPathComponent("customer-codex-home", isDirectory: true)
        let workspace = root.appendingPathComponent("empty-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let observations = root.appendingPathComponent("observations.txt")
        let script = root.appendingPathComponent("fake-codex.sh")
        let source = """
        #!/bin/sh
        printf '%s|%s\n' "$CODEX_HOME" "$*" >> '\(observations.path)'
        if [ "$1" = "login" ]; then echo 'Logged in using ChatGPT'; exit 0; fi
        out=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
        done
        cat >/dev/null
        printf '%s\n' '{"type":"thread.started","thread_id":"isolated-session"}'
        printf '%s' '{"decision":"auto_send","risk_level":"low","reply_text":"隔离成功","reason":"普通咨询"}' > "$out"
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        let generator = CodexReplyGenerator(
            executableURL: script,
            schemaURL: schema,
            codexHomeURL: codexHome,
            workingDirectoryURL: workspace
        )

        _ = try await generator.generate(for: PromptInput(
            uid: "u1", historyVersion: "v1", historyJSONL: "[]", historyText: "", imagePaths: []
        ))

        let lines = try String(contentsOf: observations, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix(codexHome.path + "|") })
        XCTAssertTrue(lines[1].contains("--disable shell_tool"))
        XCTAssertTrue(lines[1].contains("-C \(workspace.path)"))
    }

    func testGeneratorRejectsNonChatGPTLoginBeforeGenerating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("api-login.sh")
        let source = "#!/bin/sh\necho 'Logged in using API key'\n"
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        let generator = CodexReplyGenerator(executableURL: script, schemaURL: schema)

        do {
            _ = try await generator.generate(for: PromptInput(uid: "u1", historyVersion: "v1", historyJSONL: "[]", historyText: "", imagePaths: []))
            XCTFail("应当拒绝非 ChatGPT 登录")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ChatGPT"))
        }
    }

    func testGeneratorPinsSolModelWithMediumReasoning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("model-check-codex.sh")
        try Data(modelCheckingScript.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        let generator = CodexReplyGenerator(executableURL: script, schemaURL: schema)
        let input = PromptInput(uid: "u1", historyVersion: "v1", historyJSONL: "[]", historyText: "你好", imagePaths: [])

        let result = try await generator.generate(for: input)

        XCTAssertEqual(result.reply.replyText, "已固定模型")
    }

    func testGeneratorDrainsLargeOutputAndKeepsTimedEventsOnSuccessAndFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        for code in [0, 7] {
            let script = root.appendingPathComponent("events-\(code).sh")
            let source = """
            #!/bin/sh
            if [ "$1" = "login" ]; then echo 'Logged in using ChatGPT'; exit 0; fi
            out=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
            done
            printf '%s\\n' '{"type":"thread.started","thread_id":"session-u1"}' '{"type":"turn.started"}'
            # More than pipe capacity BEFORE reading stdin; catches parent/child pipe deadlocks.
            i=0
            while [ "$i" -lt 2000 ]; do
              printf '%s\\n' '{"type":"item.updated","item":{"id":"item_0","type":"agent_message","text":"sensitive-content-sensitive-content-sensitive-content"}}'
              i=$((i+1))
            done
            cat >/dev/null
            printf '%s\\n' '{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"unzip -l /safe/KB.zip"}}'
            sleep 0.05
            printf '%s\\n' '{"type":"item.completed","item":{"id":"item_1","type":"command_execution","exit_code":0}}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":50,"output_tokens":10}}'
            printf '%s' '{"decision":"auto_send","risk_level":"low","reply_text":"您好","reason":"普通咨询"}' > "$out"
            exit \(code)
            """
            try Data(source.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let directory = root.appendingPathComponent("trace-\(code)")
            let generator = CodexReplyGenerator(executableURL: script, schemaURL: schema, traceDirectory: directory)
            let input = PromptInput(uid: "u1", historyVersion: "v1", historyJSONL: String(repeating: "x", count: 100_000), historyText: "", imagePaths: [])
            do {
                let result = try await generator.generate(for: input)
                XCTAssertEqual(code, 0)
                XCTAssertEqual(result.reply.replyText, "您好")
                XCTAssertNotNil(result.timing.cliTraceReportPath)
            } catch {
                XCTAssertEqual(code, 7, error.localizedDescription)
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let events = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "jsonl" }))
                .split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            XCTAssertEqual(events.last?["exit_code"] as? Int, code)
            // A flood may buffer start/end into the same read: do not mistake wall sleep
            // for guaranteed precision of received events. Exact partition is tested separately.
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(events.last?["tool_active_ms"] as? Double), 0)
            XCTAssertNotNil(events.first { $0["tool_duration_ms"] != nil })
            XCTAssertEqual(events.filter { ($0["event"] as? String) == "item.updated" }.count, 2000)
            let text = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "txt" }))
            XCTAssertFalse(text.contains("sensitive-content"))
        }
    }

    private var fakeScript: String {
        """
        #!/bin/sh
        if [ "$1" = "login" ]; then echo 'Logged in using ChatGPT'; exit 0; fi
        out=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
        done
        cat >/dev/null
        printf '%s\n' '{"type":"thread.started","thread_id":"session-u1"}'
        printf '%s' '{"decision":"auto_send","risk_level":"low","reply_text":"您好","reason":"普通咨询"}' > "$out"
        """
    }

    private func makeHangingFixture(
        loginHangs: Bool
    ) throws -> (generator: CodexReplyGenerator, input: PromptInput) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-hang-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-codex.sh")
        let source = loginHangs
            ? "#!/bin/sh\nsleep 30\n"
            : "#!/bin/sh\nif [ \"$1\" = login ]; then echo 'Logged in using ChatGPT'; exit 0; fi\nsleep 30\n"
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        return (
            CodexReplyGenerator(
                executableURL: script,
                schemaURL: schema,
                loginDeadlines: (.milliseconds(20), .milliseconds(100)),
                codexDeadlines: (.milliseconds(20), .milliseconds(100))
            ),
            PromptInput(uid: "hang", historyVersion: "v1", historyJSONL: "[]", historyText: "", imagePaths: [])
        )
    }

    private var modelCheckingScript: String {
        """
        #!/bin/sh
        if [ "$1" = "login" ]; then echo 'Logged in using ChatGPT'; exit 0; fi
        out=""
        model=""
        reasoning=""
        json_events=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            -m) model="$2"; shift 2 ;;
            -c) reasoning="$2"; shift 2 ;;
            --json) json_events="yes"; shift ;;
            *) shift ;;
          esac
        done
        [ "$model" = "gpt-5.6-sol" ] || { echo "wrong model: $model" >&2; exit 41; }
        [ "$reasoning" = 'model_reasoning_effort="medium"' ] || { echo "wrong reasoning: $reasoning" >&2; exit 42; }
        [ "$json_events" = "yes" ] || { echo "missing structured CLI events" >&2; exit 43; }
        cat >/dev/null
        printf '%s\n' '{"type":"thread.started","thread_id":"session-model-check"}'
        printf '%s' '{"decision":"auto_send","risk_level":"low","reply_text":"已固定模型","reason":"普通咨询"}' > "$out"
        sleep 0.05
        """
    }
}
