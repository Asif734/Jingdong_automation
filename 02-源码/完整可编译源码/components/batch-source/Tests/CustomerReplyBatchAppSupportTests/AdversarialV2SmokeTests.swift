import XCTest
@testable import CustomerReplyBatchAppSupport

final class AdversarialV2SmokeTests: XCTestCase {
    private struct HardCase: Sendable {
        let id: String
        let history: String
        let target: String
        let requiredGroups: [[String]]
        let forbidden: [String]
    }

    private struct HardResult: Codable, Sendable {
        let id: String
        let passed: Bool
        let reply: String
        let totalMilliseconds: Double
        let submittedHistoryBytes: Int
        let missingGroups: [[String]]
        let forbiddenHits: [String]
        let error: String?
    }

    func testHardQuestionsAgainstRealFocusedV2AndLocalCodex() async throws {
        guard ProcessInfo.processInfo.environment["RUN_REAL_V2_HARD_SMOKE"] == "1" else {
            throw XCTSkip("仅显式运行高难度本机 Codex 测试；不入队、不发送")
        }
        let project = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["V2_PROJECT_ROOT"]))
        let runtime = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["V2_RUNTIME_ROOT"]))
        let knowledgeBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AI客服记录/知识库/Grozziie-China-KB-2026-08-24.zip")
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("real-v2-hard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let retriever = V2KnowledgeRetriever(
            pythonURL: URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"),
            scriptURL: project.appendingPathComponent("Resources/V2Knowledge/retrieve_top12.py"),
            sitePackagesURL: runtime.appendingPathComponent(".venv/lib/python3.12/site-packages"),
            seedCacheURL: runtime.appendingPathComponent("cache"),
            writableCacheURL: temporary.appendingPathComponent("cache")
        )
        let oldNoise = (0..<40).map {
            "{\"sender\":\"customer\",\"v\":\"旧问题\($0)：TP732能连Mac吗\"}\n{\"sender\":\"service\",\"v\":\"TP732不支持原生macOS\"}"
        }.joined(separator: "\n")
        let cases: [HardCase] = [
            HardCase(
                id: "old-history-pollution-m880-power",
                history: oldNoise + "\n{\"sender\":\"customer\",\"v\":\"停电了，普通款M880完全不工作，我现在怎么办？\"}",
                target: "{\"sender\":\"customer\",\"v\":\"停电了，普通款M880完全不工作，我现在怎么办？\"}\n",
                requiredGroups: [["普通款", "带电池", "断电"], ["来电", "恢复供电", "电源"]],
                forbidden: ["macos", "tp732", "转人工"]
            ),
            HardCase(
                id: "td630g-mac-wireless-boundary",
                history: "{\"sender\":\"customer\",\"v\":\"我确认标签是TD630G，MacBook能不能直接走WiFi无线打印？不要USB。\"}",
                target: "{\"sender\":\"customer\",\"v\":\"我确认标签是TD630G，MacBook能不能直接走WiFi无线打印？不要USB。\"}\n",
                requiredGroups: [["不支持", "不能"], ["mac", "macbook"], ["无线", "wifi", "wi-fi"], ["usb"]],
                forbidden: ["转人工"]
            ),
            HardCase(
                id: "ak890-mobile-wireless-misleading",
                history: "{\"sender\":\"customer\",\"v\":\"AK890我想用iPhone蓝牙打印，蓝牙搜不到的话能改连WiFi吗？\"}",
                target: "{\"sender\":\"customer\",\"v\":\"AK890我想用iPhone蓝牙打印，蓝牙搜不到的话能改连WiFi吗？\"}\n",
                requiredGroups: [["usb"], ["windows"], ["不支持", "不能", "仅支持"]],
                forbidden: ["转人工", "连接2.4g", "配网"]
            ),
            HardCase(
                id: "m880-group15-no-matching-video",
                history: "{\"sender\":\"customer\",\"v\":\"M880原装卡能打，文具店买的同尺寸卡一插就退出不打印。第15组怎么设？把对应视频也发我。\"}",
                target: "{\"sender\":\"customer\",\"v\":\"M880原装卡能打，文具店买的同尺寸卡一插就退出不打印。第15组怎么设？把对应视频也发我。\"}\n",
                requiredGroups: [["15"], ["00"], ["暂无", "没有", "不发送", "无可核实", "暂未", "未查到", "不发"]],
                forbidden: ["491279178909.mp4", "转人工"]
            ),
            HardCase(
                id: "windows-unknown-usb-descriptor",
                history: "{\"sender\":\"customer\",\"v\":\"针式打印机插Windows后设备管理器显示未知USB设备、设备描述符请求失败，装驱动也找不到机器，第一步做什么？\"}",
                target: "{\"sender\":\"customer\",\"v\":\"针式打印机插Windows后设备管理器显示未知USB设备、设备描述符请求失败，装驱动也找不到机器，第一步做什么？\"}\n",
                requiredGroups: [["通电", "开机"], ["数据线", "打印线"], ["usb接口", "usb 口", "usb端口"]],
                forbidden: ["等待30秒", "转人工"]
            ),
            HardCase(
                id: "m880-light-print-next-step",
                history: "{\"sender\":\"customer\",\"v\":\"M880字很浅\"}\n{\"sender\":\"service\",\"v\":\"请轻微顺时针转动色带旋钮并换色带面\"}\n{\"sender\":\"customer\",\"v\":\"已经转过旋钮也换过面了，还是很浅，下一步呢？\"}",
                target: "{\"sender\":\"customer\",\"v\":\"已经转过旋钮也换过面了，还是很浅，下一步呢？\"}\n",
                requiredGroups: [["断电", "拔掉电源", "视频", "拍"], ["色带", "打印"]],
                forbidden: ["转动色带旋钮", "换色带面", "机器坏了", "转人工"]
            ),
            HardCase(
                id: "three-overlapping-cross-midnight-shifts",
                history: "{\"sender\":\"customer\",\"v\":\"M880同一天有三种班：8点到18点、凌晨4点到18点、早7点到第二天7点，而且会重叠。自动班次怎么设？请给对应视频。\"}",
                target: "{\"sender\":\"customer\",\"v\":\"M880同一天有三种班：8点到18点、凌晨4点到18点、早7点到第二天7点，而且会重叠。自动班次怎么设？请给对应视频。\"}\n",
                requiredGroups: [["手动"], ["02"], ["00"], ["491279010943.mp4"]],
                forbidden: ["转人工"]
            ),
            HardCase(
                id: "two-unanswered-questions-one-batch",
                history: "{\"sender\":\"customer\",\"v\":\"TD630能连原生Mac吗？\"}\n{\"sender\":\"customer\",\"v\":\"另外它有WiFi吗，还是只有蓝牙和USB？\"}",
                target: "{\"sender\":\"customer\",\"v\":\"TD630能连原生Mac吗？\"}\n{\"sender\":\"customer\",\"v\":\"另外它有WiFi吗，还是只有蓝牙和USB？\"}\n",
                requiredGroups: [["mac"], ["支持"], ["不支持wi", "不支持 wi", "没有wi", "没有 wi"], ["蓝牙"], ["usb"]],
                forbidden: ["转人工"]
            ),
        ]

        var results: [HardResult] = []
        for start in stride(from: 0, to: cases.count, by: 4) {
            let batch = Array(cases[start..<min(start + 4, cases.count)])
            let batchResults = await withTaskGroup(of: HardResult.self, returning: [HardResult].self) { group in
                for testCase in batch {
                    group.addTask {
                        do {
                            let caseRoot = temporary.appendingPathComponent(testCase.id, isDirectory: true)
                            let generator = CodexReplyGenerator(
                                traceDirectory: caseRoot.appendingPathComponent("trace"),
                                sessionRegistry: CodexSessionRegistry(storageURL: caseRoot.appendingPathComponent("sessions.json")),
                                knowledgeRetriever: retriever
                            )
                            let generated = try await generator.generate(for: PromptInput(
                                uid: "hard-\(testCase.id)",
                                historyVersion: "v1",
                                historyJSONL: testCase.history,
                                historyText: "",
                                imagePaths: [],
                                knowledgeBasePaths: [knowledgeBase.path],
                                targetCustomerJSONL: testCase.target
                            ))
                            await generated.cleanupTask?.value
                            let normalized = generated.reply.replyText.lowercased().replacingOccurrences(of: " ", with: "")
                            let missing = testCase.requiredGroups.filter { group in
                                !group.contains { normalized.contains($0.lowercased().replacingOccurrences(of: " ", with: "")) }
                            }
                            let forbiddenHits = testCase.forbidden.filter {
                                normalized.contains($0.lowercased().replacingOccurrences(of: " ", with: ""))
                            }
                            return HardResult(
                                id: testCase.id,
                                passed: missing.isEmpty && forbiddenHits.isEmpty,
                                reply: generated.reply.replyText,
                                totalMilliseconds: generated.timing.totalMilliseconds,
                                submittedHistoryBytes: generated.timing.submittedHistoryBytes,
                                missingGroups: missing,
                                forbiddenHits: forbiddenHits,
                                error: nil
                            )
                        } catch {
                            return HardResult(
                                id: testCase.id,
                                passed: false,
                                reply: "",
                                totalMilliseconds: 0,
                                submittedHistoryBytes: 0,
                                missingGroups: testCase.requiredGroups,
                                forbiddenHits: [],
                                error: error.localizedDescription
                            )
                        }
                    }
                }
                var values: [HardResult] = []
                for await value in group { values.append(value) }
                return values
            }
            results.append(contentsOf: batchResults)
        }
        results.sort { $0.id < $1.id }
        let reportURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["V2_HARD_REPORT"] ?? temporary.appendingPathComponent("report.json").path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(results).write(to: reportURL, options: .atomic)
        for result in results {
            print("HARD_V2_CASE=\(result.id) PASS=\(result.passed) MS=\(Int(result.totalMilliseconds)) REPLY=\(result.reply)")
        }
        print("HARD_V2_REPORT=\(reportURL.path)")
        XCTAssertTrue(results.allSatisfy(\.passed), "高难度失败项：\(results.filter { !$0.passed }.map(\.id))")
    }
}
