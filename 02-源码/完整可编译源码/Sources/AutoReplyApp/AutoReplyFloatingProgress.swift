import AppKit
import SwiftUI
import AutoReplyCore
import QianniuOCRAppSupport

@MainActor final class AutoReplyFloatingProgressPanel: NSPanel {
    private var automationActive = false
    private var titleDragArmed = false
    private var mouseTrackingTimer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 530),
                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "AI 客服 · 实时进度"
        level = .floating
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        minSize = NSSize(width: 380, height: 150)
        setFrameAutosaveName("AutoReplyProgressFloat")
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTrackingTimer = timer
    }
    deinit { mouseTrackingTimer?.invalidate() }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func setReadOnly(_ readOnly: Bool) {
        automationActive = readOnly
        updateMousePassthrough()
    }

    static func shouldIgnoreMouse(cursor: CGPoint, pressedButtons: Int, frame: CGRect,
                                  automationActive: Bool, titleDragArmed: Bool) -> Bool {
        guard automationActive else { return false }
        let titlebar = CGRect(x: frame.minX, y: frame.maxY - 32, width: frame.width, height: 32)
        return !titlebar.contains(cursor) && !(pressedButtons != 0 && titleDragArmed)
    }

    private func updateMousePassthrough() {
        let cursor = NSEvent.mouseLocation
        let pressed = NSEvent.pressedMouseButtons
        let titlebar = CGRect(x: frame.minX, y: frame.maxY - 32, width: frame.width, height: 32)
        if pressed == 0 { titleDragArmed = titlebar.contains(cursor) }
        ignoresMouseEvents = Self.shouldIgnoreMouse(cursor: cursor, pressedButtons: pressed,
            frame: frame, automationActive: automationActive, titleDragArmed: titleDragArmed)
    }
}

enum AutoReplyProgressPresentation {
    static func customerStageRecords(_ records: [SchedulerRecord]) -> [SchedulerRecord] {
        records
            .sorted { $0.sequence > $1.sequence }
    }

    static func taskDetails(_ record: SchedulerRecord, now: Date = Date()) -> [String] {
        var details: [String] = []
        if let revision = record.customerRevision, !revision.isEmpty {
            details.append("版本 \(String(revision.prefix(12)))")
        }
        if let attempt = record.stageAttempt {
            details.append("阶段 \(attempt.stage)")
            if let startedAt = attempt.startedAt {
                details.append(String(format: "已用 %.1fs", max(0, now.timeIntervalSince(startedAt))))
            }
            if let deadlineAt = attempt.deadlineAt {
                details.append(String(format: "剩余 %.1fs", max(0, deadlineAt.timeIntervalSince(now))))
            }
        }
        details.append("重试 \(record.retries)")
        if let reason = record.parkedReason ?? record.lastError, !reason.isEmpty {
            details.append(reason)
        }
        return details
    }

    static func headline(isRunning: Bool, currentUIOwner: String?, stages: [String: String],
                         records: [SchedulerRecord], liveGenerationCount: Int,
                         generationCapacity: Int) -> String {
        guard isRunning else { return "自动客服已停止" }
        if let uid = currentUIOwner {
            return "\(uid) · \(stages[uid] ?? "正在操作千牛界面")"
        }
        let active = records.filter { !$0.state.isTerminal }.min { lhs, rhs in
            let left = priority(lhs.state), right = priority(rhs.state)
            return left == right ? lhs.sequence < rhs.sequence : left < right
        }
        if let active {
            let stage = stageName(active.state)
            if active.state == .generating {
                let session = active.sessionStage.map { " · \($0)" } ?? ""
                return "\(active.uid) · \(stage)\(session) · CLI \(liveGenerationCount)/\(generationCapacity)"
            }
            return "\(active.uid) · \(stage)"
        }
        if liveGenerationCount > 0 { return "AI 后台处理中 · CLI \(liveGenerationCount)/\(generationCapacity)" }
        return "扫描当前可见红点 · 每 1 秒"
    }

    static func stageName(_ state: SchedulerJobState) -> String {
        switch state {
        case .discovered: "等待打开客户"
        case .capturing: "OCR 正在读取消息"
        case .queued: "等待 CLI 空位"
        case .generating: "AI 正在生成回复"
        case .ready: "回复就绪，等待发送"
        case .sending: "正在发送并回读确认"
        case .completed: "已完成"
        case .superseded: "已被客户新消息替代"
        case .failed: "历史失败记录"
        case .parked: "本次任务已移入失败区"
        case .uncertain: "发送结果待核对"
        }
    }

    private static func priority(_ state: SchedulerJobState) -> Int {
        switch state {
        case .sending: 0; case .ready: 1; case .capturing: 2; case .discovered: 3
        case .generating: 4; case .queued: 5
        case .completed, .superseded, .failed, .parked, .uncertain: 6
        }
    }
}

