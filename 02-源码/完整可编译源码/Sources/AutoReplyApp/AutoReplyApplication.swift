import AppKit
import SwiftUI
import AutoReplyCore

@main struct AutoReplyApplication: App {
    @NSApplicationDelegateAdaptor(AutomationAppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AutomationAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AutomationAppModel?
    private var panel: NSPanel?
    private var progressPanel: AutoReplyProgressPanelController?
    private var quitTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let model = try AutomationAppModel.live(); self.model = model
            let panel = NSPanel(contentRect: NSRect(x: 80, y: 100, width: 620, height: 680),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = AppIdentity.displayName
            panel.isFloatingPanel = false; panel.level = .normal; panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true; panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 540, height: 500)
            panel.delegate = self
            let progress = AutoReplyProgressPanelController(model: model)
            progressPanel = progress
            panel.contentView = NSHostingView(rootView: AutomationRootView(model: model,
                toggleProgress: progress.toggleCollapsed, updateProgressInteraction: progress.updateInteraction))
            self.panel = panel
            panel.center(); panel.orderFrontRegardless(); progress.show()
        } catch {
            let alert = NSAlert(); alert.messageText = "全自动客服未启动"
            alert.informativeText = error.localizedDescription; alert.runModal()
            NSApp.terminate(nil)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Explicit user request only, never a timer/update activation.
        panel?.orderFrontRegardless(); return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.quitRequested = true; model.prepareForTermination()
        guard !model.mayQuit else { return .terminateNow }
        model.message = "正在安全退出：等待 UI 操作和 CLI 清理结束；会话锁保持占用"
        if quitTask == nil {
            quitTask = Task { [weak self] in
                while let model = self?.model, !model.mayQuit {
                    try? await Task.sleep(for: .milliseconds(250))
                    model.refresh()
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

private struct AutomationRootView: View {
    @ObservedObject var model: AutomationAppModel
    let toggleProgress: () -> Void
    let updateProgressInteraction: () -> Void

    var body: some View {
        if let firstRun = model.firstRun,
           let viewModel = model.firstRunViewModel,
           firstRun.phase != .readOnlyReady,
           firstRun.phase != .running {
            FirstRunView(model: model, coordinator: firstRun, viewModel: viewModel)
        } else {
            AutomationStatusView(
                model: model,
                toggleProgress: toggleProgress,
                updateProgressInteraction: updateProgressInteraction
            )
        }
    }
}

struct AutomationStatusView: View {
    @ObservedObject var model: AutomationAppModel
    let toggleProgress: () -> Void
    let updateProgressInteraction: () -> Void
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    static func videoStatusText(from controller: VideoDetectionNoticeController) -> String {
        controller.videoFlowText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("千牛全自动客服").font(.title2.bold())
            Text(model.message).font(.callout).foregroundStyle(model.scheduler.isRunning ? .green : .secondary)
            Text(model.knowledgeRetrievalStatusText)
                .font(.caption)
                .foregroundStyle(model.knowledgeRetrievalStatusText.contains("恢复中") ? .orange : .secondary)
            VideoProcessingStatusCard(
                controller: model.videoDetectionNotice,
                downloadStatus: model.videoStatus
            )
            HStack {
                Button("开始") { model.start(); updateProgressInteraction() }
                    .disabled(model.scheduler.isRunning || !model.mayQuit || model.quitRequested)
                Button("停止") { model.stop(); updateProgressInteraction() }.disabled(!model.scheduler.isRunning)
                Button("收起／展开浮窗", action: toggleProgress)
                Spacer()
            }
            Text("全部客户模式：会自动生成并发送回复")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                Text("客服名称")
                TextField("例如：小丹、小秦、小艳", text: Binding(
                    get: { model.serviceAliasesText },
                    set: model.setServiceAliasesText
                ))
                .disabled(model.quitRequested)
                Button("应用名称") { model.applyServiceAliases() }
                    .disabled(model.quitRequested)
            }
            Text("多个名称可用逗号或换行分隔；运行中修改后点击“应用名称”，从下一次扫描开始生效。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("UI：\(model.driver.currentUIOwner ?? "空闲")")
                Spacer()
                Text("CLI：\(model.scheduler.liveGenerationCount) / \(model.scheduler.generationCapacity)")
            }.font(.callout.monospaced())
            permissionRow("辅助功能", granted: model.accessibility, request: AutomationPermissions.requestAccessibility, accessibility: true)
            permissionRow("屏幕录制", granted: model.screenCapture, request: AutomationPermissions.requestScreenCapture, accessibility: false)
            if model.scheduler.status != "Running" && model.scheduler.status != "Stopped" {
                Text(model.scheduler.status).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Divider()
            Text("客户阶段").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(AutoReplyProgressPresentation.customerStageRecords(
                        model.scheduler.records
                    ).prefix(100)) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(record.uid).bold(); Spacer(); Text(stageName(record.state)) }
                            Text("#\(record.sequence) · \(record.updatedAt.formatted(date: .omitted, time: .standard)) · 重试 \(record.retries)")
                                .font(.caption).foregroundStyle(.secondary)
                            if let stage = model.stages[record.uid], record.state == .capturing { Text(stage).font(.caption) }
                            if let error = record.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                        }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if AutoReplyProgressPresentation.customerStageRecords(model.scheduler.records).isEmpty {
                        Text("暂无进行中的任务；警告已记入下方历史。").foregroundStyle(.secondary)
                    }
                }
            }.frame(minHeight: 130)
            Divider()
            Text("阶段与耗时").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array((model.scheduler.events + model.nativeEvents).sorted { $0.date > $1.date }.prefix(100).enumerated()), id: \.offset) { _, event in
                        Text("\(event.date.formatted(date: .omitted, time: .standard))  \(event.uid ?? "调度器")  \(event.message)")
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 130)
        }.padding(16).onReceive(refresh) { _ in model.refresh(); updateProgressInteraction() }
    }
    private func permissionRow(_ title: String, granted: Bool, request: @escaping () -> Void, accessibility: Bool) -> some View {
        HStack {
            Label("\(title)：\(granted ? "已授权" : "未授权")", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Spacer()
            Button("请求权限", action: request).disabled(granted || model.scheduler.isRunning || !model.mayQuit)
            Button("系统设置") { AutomationPermissions.openSettings(accessibility: accessibility) }
                .disabled(model.scheduler.isRunning || !model.mayQuit)
        }.font(.caption)
    }
    private func stageName(_ state: SchedulerJobState) -> String {
        switch state {
        case .discovered: "待采集"; case .capturing: "采集中"; case .queued: "等待 CLI"
        case .generating: "生成中"; case .ready: "回复就绪"; case .sending: "发送核验中"
        case .completed: "已完成"; case .superseded: "被新消息替代"; case .failed: "失败"
        case .parked: "失败区"
        case .uncertain: "发送结果待核对"
        }
    }
}

private struct VideoProcessingStatusCard: View {
    @ObservedObject var controller: VideoDetectionNoticeController
    let downloadStatus: String

    private var accent: Color {
        if controller.videoFlowText.contains("已提取") { return .green }
        if controller.videoFlowText.contains("正在") || controller.videoFlowText.contains("●") { return .blue }
        if controller.videoFlowText.contains("未完成") { return .orange }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "video.fill")
                .foregroundStyle(accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("视频处理")
                    .font(.caption.bold())
                Text(AutomationStatusView.videoStatusText(from: controller))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                Text(downloadStatus)
                    .font(.caption.bold())
                    .foregroundStyle(downloadStatus == "下载完成" ? .green : .blue)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("视频处理")
        .accessibilityValue("\(AutomationStatusView.videoStatusText(from: controller))；\(downloadStatus)")
    }
}
