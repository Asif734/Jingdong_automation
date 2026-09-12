import SwiftUI
import UnreadCore

private actor JournalFeed {
    private let reader: ProgressJournalReader
    init(root: URL, since: Date) { reader = ProgressJournalReader(root: root, since: since) }
    func read() -> ProgressSnapshot { reader.read() }
}

@MainActor final class ProgressDisplayModel: ObservableObject {
    @Published private(set) var tasks: [ProgressTask] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var activeCLICount = 0
    @Published private(set) var localEvents: [ProgressEvent] = []
    @Published private(set) var localHeadline = "等待手动启动；浮窗不会扫描或发送消息"
    @Published private(set) var localUID: String?
    @Published private(set) var runStarted: Date?
    @Published private(set) var runEnded: Date?
    @Published private(set) var lookupBusy = false
    @Published private(set) var ocrActive = false
    @Published private(set) var ocrWarning: String?
    @Published var collapsed = false
    @Published var selectedTaskID = ""
    @Published var scrollTarget = "end"
    @Published var scrollRequest = 0
    @Published private(set) var hasFreshSnapshot = false
    private let feed: JournalFeed
    private var polling: Task<Void, Never>?
    private var pollGeneration: UUID?
    private var tracker: OCRProgressTracker?
    private var armedAt: Date?
    private var observing = false

    init(root: URL, since: Date = Date()) { feed = JournalFeed(root: root, since: since) }

    var isAutomationActive: Bool {
        lookupBusy || ocrActive || tasks.contains { !$0.isTerminal || $0.cliActive }
    }
    var isOverlayReadOnly: Bool { !hasFreshSnapshot || isAutomationActive }
    var headline: String {
        if lookupBusy || ocrActive { return localHeadline }
        if let task = tasks.first(where: { !$0.isTerminal }) { return "\(task.uid) · \(task.stage)" }
        if let task = tasks.filter({ $0.isTerminal }).max(by: {
            ($0.events.last?.date ?? .distantPast) < ($1.events.last?.date ?? .distantPast)
        }), task.cliActive || runStarted == nil || (task.events.last?.date ?? .distantPast) >= Date(timeIntervalSince1970: floor(runStarted!.timeIntervalSince1970)) {
            return "\(task.uid) · \(task.stage)" + (task.cliActive ? " · CLI 后台收尾" : "")
        }
        if activeCLICount > 0 { return "CLI 尚未观测到退出；请查看任务详情" }
        return localHeadline
    }
    func beginRun() {
        runStarted = Date(); runEnded = nil; localUID = nil
        tracker = nil; armedAt = nil; ocrActive = false; ocrWarning = nil
        localEvents = []; lookupBusy = true
        record("开始本次查找", detail: "仅按原有流程执行一次；浮窗只读观察")
    }
    func record(_ title: String, detail: String = "") {
        localHeadline = title
        guard localEvents.last?.title != title || localEvents.last?.detail != detail else { return }
        localEvents.append(ProgressEvent(id: UUID().uuidString, date: Date(), title: title, detail: detail))
        if localEvents.count > 100 { localEvents.removeFirst(localEvents.count - 100) }
    }
    func arm(uid: String, baseline: OCRStatusSample?) {
        localUID = uid; tracker = OCRProgressTracker(uid: uid, baseline: baseline)
        armedAt = Date(); ocrActive = true
        record("已核对用户，准备触发一期版", detail: "客户：\(uid)；已隔离旧界面结果")
    }
    func finishLookup(noTarget: Bool) {
        lookupBusy = false
        if noTarget {
            ocrActive = false; tracker = nil; runEnded = Date()
            record("未发现未读目标 · 本次结束，未触发一期版")
        } else if ocrActive {
            record("已触发一期版识别一次", detail: "等待新的界面状态或入队事件；不会重复点击")
        }
    }
    func failLookup(_ message: String) {
        lookupBusy = false; ocrActive = false; tracker = nil; runEnded = Date()
        record("查找／交接停止：\(message)", detail: "此状态不代表其他客户任务已停止")
    }
    func receiveOCR(_ sample: OCRStatusSample) {
        guard var current = tracker else { return }
        let step = current.observe(sample)
        tracker = current
        guard let step else { return }
        record(step.title, detail: step.detail)
        if step.isTerminal {
            ocrActive = false; runEnded = Date(); tracker = nil
            if step.noNewMessages { record("没有新消息 · 本次结束，未入队") }
            else if !step.isError { record("一期版识别结束", detail: "后续按下方实际队列／发送记录展示；识别结束不等于已发送") }
        }
    }
    func apply(_ snapshot: ProgressSnapshot) {
        if tasks != snapshot.tasks { tasks = snapshot.tasks }
        if warnings != snapshot.warnings { warnings = snapshot.warnings }
        if activeCLICount != snapshot.activeCLICount { activeCLICount = snapshot.activeCLICount }
        let readable = !snapshot.warnings.contains { $0.hasPrefix("进度目录不可读") }
        if hasFreshSnapshot != readable { hasFreshSnapshot = readable }
        if !selectedTaskID.isEmpty && !tasks.contains(where: { $0.id == selectedTaskID }) { selectedTaskID = "" }
    }
    func startMonitoring() {
        observing = true
        guard polling == nil || polling?.isCancelled == true else { return }
        hasFreshSnapshot = false
        let generation = UUID()
        pollGeneration = generation
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let snapshot = await self.feed.read()
                guard !Task.isCancelled else { break }
                self.apply(snapshot)
                if self.ocrActive {
                    let reading = PhaseOneStatusReader.read()
                    self.ocrWarning = reading.warning
                    if let sample = reading.sample { self.receiveOCR(sample) }
                    if let armedAt = self.armedAt, Date().timeIntervalSince(armedAt) > 60, self.ocrActive {
                        self.ocrActive = false; self.tracker = nil; self.runEnded = Date()
                        self.record("一期版状态未确认", detail: "60 秒未观测到对应识别结束；仅停止界面采样，业务照常运行，请查看一期版。")
                    }
                }
                if !self.observing && !self.lookupBusy && !self.ocrActive { break }
                do { try await Task.sleep(for: .milliseconds(700)) } catch { break }
            }
            if self?.pollGeneration == generation { self?.polling = nil }
        }
    }
    func hideMonitoring() {
        observing = false
        // Finish observing this OCR handoff when hidden, but do not keep polling completed work.
        if !lookupBusy && !ocrActive { polling?.cancel() }
    }
}
