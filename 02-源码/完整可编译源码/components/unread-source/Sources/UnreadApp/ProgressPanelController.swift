import SwiftUI
import AppKit
import UnreadCore

@MainActor final class ProgressPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var visible = false
    let model: ProgressDisplayModel
    private var panel: FloatingProgressPanel?

    init(model: ProgressDisplayModel = ProgressDisplayModel(root: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent("AI客服记录"))) {
        self.model = model
        super.init()
    }

    func show() {
        if panel == nil {
            let window = FloatingProgressPanel()
            window.delegate = self
            let hosting = NSHostingView(rootView: ProgressPanelView(model: model, toggle: { [weak self] in self?.toggleCollapsed() }))
            // Keep a small user-sized float; long timelines scroll instead of forcing a tall window.
            hosting.sizingOptions = []
            window.contentView = hosting
            if !window.setFrameUsingName("CustomerServiceProgressFloat"), let frame = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.maxX - 480, y: frame.maxY - 560))
            }
            panel = window
        }
        model.startMonitoring()
        panel?.setAutomationActive(model.isOverlayReadOnly)
        panel?.orderFrontRegardless()
        visible = true
    }
    func hide() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        visible = false
        model.hideMonitoring()
    }
    func updateInteraction() { panel?.setAutomationActive(model.isOverlayReadOnly) }
    func toggleCollapsed() {
        model.collapsed.toggle()
        guard let panel else { return }
        var frame = panel.frame
        let height: CGFloat = model.collapsed ? 175 : 550
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
    }
}

private struct ProgressPanelView: View {
    @ObservedObject var model: ProgressDisplayModel
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(model.isAutomationActive ? Color.blue : Color.green).frame(width: 8, height: 8)
                Text("全链路进度").font(.headline)
                Spacer()
                Text("CLI \(model.activeCLICount)/5").font(.caption).monospacedDigit()
                Button(model.collapsed ? "展开详情" : "收起详情", action: toggle).font(.caption)
            }
            Text(model.headline).font(.system(size: 13, weight: .medium)).lineLimit(3)
            Text(model.isOverlayReadOnly ? "鼠标穿透 · 可在未读助手切换客户／回看步骤" : "拖动标题栏可移动 · 关闭浮窗不停止业务")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !model.collapsed {
                Divider()
                ScrollViewReader { proxy in
                  ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Color.clear.frame(height: 1).id("start")
                        if !model.localEvents.isEmpty && model.selectedTaskID.isEmpty {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("本次查找／识别 · \(model.localUID ?? "待核对客户")").font(.subheadline.bold())
                                    if let start = model.runStarted {
                                        TimelineView(.periodic(from: .now, by: 1)) { context in
                                            Text("观测用时 \(String(format: "%.1f", (model.runEnded ?? context.date).timeIntervalSince(start))) 秒")
                                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                    }
                                    ForEach(model.localEvents) { event in EventRow(event: event) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ForEach(model.tasks.filter { model.selectedTaskID.isEmpty || $0.id == model.selectedTaskID }) { task in TaskProgressCard(task: task) }
                        if model.tasks.isEmpty {
                            Text("尚未观察到新队列任务。旧的完成记录不会冒充本次进度。")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        if let warning = model.ocrWarning {
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }.padding(.trailing, 4)
                  }
                  .onChange(of: model.scrollRequest) { _, _ in proxy.scrollTo(model.scrollTarget, anchor: model.scrollTarget == "end" ? .bottom : .top) }
                  .onChange(of: model.selectedTaskID) { _, _ in proxy.scrollTo("start", anchor: .top) }
                }
                Text("只读观察 · 界面约0.7秒采样，快速步骤可能漏采；等待不等于纯思考耗时。只有发送器的成功记录才显示发送成功。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.isOverlayReadOnly) { _, active in
            // Find only our window via its hosting view is unnecessary: controller owns this callback.
            for window in NSApp.windows where window is FloatingProgressPanel {
                (window as? FloatingProgressPanel)?.setAutomationActive(active)
            }
        }
    }
}

/// Controls remain available in the ordinary helper window while the overlay passes clicks through.
struct ProgressControls: View {
    @ObservedObject var model: ProgressDisplayModel
    let toggle: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("浮窗客户", selection: $model.selectedTaskID) {
                Text("全部客户／本次识别").tag("")
                ForEach(model.tasks) { task in Text("\(task.uid) · \(task.id.prefix(6))").tag(task.id) }
            }.frame(maxWidth: 470)
            HStack {
                Button(model.collapsed ? "展开详情" : "收起详情", action: toggle)
                Button("最早步骤") { model.scrollTarget = "start"; model.scrollRequest += 1 }
                Button("最新步骤") { model.scrollTarget = "end"; model.scrollRequest += 1 }
            }
        }.font(.caption)
    }
}

private struct TaskProgressCard: View {
    let task: ProgressTask
    @State private var expanded = true
    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("任务 \(task.id.prefix(12)) · \(task.cliActive ? "CLI 未观测到退出" : "CLI 无活动记录")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let last = task.events.last, !task.isTerminal {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("距最近事件 \(max(0, Int(context.date.timeIntervalSince(last.date)))) 秒；等待新进度")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    ForEach(task.events) { event in EventRow(event: event) }
                }.padding(.top, 6)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.uid).font(.subheadline.bold()).lineLimit(2)
                    Text(task.stage).font(.caption).foregroundStyle(color)
                }
            }
        }
    }
    private var color: Color {
        if task.stage.contains("失败") || task.stage.contains("人工") || task.stage.contains("不确定") { return .orange }
        return task.isTerminal ? .green : .blue
    }
}

private struct EventRow: View {
    let event: ProgressEvent
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"; return formatter
    }()
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.formatter.string(from: event.date)).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 77, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if !event.detail.isEmpty {
                    Text(event.detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
