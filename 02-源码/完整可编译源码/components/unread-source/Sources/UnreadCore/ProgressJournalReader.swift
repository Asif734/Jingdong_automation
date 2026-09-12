import CryptoKit
import Foundation

public struct ProgressEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let title: String
    public let detail: String
    public init(id: String, date: Date, title: String, detail: String) {
        self.id = id; self.date = date; self.title = title; self.detail = detail
    }
}

public struct ProgressTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let uid: String
    public let stage: String
    public let events: [ProgressEvent]
    public let isTerminal: Bool
    public let cliActive: Bool
    public init(id: String, uid: String, stage: String, events: [ProgressEvent], isTerminal: Bool, cliActive: Bool) {
        self.id = id; self.uid = uid; self.stage = stage; self.events = events
        self.isTerminal = isTerminal; self.cliActive = cliActive
    }
}

public struct ProgressSnapshot: Sendable {
    public let tasks: [ProgressTask]
    public let warnings: [String]
    public let activeCLICount: Int
    public init(tasks: [ProgressTask], warnings: [String], activeCLICount: Int) {
        self.tasks = tasks; self.warnings = warnings; self.activeCLICount = activeCLICount
    }
}

/// Read-only observer. Call serially from a background queue, never the main thread.
public final class ProgressJournalReader {
    private let root: URL
    private let since: Date
    private let files = FileManager.default
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    private var tasks: [String: TaskState] = [:]
    private var directories: [String: DirectoryCache] = [:]
    private var objects: [String: ObjectCache] = [:]
    private var tails: [String: Tail] = [:]
    private var warnings: [String] = []
    private var readBudget = 0
    private var reservedForLogs = 0
    private var archiveOffset = 0
    private var activeQueue: Set<String> = []
    private static let maxLine = 64 * 1024
    private static let maxChunk = 256 * 1024