@MainActor final class AutoReplyProgressLayout: ObservableObject {
    @Published var collapsed = false
}

@MainActor final class VideoDetectionNoticeController: ObservableObject {
    @Published private(set) var text: String?
    @Published private(set) var videoFlowText = "视频流程：等待 messageType=105"

    private let displayDuration: Duration
    private var clearTask: Task<Void, Never>?
    private var seenMessageIDs = Set<String>()
    private var seenOrder: [String] = []
    private let maximumRememberedMessages = 512

    init(displayDuration: Duration = .seconds(1)) {
        self.displayDuration = displayDuration
    }

    deinit { clearTask?.cancel() }

    func show(messageID: String) {
        guard !messageID.isEmpty, seenMessageIDs.insert(messageID).inserted else { return }
        seenOrder.append(messageID)
        if seenOrder.count > maximumRememberedMessages {
            let overflow = seenOrder.count - maximumRememberedMessages
            let expired = seenOrder.prefix(overflow)
            seenMessageIDs.subtract(expired)
            seenOrder.removeFirst(overflow)
        }

        clearTask?.cancel()
        text = "检测到视频"
        clearTask = Task { [weak self, displayDuration] in
            try? await Task.sleep(for: displayDuration)
            guard !Task.isCancelled else { return }
            self?.text = nil
        }
    }

    func advanceVideoFlow(_ phase: VideoOpenProgressPhase) {
        switch phase {
        case .detected:
            videoFlowText = "视频流程：✓ 105 → ○ 打开 → ○ 发起下载 → ○ 关窗 → ○ 继续扫描"
        case .opening:
            videoFlowText = "视频流程：✓ 105 → ● 打开 → ○ 发起下载 → ○ 关窗 → ○ 继续扫描"
        case .downloadRequested:
            videoFlowText = "视频流程：✓ 105 → ✓ 打开 → ● 发起下载 → ○ 关窗 → ○ 继续扫描"
        case .closingPlayer:
            videoFlowText = "视频流程：✓ 105 → ✓ 打开 → ✓ 发起下载 → ● 关窗 → ○ 继续扫描"
        case .resumedScanning:
            videoFlowText = "视频流程：✓ 105 → ✓ 打开 → ✓ 发起下载 → ✓ 关窗 → ✓ 继续扫描"
        }
    }

    func showDownloadCompleted(messageID: String, bytes: Int, elapsed: TimeInterval) {
        let megabytes = Double(bytes) / 1_000_000
        videoFlowText = String(
            format: "视频下载完成：%@ · %.2f MB · %.1f 秒",
            locale: Locale(identifier: "en_US_POSIX"),
            messageID,
            megabytes,
            max(0, elapsed)
        )
    }

    func showFrameExtractionStarted(messageID: String) {
        videoFlowText = "视频处理：\(messageID) · 正在抽帧、保存音轨并转写语音"
    }

    func showFrameExtractionCompleted(
        messageID: String,
        frameCount: Int,
        audioSaved: Bool,
        transcriptSegmentCount: Int = 0
    ) {
        let audioStatus = audioSaved ? "音轨已保存" : "视频没有可保存音轨"
        let transcriptStatus = transcriptSegmentCount > 0
            ? "语音已转写 \(transcriptSegmentCount) 段"
            : "未识别到有效语音"
        videoFlowText = "视频处理：\(messageID) · 已提取 \(frameCount) 帧 · \(audioStatus) · \(transcriptStatus)"
    }

    func showFrameExtractionFailed(messageID: String) {
        videoFlowText = "视频处理：\(messageID) · 抽帧未完成；扫描继续"
    }

    func showVideoReplyQueued(messageID: String) {
        if videoFlowText.hasPrefix("视频处理：\(messageID)") {
            videoFlowText += " · 已提交 AI 回复"
        } else {
            videoFlowText = "视频处理：\(messageID) · 已提交 AI 回复"
        }
    }
}

@MainActor final class AutoReplyProgressPanelController: NSObject, NSWindowDelegate {
    private let model: AutomationAppModel
    private let layout = AutoReplyProgressLayout()
    private var panel: AutoReplyFloatingProgressPanel?

    init(model: AutomationAppModel) { self.model = model }

