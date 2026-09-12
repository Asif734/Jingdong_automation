import XCTest
@testable import CustomerReplyBatchAppSupport

private struct AlwaysFailingKnowledgeRetriever: KnowledgeContextRetrieving {
    func retrieve(historyJSONL: String, knowledgeBasePaths: [String]) async throws -> RetrievedKnowledge {
        throw KnowledgeRetrieverError.unavailable("fixture failure")
    }
}
@testable import CustomerReplyBatchCore

final class RealCodexSmokeTests: XCTestCase {
    func testInstalledPersistentV2GeneratesOneCompleteReplyWithoutSending() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_INSTALLED_FULL_REPLY_BENCHMARK"] == "1" else {
            throw XCTSkip("仅显式执行已安装 V2 + Codex 完整回复计时；不入队、不发送")
        }
        let resources = URL(fileURLWithPath: environment["INSTALLED_RESOURCES"]!, isDirectory: true)
        let knowledgeBase = URL(fileURLWithPath: environment["INSTALLED_KNOWLEDGE_BASE"]!)
        let preservedOutput = environment["INSTALLED_BENCHMARK_OUTPUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let temporary = preservedOutput ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("installed-full-reply-\(UUID())", isDirectory: true)
        defer { if preservedOutput == nil { try? FileManager.default.removeItem(at: temporary) } }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let v2 = resources.appendingPathComponent("V2Knowledge", isDirectory: true)
        let retriever = V2KnowledgeRetriever(
            pythonURL: resources.appendingPathComponent("Python.framework/Versions/3.12/bin/python3.12"),
            scriptURL: v2.appendingPathComponent("retrieve_top12.py"),
            workerScriptURL: v2.appendingPathComponent("serve_top12.py"),
            sitePackagesURL: v2.appendingPathComponent("site-packages", isDirectory: true),
            seedCacheURL: v2.appendingPathComponent("cache", isDirectory: true),
            writableCacheURL: URL(fileURLWithPath: environment["INSTALLED_V2_CACHE"]!, isDirectory: true),
            knowledgeBaseSHA256: environment["INSTALLED_KNOWLEDGE_SHA"]!,
            indexRootURL: URL(fileURLWithPath: environment["INSTALLED_V2_INDEX"]!, isDirectory: true),
            indexAlgorithmVersion: "v2-index-1"
        )
        let history = "{\"sender\":\"customer\",\"t\":\"text\",\"v\":\"TD630支持Wi-Fi吗？\"}\n"
        let input = PromptInput(
            uid: "installed-full-reply-benchmark",
            historyVersion: UUID().uuidString,
            historyJSONL: history,
            historyText: "",
            imagePaths: [],
            knowledgeBasePaths: [knowledgeBase.path],
            targetCustomerJSONL: history
        )
        let generator = CodexReplyGenerator(
            executableURL: URL(fileURLWithPath: environment["INSTALLED_CODEX"]!),
            traceDirectory: temporary.appendingPathComponent("trace"),
            sessionRegistry: CodexSessionRegistry(storageURL: temporary.appendingPathComponent("sessions.json")),
            knowledgeRetriever: retriever,
            retrievalFailurePolicy: .failClosed
        )
        let clock = ContinuousClock()
        let start = clock.now

        let generated = try await generator.generate(for: input)
        let handoffMilliseconds = Double(start.duration(to: clock.now).components.seconds) * 1_000
            + Double(start.duration(to: clock.now).components.attoseconds) / 1e15
        await generated.cleanupTask?.value
        await retriever.shutdown()

        XCTAssertEqual(generated.reply.decision, .autoSend)
        XCTAssertFalse(generated.reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("INSTALLED_FULL_REPLY=\(generated.reply.replyText)")
        print("INSTALLED_WALL_TO_REPLY_MS=\(handoffMilliseconds)")
        print("INSTALLED_LOGIN_MS=\(generated.timing.loginCheckMilliseconds)")
        print("INSTALLED_CODEX_MS=\(generated.timing.codexExecMilliseconds)")
        print("INSTALLED_DECODE_MS=\(generated.timing.decodeMilliseconds)")
        print("INSTALLED_GENERATOR_TOTAL_MS=\(generated.timing.totalMilliseconds)")
        print("INSTALLED_TRACE=\(generated.timing.cliTraceReportPath ?? "")")
    }

    func testFailClosedRetrievalDoesNotLaunchCodexOrFallbackToFullZip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("strict-retrieval-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let knowledge = root.appendingPathComponent("knowledge.zip")
        try Data("fixture".utf8).write(to: knowledge)
        let generator = CodexReplyGenerator(
            executableURL: root.appendingPathComponent("must-not-launch-codex"),
            knowledgeRetriever: AlwaysFailingKnowledgeRetriever(),
            retrievalFailurePolicy: .failClosed
        )
        let input = PromptInput(uid: "buyer", historyVersion: "r1", historyJSONL: "{}\n",
                                historyText: "", imagePaths: [], knowledgeBasePaths: [knowledge.path],
                                targetCustomerJSONL: "{}\n")

        do {
            _ = try await generator.generate(for: input)
            XCTFail("strict retrieval must stop before Codex")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fixture failure"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: generator.executableURL.path))
        }
    }
    func testRealLocalCodexUsesFocusedV2EvidenceForTmallVideo() async throws {
        guard ProcessInfo.processInfo.environment["RUN_REAL_V2_EVIDENCE_SMOKE"] == "1" else {
            throw XCTSkip("仅显式验证 V2 证据与本机 Codex；不入队、不发送")
        }
        let project = URL(fileURLWithPath: ProcessInfo.processInfo.environment["V2_PROJECT_ROOT"]!)
        let runtime = URL(fileURLWithPath: ProcessInfo.processInfo.environment["V2_RUNTIME_ROOT"]!)
        let knowledgeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AI客服记录/知识库/Grozziie-China-KB-2026-08-24.zip")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-v2-evidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let retriever = V2KnowledgeRetriever(
            pythonURL: URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"),
            scriptURL: project.appendingPathComponent("Resources/V2Knowledge/retrieve_top12.py"),
            sitePackagesURL: runtime.appendingPathComponent(".venv/lib/python3.12/site-packages"),
            seedCacheURL: runtime.appendingPathComponent("cache"),
            writableCacheURL: temporary.appendingPathComponent("cache")
        )
        let history = """
        {"sender":"customer","v":"M880班次有重叠"}
        {"sender":"service","v":"建议手动打卡"}
        {"sender":"customer","v":"视频发给我"}
        """
        let input = PromptInput(
            uid: "real-v2-video-smoke",
            historyVersion: "v1",
            historyJSONL: history,
            historyText: "",
            imagePaths: [],
            knowledgeBasePaths: [knowledgeBase.path],
            targetCustomerJSONL: "{\"sender\":\"customer\",\"v\":\"视频发给我\"}\n"
        )
        let generator = CodexReplyGenerator(
            traceDirectory: temporary.appendingPathComponent("trace"),
            sessionRegistry: CodexSessionRegistry(storageURL: temporary.appendingPathComponent("sessions.json")),
            knowledgeRetriever: retriever
        )

        let generated = try await generator.generate(for: input)
        await generated.cleanupTask?.value

        XCTAssertTrue(generated.reply.replyText.contains("491279010943.mp4"), generated.reply.replyText)
        XCTAssertLessThan(generated.timing.submittedHistoryBytes, 100_000)
        print("REAL_V2_REPLY=\(generated.reply.replyText)")
        print("REAL_V2_TOTAL_MS=\(generated.timing.totalMilliseconds)")
    }

    func testRealCLIProducesInternalTimingWithoutSending() async throws {
        guard let path = ProcessInfo.processInfo.environment["CLI_TRACE_SMOKE_DIRECTORY"] else {
            throw XCTSkip("仅显式开启 CLI 耗时测试；不入队、不发送")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let knowledgeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AI客服记录/知识库/Grozziie-China-KB-2026-08-24.zip")
        let input = PromptInput(uid: "cli-timing-test", historyVersion: UUID().uuidString,
            historyJSONL: "{\"sender\":\"customer\",\"t\":\"text\",\"v\":\"CAN TP732CONNECTTOMAC?\"}\n",
            historyText: "", imagePaths: [], knowledgeBasePaths: [knowledgeBase.path])
        let generated = try await CodexReplyGenerator(traceDirectory: root).generate(for: input)
        let handoffMilliseconds = generated.timing.codexExecMilliseconds
        await generated.cleanupTask?.value
        let report = try XCTUnwrap(generated.timing.cliTraceReportPath)
        let rows = try String(contentsOfFile: URL(fileURLWithPath: report).deletingPathExtension().appendingPathExtension("jsonl").path)
            .split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertTrue(rows.contains { ($0["event"] as? String) == "turn.completed" })
        XCTAssertTrue(rows.contains { ($0["item_type"] as? String) == "command_execution" })
        XCTAssertEqual(rows.last?["exit_code"] as? Int, 0)
        let exitMilliseconds = try XCTUnwrap(rows.last?["elapsed_ms"] as? Double)
        XCTAssertGreaterThanOrEqual(exitMilliseconds + 0.01, handoffMilliseconds)
        XCTAssertTrue(rows.contains { ($0["event"] as? String) == "reply.ready" })
        XCTAssertGreaterThan(exitMilliseconds - handoffMilliseconds, 100)
        try Data(("仅生成未发送\n回复：" + generated.reply.replyText + "\n交接毫秒：\(handoffMilliseconds)\n退出毫秒：\(exitMilliseconds)\n节约尾耗毫秒：\(exitMilliseconds-handoffMilliseconds)\n明细：" + report + "\n").utf8)
            .write(to: root.appendingPathComponent("测试结果.txt"), options: .atomic)
        print("CLI_TRACE_REPORT=\(report)")
    }

    func testRealLocalCodexReturnsStructuredCustomerReply() async throws {
        guard ProcessInfo.processInfo.environment["RUN_REAL_CODEX_SMOKE"] == "1" else {
            throw XCTSkip("仅在显式启用时调用本机 Codex")
        }
        let input = PromptInput(
            uid: "local_swift_smoke_test",
            historyVersion: "v1",
            historyJSONL: "{\"sender\":\"customer\",\"t\":\"text\",\"v\":\"你好\"}\n",
            historyText: "客户：你好",
            imagePaths: []
        )

        let generated = try await CodexReplyGenerator().generate(for: input)
        await generated.cleanupTask?.value
        let reply = generated.reply

        XCTAssertEqual(reply.decision, .autoSend)
        XCTAssertEqual(reply.riskLevel, .low)
        XCTAssertFalse(reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testRealLocalCodexReadsTheConfiguredKnowledgeBaseZip() async throws {
        guard ProcessInfo.processInfo.environment["RUN_REAL_CODEX_SMOKE"] == "1" else {
            throw XCTSkip("仅在显式启用时调用本机 Codex")
        }
        let knowledgeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Desktop/AI客服记录/知识库/Grozziie-China-KB-2026-08-24.zip"
            )
        guard FileManager.default.fileExists(atPath: knowledgeBase.path) else {
            throw XCTSkip("本地知识库 ZIP 不存在")
        }
        let input = PromptInput(
            uid: "local_kb_smoke_test",
            historyVersion: "v1",
            historyJSONL: "{\"sender\":\"customer\",\"t\":\"text\",\"v\":\"TD630支持Wi-Fi吗？\"}\n",
            historyText: "客户：TD630支持Wi-Fi吗？",
            imagePaths: [],
            knowledgeBasePaths: [knowledgeBase.path]
        )

        let generated = try await CodexReplyGenerator().generate(for: input)
        await generated.cleanupTask?.value
        let reply = generated.reply

        XCTAssertEqual(reply.decision, .autoSend)
        XCTAssertEqual(reply.riskLevel, .low)
        XCTAssertTrue(reply.replyText.contains("不支持"), reply.replyText)
    }

    func testRealLocalCodexAlwaysReturnsAutoSend() async throws {
        guard ProcessInfo.processInfo.environment["RUN_REAL_CODEX_SMOKE"] == "1" else {
            throw XCTSkip("仅在显式启用时调用本机 Codex")
        }
        let knowledgeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AI客服记录/知识库/Grozziie-China-KB-2026-08-24.zip")
        guard FileManager.default.fileExists(atPath: knowledgeBase.path) else {
            throw XCTSkip("本地知识库 ZIP 不存在")
        }
        let cases = [
            "我不知道具体型号，这个怎么连接电脑？",
            "打印机不出纸，刚发现问题，还没有做过排查",
            "打印机刚才冒烟了",
            "这个订单我不要了，请直接给我退款",
            "请把这个订单的收货地址改成上海市",
        ]
        let generator = CodexReplyGenerator()

        for (index, message) in cases.enumerated() {
            let input = PromptInput(
                uid: "policy-smoke-\(index)",
                historyVersion: "v1",
                historyJSONL: "{\"sender\":\"customer\",\"t\":\"text\",\"v\":\"\(message)\"}\n",
                historyText: "客户：\(message)",
                imagePaths: [],
                knowledgeBasePaths: [knowledgeBase.path]
            )
            let generated = try await generator.generate(for: input)
            await generated.cleanupTask?.value
            let reply = generated.reply
            XCTAssertEqual(reply.decision, .autoSend, message)
            XCTAssertFalse(reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
