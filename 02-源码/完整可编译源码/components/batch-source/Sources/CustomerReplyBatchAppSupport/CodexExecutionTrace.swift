import Foundation
import CustomerReplyBatchCore

/// One CLI invocation; owned by the stdout reader, then finished after that reader joins.
/// Persist only allowlisted metadata, never raw commands, output, prompts or reasoning text.
final class CodexExecutionTrace: @unchecked Sendable {
    private(set) var reportURL: URL?
    private(set) var eventsURL: URL?
    private let startedAt: Date
    private let knowledgePaths: [String]
    private var textHandle: FileHandle?
    private var jsonHandle: FileHandle?
    private var pending = Data()
    private var discardingLine = false
    private var invalidLines = 0
    private var previous: Double = 0
    private var sawEvent = false
    private var turnEnded = false
    private var tools: [String: Double] = [:]
    private var totals: [String: Double] = [:]
    private var tokenUsage: [String: Int] = [:]
    private let dateFormatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    private static let maxLineBytes = 4 * 1_024 * 1_024

    init(directory: URL?, input: PromptInput, startedAt: Date = Date()) {
        self.startedAt = startedAt
        knowledgePaths = input.knowledgeBasePaths
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = TaskIdentity.make(uid: input.uid, historyVersion: input.historyVersion) + "-" + UUID().uuidString
            let report = directory.appendingPathComponent(name + ".txt")
            let events = directory.appendingPathComponent(name + ".jsonl")
            let header = """
            CLI 内部步骤耗时（正在执行，完成后末尾会追加汇总）
            UID：\(input.uid)
            任务 ID：\(TaskIdentity.make(uid: input.uid, historyVersion: input.historyVersion))
            开始时间：\(timestamp(0))
            模型：\(CodexReplyGenerator.model) / \(CodexReplyGenerator.reasoningEffort)

            时间为本机收到事件的时间，非服务器内部计时；事件缓冲可能影响精度。
            等待区间不能区分网络、服务端排队、模型推理或生成；不等于纯思考时间。
            工具区间是已观察到开始/结束的跨度（并行取并集）；完成事件缺少开始时不猜耗时。
            仅记录步骤元数据；不保存命令原文、工具输出、聊天正文、凭据或思考正文。
            本报告仅计 CLI，不含 OCR、业务排队、登录检查和千牛发送。

            """
            try Data(header.utf8).write(to: report, options: .atomic)
            try Data().write(to: events)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: events.path)
            textHandle = try FileHandle(forWritingTo: report)
            try textHandle?.seekToEnd()
            jsonHandle = try FileHandle(forWritingTo: events)
            reportURL = report
            eventsURL = events
            write(["event": "process.started", "elapsed_ms": 0, "at": timestamp(0)], text: "+0.000 s  启动 CLI\n")
        } catch {
            // Diagnostics must never change reply generation/routing on a disk error.
            try? textHandle?.close()
            try? jsonHandle?.close()
            textHandle = nil
            jsonHandle = nil
            reportURL = nil
            eventsURL = nil
        }
    }

    func consume(_ data: Data, elapsed: Double) {
        // Bound memory even if a tool prints a huge JSON event or malformed stream.
        for part in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            if part.offset > 0 {
                if !discardingLine && !pending.isEmpty { event(pending, elapsed: elapsed) }
                pending.removeAll(keepingCapacity: true)
                discardingLine = false
            }
            if !discardingLine {
                if pending.count + part.element.count > Self.maxLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    discardingLine = true
                    invalidLines += 1
                } else {
                    pending.append(contentsOf: part.element)
                }
            }
        }
    }

    private func event(_ data: Data, elapsed: Double) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawType = object["type"] as? String else { invalidLines += 1; return }
        let known = ["thread.started", "turn.started", "turn.completed", "turn.failed", "item.started", "item.updated", "item.completed", "error"]
        let type = known.contains(rawType) ? rawType : "unknown_event"
        var row = advance(to: elapsed)
        row["event"] = type
        sawEvent = true
        var label: String
        switch type {
        case "thread.started": label = "CLI 会话就绪"
        case "turn.started": label = "开始处理"
        case "turn.completed": label = "本轮生成完成"; turnEnded = true
        case "turn.failed": label = "本轮失败（错误正文不记录）"; turnEnded = true
        case "error": label = "CLI 报错/重连提示（错误正文不记录）"
        default: label = "CLI 事件"
        }
        if let item = object["item"] as? [String: Any] {
            let kind = item["type"] as? String ?? ""
            let kinds = ["command_execution", "mcp_tool_call", "web_search", "file_change", "agent_message", "reasoning", "todo_list", "error"]
            row["item_type"] = kinds.contains(kind) ? kind : "unknown_item"
            let rawID = item["id"] as? String ?? ""
            let id = String(rawID.prefix(100)).filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            if !id.isEmpty { row["item_id"] = id }
            let isTool = ["command_execution", "mcp_tool_call", "web_search"].contains(kind)
            if isTool {
                label = kind == "command_execution" ? "本地命令" : (kind == "mcp_tool_call" ? "MCP 工具" : "网页检索")
                let command = item["command"] as? String ?? ""
                if knowledgePaths.contains(where: { !$0.isEmpty && command.contains($0) }) {
                    row["resource"] = "configured_knowledge_base"
                    label += "（涉及配置的知识库）"
                }
                // Only program names from a fixed list; never persist arguments or arbitrary text.
                let programs = ["unzip", "zipinfo", "python3", "python", "rg", "grep", "sed", "cat", "ls"]
                    .filter { command.range(of: "(?<![A-Za-z0-9_])" + $0 + "(?![A-Za-z0-9_])", options: .regularExpression) != nil }
                if !programs.isEmpty { row["programs"] = programs; label += " [" + programs.joined(separator: ", ") + "]" }
                if type == "item.started", !id.isEmpty {
                    if tools[id] == nil { tools[id] = previous }
                    label += " 开始"
                } else if type == "item.completed" {
                    if let start = tools.removeValue(forKey: id) {
                        row["tool_duration_ms"] = previous - start
                        label += " 结束，跨度 \(seconds(previous - start)) s"
                    } else {
                        label += " 结束（未收到开始事件，耗时未知）"
                    }
                } else { label += " 更新" }
                if let code = item["exit_code"] as? Int { row["exit_code"] = code; label += "，退出码 \(code)" }
            } else {
                switch kind {
                case "agent_message": label = "回复输出事件（正文略）"
                case "reasoning": label = "模型活动事件（不代表纯思考耗时，正文略）"
                case "error": label = "工具错误事件（正文略）"
                default: label = "其他步骤事件"
                }
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            for key in ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"] {
                if let value = usage[key] as? Int { tokenUsage[key] = value }
            }
            row["usage"] = tokenUsage
        }
        write(row, text: "+\(seconds(previous)) s  \(label)；距上步 \(seconds(row["delta_ms"] as? Double ?? 0)) s [\(categoryLabel(row["interval_category"] as? String ?? ""))]\n")
    }

    private func advance(to elapsed: Double) -> [String: Any] {
        let end = max(previous, elapsed)
        let category = !sawEvent ? "startup" : (!tools.isEmpty ? "tool_active" : (turnEnded ? "shutdown" : "waiting"))
        let delta = end - previous
        totals[category, default: 0] += delta
        previous = end
        return ["elapsed_ms": end, "delta_ms": delta, "interval_category": category, "at": timestamp(end)]
    }

    func replyReady(elapsed: Double) {
        write(["event": "reply.ready", "elapsed_ms": elapsed, "at": timestamp(elapsed)],
              text: "+\(seconds(elapsed)) s  完整回复已验证，可提前交接；CLI 继续后台收尾（不重复发布）\n")
    }

    func finish(elapsed: Double, exitCode: Int32) {
        if !pending.isEmpty && !discardingLine { event(pending, elapsed: elapsed) }
        pending.removeAll()
        var row = advance(to: elapsed)
        row["event"] = "process.completed"
        row["exit_code"] = exitCode
        row["invalid_lines"] = invalidLines
        row["unfinished_tools"] = tools.count
        row["usage"] = tokenUsage
        for name in ["startup", "tool_active", "waiting", "shutdown"] { row[name + "_ms"] = totals[name, default: 0] }
        let summary = """

        CLI 耗时汇总：\(seconds(previous)) s；退出码 \(exitCode)
        启动到首个有效事件：\(seconds(totals["startup", default: 0])) s
        已观察工具执行区间（并行不重复累计）：\(seconds(totals["tool_active", default: 0])) s
        无工具运行的等待区间：\(seconds(totals["waiting", default: 0])) s
        轮次结束到 CLI 退出：\(seconds(totals["shutdown", default: 0])) s
        Token：输入 \(tokenUsage["input_tokens"].map(String.init) ?? "未知")，缓存命中 \(tokenUsage["cached_input_tokens"].map(String.init) ?? "未知")，输出 \(tokenUsage["output_tokens"].map(String.init) ?? "未知")
        缺少结束的工具：\(tools.count)；无效/过大事件：\(invalidLines)（非零时分类可能不完整）。
        注意：等待区间不能区分网络、服务端排队、推理和生成；退出码 0 不代表千牛已送达。
        """
        write(row, text: summary + "\n")
        try? textHandle?.close()
        try? jsonHandle?.close()
        textHandle = nil
        jsonHandle = nil
    }

    private func write(_ row: [String: Any], text: String) {
        if var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) {
            line.append(0x0A)
            try? jsonHandle?.write(contentsOf: line)
        }
        try? textHandle?.write(contentsOf: Data(text.utf8))
    }

    private func timestamp(_ elapsed: Double) -> String {
        dateFormatter.string(from: startedAt.addingTimeInterval(elapsed / 1_000))
    }

    private func seconds(_ ms: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), ms / 1_000) }
    private func categoryLabel(_ name: String) -> String {
        switch name {
        case "startup": return "启动/连接"
        case "tool_active": return "工具执行区间"
        case "shutdown": return "退出收尾"
        default: return "等待下一事件"
        }
    }
}