    func show() {
        if panel == nil {
            let window = AutoReplyFloatingProgressPanel()
            window.delegate = self
            let hosting = NSHostingView(rootView: AutoReplyProgressPanelView(model: model, layout: layout))
            hosting.sizingOptions = []
            window.contentView = hosting
            if !window.setFrameUsingName("AutoReplyProgressFloat"), let frame = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.maxX - 480, y: frame.maxY - 560))
            }
            panel = window
        }
        updateInteraction()
        keepVisible()
        panel?.orderFrontRegardless()
    }

    func toggleCollapsed() {
        guard panel != nil else { show(); return }
        layout.collapsed.toggle()
        guard let panel else { return }
        var frame = panel.frame
        let height: CGFloat = layout.collapsed ? 175 : 550
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
        keepVisible()
        panel.orderFrontRegardless()
    }

    private func keepVisible() {
        guard let panel, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }),
              let screen = NSScreen.main else { return }
        panel.setFrame(panel.constrainFrameRect(panel.frame, to: screen), display: true)
    }

    func updateInteraction() {
        // While the scheduler is running, the overlay must never intercept a
        // Qianniu click. It remains interactive and movable after Stop.
        panel?.setReadOnly(model.scheduler.isRunning)
    }

    func windowWillClose(_ notification: Notification) { panel = nil }
}

private struct AutoReplyProgressPanelView: View {
    @ObservedObject var model: AutomationAppModel
    @ObservedObject var layout: AutoReplyProgressLayout
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var headline: String {
        AutoReplyProgressPresentation.headline(isRunning: model.scheduler.isRunning,
            currentUIOwner: model.driver.currentUIOwner, stages: model.stages,
            records: model.scheduler.records, liveGenerationCount: model.scheduler.liveGenerationCount,
            generationCapacity: model.scheduler.generationCapacity)
    }
    private var events: [SchedulerEvent] {
        Array((model.scheduler.events + model.nativeEvents).sorted { $0.date > $1.date }.prefix(100))
    }
    private var activeRecords: [SchedulerRecord] {
        Array(model.scheduler.records.filter {
            ![.completed, .superseded, .failed].contains($0.state)
        }.sorted { $0.sequence < $1.sequence }.prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.scheduler.isRunning ? Color.blue : Color.gray).frame(width: 8, height: 8)
                Text("全链路进度").font(.headline)
                Spacer()
                Text("CLI \(model.scheduler.liveGenerationCount)/\(model.scheduler.generationCapacity) · 排队 \(model.scheduler.queuedGenerationCount)")
                    .font(.caption).monospacedDigit()
            }
            Text(headline).font(.system(size: 13, weight: .medium)).lineLimit(3)
            Text(model.knowledgeRetrievalStatusText)
                .font(.system(size: 10))
                .foregroundStyle(model.knowledgeRetrievalStatusText.contains("恢复中") ? .orange : .secondary)
            VideoFlowProgressLine(controller: model.videoDetectionNotice)
            Text(model.videoStatus)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.videoStatus == "下载完成" ? .green : .blue)
            Text(model.scheduler.isRunning ? "鼠标穿透 · 不影响千牛自动操作" : "已停止 · 可拖动标题栏调整位置")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !layout.collapsed {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(activeRecords) { record in
                            AutoReplyProgressTaskCard(record: record)
                        }
                        if activeRecords.isEmpty {
                            Text(model.scheduler.isRunning ? "当前没有排队客户，继续扫描可见红点。" : "当前没有运行中的客户任务。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                            AutoReplyProgressEventRow(event: event)
                        }
                        if events.isEmpty { Text("尚无步骤记录。").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.trailing, 4)
                }
                Text("只读显示 · 数据直接来自当前调度器，不额外扫描千牛")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            VideoDetectionNoticeOverlay(controller: model.videoDetectionNotice)
        }
        .onReceive(refresh) { _ in model.refresh() }
    }
}

private struct VideoDetectionNoticeOverlay: View {
    @ObservedObject var controller: VideoDetectionNoticeController

    var body: some View {
        if let notice = controller.text {
            ZStack {
                Color.black.opacity(0.92)
                Text(notice)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct VideoFlowProgressLine: View {
    @ObservedObject var controller: VideoDetectionNoticeController

    var body: some View {
        Text(controller.videoFlowText)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

private struct AutoReplyProgressTaskCard: View {
    let record: SchedulerRecord
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.uid).font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Text("#\(record.sequence)").font(.caption).foregroundStyle(.secondary)
                }
                Text(AutoReplyProgressPresentation.stageName(record.state)).font(.caption).foregroundStyle(.blue)
                if let sessionStage = record.sessionStage {
                    Text(sessionStage).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ForEach(AutoReplyProgressPresentation.taskDetails(record), id: \.self) { detail in
                    Text(detail).font(.system(size: 10))
                        .foregroundStyle(detail == record.parkedReason || detail == record.lastError ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("最近更新 \(record.updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AutoReplyProgressEventRow: View {
    let event: SchedulerEvent
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"; return formatter
    }()
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.formatter.string(from: event.date)).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 77, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let uid = event.uid { Text(uid).font(.system(size: 10, weight: .semibold)) }
                Text(event.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