    private struct Stamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }
    private struct DirectoryCache { let stamp: Stamp; let children: [URL]; let limited: Bool }
    private struct ObjectCache { let stamp: Stamp; let object: [String: Any]? }
    private struct TaskState {
        let id: String
        var uid: String
        var stage = "状态待确认"
        var rank = 0
        var terminal = false
        var date = Date.distantPast
        var stageDate = Date.distantPast
        var events: [ProgressEvent] = []
    }
    private struct Tail {
        var stamp: Stamp
        var offset: UInt64 = 0
        var pending = Data()
        var discarding = false
        var boundary = Data()
        var warning: String?
        var taskID: String?
        var started = false
        var completed = false
    }

    public init(root: URL, since: Date) {
        self.root = root.standardizedFileURL
        self.since = since
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func read() -> ProgressSnapshot {
        warnings = []
        readBudget = 2 * 1024 * 1024
        reservedForLogs = 1024 * 1024
        activeQueue = []
        guard stamp(root) != nil else {
            return ProgressSnapshot(tasks: snapshots(), warnings: ["进度目录不可读；状态未知，不能据此判断完成。"], activeCLICount: activeCLI)
        }
        for directory in ["待处理", "处理中", "待发送", "发送中"] {
            for url in children(root.appendingPathComponent(directory)) where url.pathExtension == "json" {
                observeQueue(url, directory: directory)
            }
        }
        for url in children(root.appendingPathComponent("运行状态/发送尝试")) where url.pathExtension == "json" {
            observeAttempt(url)
        }
        reservedForLogs = 0
        let traceDirectory = root.appendingPathComponent("运行状态/CLI明细")
        let traceFiles = children(traceDirectory).filter { $0.pathExtension == "jsonl" }
        let visiblePaths = Set(traceFiles.map(\.path))
        for url in traceFiles {
            let stem = url.deletingPathExtension().lastPathComponent
            let id = String(stem.prefix(64))
            guard id.count == 64, id.allSatisfy({ $0.isHexDigit }), stem.dropFirst(64).hasPrefix("-") else { continue }
            guard let info = stamp(url), info.modified >= since || activeQueue.contains(id) || tails[url.path] != nil else { continue }
            let uid = tasks[id]?.uid ?? traceUID(url)
            guard let uid else { warn("CLI 明细缺少可验证 UID，部分步骤无法归属。"); continue }
            if tasks[id] == nil { tasks[id] = TaskState(id: id, uid: uid) }
            tail(url, taskID: id, fallbackDate: info.modified)
        }
        for (path, value) in tails where value.taskID != nil && value.started && !value.completed && !visiblePaths.contains(path) {
            warn("执行中的 CLI 明细已不可读；退出状态未知。")
        }
        if tails.values.contains(where: { value in
            guard let id = value.taskID else { return false }
            return !value.started && !value.completed && tasks[id]?.events.isEmpty == false
        }) {
            warn("部分 CLI 明细缺少完整启动或退出事件，活动数量可能不完整。")
        }
        for id in activeQueue where tasks[id]?.stage == "处理中" && !tails.values.contains(where: { $0.taskID == id }) {
            warn("处理中的任务尚无 CLI 明细；可能仍在准备或日志缺失，状态待确认。")
        }
        let timing = root.appendingPathComponent("运行状态/耗时日志.jsonl")
        if let info = stamp(timing), info.modified >= since || !activeQueue.isEmpty {
            tail(timing, taskID: nil, fallbackDate: info.modified)
        }
        // Terminal history must never consume the byte budget ahead of live CLI updates.
        var archives: [(URL, String)] = []
        for directory in ["待人工确认", "失败", "发送失败"] {
            archives += children(root.appendingPathComponent(directory)).filter { $0.pathExtension == "json" }.map { ($0, directory) }
        }
        let completed = root.appendingPathComponent("已完成")
        for child in children(completed) {
            if child.pathExtension == "json" { archives.append((child, "已完成")) }
            else {
                archives += children(child).filter { $0.pathExtension == "json" }.map { ($0, "已完成") }
            }
            if archives.count >= 4096 { warn("归档记录较多，部分历史暂未显示。"); break }
        }
        if !archives.isEmpty {
            let begin = archiveOffset % archives.count
            var visited = 0
            while visited < archives.count && readBudget >= Self.maxChunk {
                let entry = archives[(begin + visited) % archives.count]
                observeQueue(entry.0, directory: entry.1)
                visited += 1
            }
            archiveOffset = (begin + max(1, visited)) % archives.count
        }
        // Keep active work ahead of terminal history. All caches, buffers, and histories are bounded.
        let retained = snapshots()
        let retainedIDs = Set(retained.map(\.id))
        tasks = tasks.filter { retainedIDs.contains($0.key) }
        if tails.count > 64 {
            let keys = Set(tails.sorted {
                let leftActive = $0.value.started && !$0.value.completed
                let rightActive = $1.value.started && !$1.value.completed
                if leftActive != rightActive { return leftActive }
                return $0.value.stamp.modified > $1.value.stamp.modified
            }.prefix(64).map(\.key))
            tails = tails.filter { keys.contains($0.key) }
            warn("CLI 日志数量超出观察上限，仅保留最近明细。")
        }
        if objects.count > 512 {
            let keys = Set(objects.sorted { $0.value.stamp.modified > $1.value.stamp.modified }.prefix(512).map(\.key))
            objects = objects.filter { keys.contains($0.key) }
        }
        if directories.count > 256 { directories.removeAll(keepingCapacity: false) }
        if readBudget <= 0 { warn("日志较多，剩余步骤将在下一次刷新继续读取。") }
        return ProgressSnapshot(tasks: retained, warnings: warnings, activeCLICount: activeCLI)
    }

    private var activeCLI: Int { tails.values.filter { $0.taskID != nil && $0.started && !$0.completed }.count }

    private func snapshots() -> [ProgressTask] {
        let activeIDs = Set(tails.values.filter { $0.started && !$0.completed }.compactMap(\.taskID))
        return tasks.values.filter { !$0.events.isEmpty }.sorted {
            let leftPriority = activeIDs.contains($0.id) || activeQueue.contains($0.id) ? 2 : (!$0.terminal ? 1 : 0)
            let rightPriority = activeIDs.contains($1.id) || activeQueue.contains($1.id) ? 2 : (!$1.terminal ? 1 : 0)
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id < $1.id
        }.prefix(20).map {
            ProgressTask(id: $0.id, uid: $0.uid, stage: $0.stage, events: $0.events,
                         isTerminal: $0.terminal, cliActive: activeIDs.contains($0.id))
        }
    }

    private func stamp(_ url: URL) -> Stamp? {
        guard let attributes = try? files.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return nil }
        return Stamp(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                     size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                     modified: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    private func children(_ url: URL) -> [URL] {
        guard let info = stamp(url) else { return [] }
        if let cache = directories[url.path], cache.stamp == info {
            if cache.limited { warn("目录条目超出观察上限，部分历史暂未显示。") }
            return cache.children
        }
        guard let enumerator = files.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
            warn("部分进度目录无法读取，状态可能不完整。")
            return []
        }
        var result: [URL] = []
        var limited = false
        while let child = enumerator.nextObject() as? URL {
            if result.count == 2048 { limited = true; break }
            result.append(child)
        }
        result.sort { $0.lastPathComponent < $1.lastPathComponent }
        directories[url.path] = DirectoryCache(stamp: info, children: result, limited: limited)
        if limited { warn("目录条目超出观察上限，部分历史暂未显示。") }
        return result
    }

    private func smallObject(_ url: URL) -> [String: Any]? {
        guard let info = stamp(url) else { return nil }
        if let cache = objects[url.path], cache.stamp == info {
            if cache.object == nil && info.modified >= since { warn("部分进度记录无法解析，状态未知。") }
            return cache.object
        }
        guard info.size <= UInt64(Self.maxChunk) else {
            if info.modified >= since { warn("进度记录过大，已跳过；状态未知。") }
            return nil
        }
        // Do not attempt decoding a deliberately budget-truncated JSON object.
        guard info.size <= UInt64(max(0, readBudget - reservedForLogs)) else { return nil }
        guard let data = readData(url, maximum: Self.maxChunk),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if info.modified >= since { warn("部分进度记录无法解析，状态未知。") }
            return nil
        }
        // Never retain reply/prompt/reason/error bodies in the object cache.
        let keys = ["task_id", "uid", "history_version", "send_status", "decision", "sent_at", "failed_at", "attempted_at", "marked_at", "created_at", "updated_at", "queued_at", "first_queued_at", "phase"]
        var object: [String: Any] = [:]
        for key in keys { if let value = raw[key] as? String, value.utf8.count <= 1024 { object[key] = value } }
        objects[url.path] = ObjectCache(stamp: info, object: object)
        return object
    }

    private func readData(_ url: URL, maximum: Int) -> Data? {
        guard readBudget > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: min(maximum, readBudget)) else { return nil }
        readBudget -= data.count
        return data
    }

    private func identity(_ object: [String: Any], url: URL) -> (String, String)? {
        guard let uid = object["uid"] as? String, !uid.isEmpty else { return nil }
        if let id = object["task_id"] as? String, !id.isEmpty { return (id, uid) }
        if let version = object["history_version"] as? String {
            return (digest(Data("\(uid):\(version)".utf8)), uid)
        }
        return (url.deletingPathExtension().lastPathComponent, uid)
    }

    private func observeQueue(_ url: URL, directory: String) {
        guard let object = smallObject(url), let (id, uid) = identity(object, url: url) else { return }
        let date = recordDate(object) ?? stamp(url)?.modified ?? Date()
        let terminal = ["已完成", "待人工确认", "失败", "发送失败"].contains(directory)
        guard !terminal || date >= since || tasks[id] != nil else { return }
        if !terminal { activeQueue.insert(id) }
        let stage: String
        if directory == "已完成" {
            if object["send_status"] as? String == "sent" { stage = "已发送" }
            else if object["decision"] as? String == "no_action" { stage = "已完成（不需回复）" }
            else { stage = "已归档（发送状态待确认）"; warn("已归档任务缺少发送确认，不能视为已发送。") }
        } else if object["send_status"] as? String == "uncertain_after_send" { stage = "待人工确认（发送结果不确定）" }
        else { stage = directory }
        let rank = terminal ? 100 : (["待处理": 10, "处理中": 20, "待发送": 60, "发送中": 70][directory] ?? 0)
        add(id: id, uid: uid, date: date, title: stage, detail: "队列记录时间（非此阶段开始时间）", eventID: "queue:\(id):\(stage):\(date.timeIntervalSince1970)", stage: stage, rank: rank, terminal: terminal)
    }

    private func observeAttempt(_ url: URL) {
        guard let object = smallObject(url), object["phase"] as? String == "immediately_before_send_action",
              let (id, uid) = identity(object, url: url) else { return }
        let date = recordDate(object) ?? stamp(url)?.modified ?? .distantPast
        guard date >= since || activeQueue.contains(id) else { return }
        add(id: id, uid: uid, date: date, title: "发送动作前检查已完成", detail: "即将尝试发送；此记录不代表已送达。", eventID: "attempt:\(id):\(date.timeIntervalSince1970)")
    }

    private func traceUID(_ url: URL) -> String? {
        let report = url.deletingPathExtension().appendingPathExtension("txt")
        guard stamp(report) != nil, let data = readData(report, maximum: 8192), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").prefix(6) where line.hasPrefix("UID：") {
            let uid = line.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            if !uid.isEmpty && uid.utf8.count <= 1024 { return uid }
        }
        return nil
    }

    private func tail(_ url: URL, taskID: String?, fallbackDate: Date) {
        guard let info = stamp(url), readBudget > 0 else { return }
        var cursor = tails[url.path] ?? Tail(stamp: info, taskID: taskID)
        if cursor.stamp == info && cursor.offset == info.size {
            if let warning = cursor.warning { warn(warning) }
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { warn("进度日志无法读取，状态未知。"); return }
        defer { try? handle.close() }
        do {
            var reset = cursor.stamp.inode != info.inode || info.size < cursor.offset
            if !reset && cursor.offset > 0 && !cursor.boundary.isEmpty {
                try handle.seek(toOffset: cursor.offset - UInt64(cursor.boundary.count))
                reset = try handle.read(upToCount: cursor.boundary.count) != cursor.boundary
                readBudget -= cursor.boundary.count
            }
            if reset {
                cursor.offset = 0; cursor.pending = Data(); cursor.discarding = false; cursor.boundary = Data()
            }
            // A newly opened very large log starts with a bounded recent window.
            if cursor.offset == 0 && info.size > UInt64(2 * Self.maxChunk) {
                cursor.offset = info.size - UInt64(2 * Self.maxChunk)
                cursor.discarding = true
                cursor.warning = "日志较大，仅展示最近片段；早期步骤可能缺失。"
            }
            try handle.seek(toOffset: cursor.offset)
            let data = try handle.read(upToCount: max(0, min(Self.maxChunk, readBudget))) ?? Data()
            readBudget -= data.count
            cursor.offset += UInt64(data.count)
            cursor.stamp = info
            for byte in data {
                if byte == 10 {
                    if !cursor.discarding && !cursor.pending.isEmpty {
                        if let row = (try? JSONSerialization.jsonObject(with: cursor.pending)) as? [String: Any] {
                            let eventID = "\(url.lastPathComponent):\(digest(cursor.pending))"
                            if let taskID {
                                observeCLI(row, id: taskID, eventID: eventID, fallbackDate: fallbackDate, cursor: &cursor)
                            } else { observeTiming(row, eventID: eventID) }
                        } else { cursor.warning = "部分日志行无法解析；步骤可能缺失，不能据此判断完成。" }
                    }
                    cursor.pending.removeAll(keepingCapacity: true); cursor.discarding = false
                } else if !cursor.discarding {
                    if cursor.pending.count < Self.maxLine { cursor.pending.append(byte) }
                    else {
                        cursor.pending.removeAll(keepingCapacity: true); cursor.discarding = true
                        cursor.warning = "日志行过大已跳过；步骤可能缺失。"
                    }
                }
            }
            if cursor.offset > 0 {
                let size = min(Int(cursor.offset), 64)
                try handle.seek(toOffset: cursor.offset - UInt64(size))
                cursor.boundary = try handle.read(upToCount: size) ?? Data()
                readBudget -= cursor.boundary.count
            }
            if let warning = cursor.warning { warn(warning) }
            tails[url.path] = cursor
        } catch { warn("进度日志读取中断；状态未知，稍后重试。") }
    }

    private func observeCLI(_ row: [String: Any], id: String, eventID: String, fallbackDate: Date, cursor: inout Tail) {
        guard let name = row["event"] as? String, let uid = tasks[id]?.uid else { return }
        let date = parse(row["at"] as? String) ?? fallbackDate
        // Replay old events only when an active queue establishes this task is still relevant.
        guard date >= since || activeQueue.contains(id) || tasks[id]?.events.isEmpty == false else { return }
        var stage: String?
        var rank = 0
        let title: String
        switch name {
        case "process.started": title = "启动 CLI"; cursor.started = true; cursor.completed = false; stage = "CLI 执行中"; rank = 30
        case "thread.started": title = "CLI 会话就绪"
        case "turn.started": title = "开始处理"
        case "turn.completed": title = "本轮生成完成（尚未确认发送）"
        case "turn.failed": title = "CLI 本轮失败（正文不显示）"
        case "error": title = "CLI 报错或重连提示（正文不显示）"
        case "reply.ready": title = "回复已验证，可交接发送"; stage = "回复就绪（CLI 后台收尾）"; rank = 40
        case "process.completed": title = "CLI 已退出（不代表已发送）"; cursor.completed = true; stage = "CLI 已退出，发送状态待确认"; rank = 50
        case "item.started", "item.updated", "item.completed":
            let suffix = name == "item.started" ? "开始" : (name == "item.completed" ? "结束" : "更新")
            switch row["item_type"] as? String {
            case "command_execution": title = "本地命令" + suffix
            case "mcp_tool_call": title = "MCP 工具" + suffix
            case "web_search": title = "网页检索" + suffix
            case "agent_message": title = "回复输出事件（正文不显示）"
            case "reasoning": title = "模型活动事件（非纯思考计时）"
            case "file_change": title = "文件变更事件"
            case "todo_list": title = "任务清单事件"
            case "error": title = "工具错误事件（正文不显示）"
            default: title = "其他 CLI 步骤"
            }
        default: title = "未识别的 CLI 元数据事件"
        }
        var detail: [String] = []
        for (key, label) in [("elapsed_ms", "累计"), ("delta_ms", "距上步"), ("tool_duration_ms", "工具跨度")] {
            if let number = milliseconds(row[key]) { detail.append("\(label) \(seconds(number)) s") }
        }
        if let programs = row["programs"] as? [String] {
            let allowed: Set<String> = ["unzip", "zipinfo", "python3", "python", "rg", "grep", "sed", "cat", "ls"]
            let safe = Array(Set(programs.filter { allowed.contains($0) })).sorted()
            if !safe.isEmpty { detail.append(safe.joined(separator: ", ")) }
        }
        if row["resource"] as? String == "configured_knowledge_base" { detail.append("涉及配置的知识库") }
        if let code = row["exit_code"] as? Int { detail.append("退出码 \(code)") }
        if let category = row["interval_category"] as? String {
            let labels = ["startup": "启动/连接区间", "tool_active": "工具执行区间", "waiting": "等待下一事件（不能区分网络、排队、推理或生成）", "shutdown": "退出收尾区间"]
            if let label = labels[category] { detail.append(label) }
        }
        if let invalid = row["invalid_lines"] as? Int, invalid > 0 { warn("CLI 报告存在无效事件，步骤可能不完整。") }
        if let unfinished = row["unfinished_tools"] as? Int, unfinished > 0 { warn("CLI 报告有工具缺少结束事件，耗时不完整。") }
        add(id: id, uid: uid, date: date, title: title, detail: detail.joined(separator: "；"), eventID: eventID, stage: stage, rank: rank)
    }

    private func observeTiming(_ row: [String: Any], eventID: String) {
        guard let id = row["task_id"] as? String, id.count <= 1024,
              let uid = row["uid"] as? String, !uid.isEmpty, uid.utf8.count <= 1024,
              let date = parse(row["created_at"] as? String), date >= since || activeQueue.contains(id) else { return }
        for (key, title) in [("queue_wait_ms", "排队及启动"), ("prompt_load_ms", "提示词读取"), ("login_check_ms", "登录检查"),
                             ("codex_exec_ms", "Codex 执行至结果可用"), ("decode_ms", "结果解析"), ("publish_ms", "结果发布"), ("task_processing_ms", "任务处理合计")] {
            if let number = milliseconds(row[key]) {
                add(id: id, uid: uid, date: date, title: title, detail: "耗时 \(seconds(number)) s（记录时刻，非步骤开始时刻）", eventID: eventID + ":" + key)
            }
        }
    }

    private func add(id: String, uid: String, date: Date, title: String, detail: String, eventID: String, stage: String? = nil, rank: Int = 0, terminal: Bool = false) {
        var task = tasks[id] ?? TaskState(id: id, uid: uid)
        guard task.uid == uid else { warn("任务 UID 记录不一致，已跳过无法确认的步骤。"); return }
        if !task.events.contains(where: { $0.id == eventID }) {
            task.events.append(ProgressEvent(id: eventID, date: date, title: title, detail: detail))
            task.events.sort { $0.date < $1.date }
            if task.events.count > 200 { task.events.removeFirst(task.events.count - 200) }
        }
        // Downstream queue evidence outranks every CLI event, even late shutdown/errors.
        if let stage, rank > task.rank || (rank == task.rank && date >= task.stageDate) {
            task.stage = stage; task.rank = rank; task.terminal = terminal; task.stageDate = date
        }
        task.date = max(task.date, date)
        tasks[id] = task
        if tasks.count > 64 {
            // Keep the task currently being parsed until its following exit event is consumed.
            let keep = Set(snapshots().map(\.id)).union([id])
            tasks = tasks.filter { keep.contains($0.key) }
        }
    }

    private func recordDate(_ object: [String: Any]) -> Date? {
        for key in ["sent_at", "failed_at", "attempted_at", "marked_at", "created_at", "updated_at", "queued_at", "first_queued_at"] {
            if let value = parse(object[key] as? String) { return value }
        }
        return nil
    }
    private func parse(_ value: String?) -> Date? {
        guard let value, value.utf8.count < 100 else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
    private func milliseconds(_ value: Any?) -> Double? {
        guard let number = value as? Double, number.isFinite, number >= 0, number < 1e12 else { return nil }
        return number
    }
    private func seconds(_ value: Double) -> String { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value / 1000) }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func warn(_ message: String) { if warnings.count < 8 && !warnings.contains(message) { warnings.append(message) } }
}
