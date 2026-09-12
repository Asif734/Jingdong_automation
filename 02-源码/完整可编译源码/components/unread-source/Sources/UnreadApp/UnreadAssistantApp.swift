import SwiftUI
import UnreadCore

@main struct UnreadAssistantApp: App {
    @StateObject private var progress = ProgressPanelController()
    var body: some Scene {
        Window("千牛未读助手", id: "unread-assistant") { AssistantView(progress: progress) }
            .defaultSize(width: 520, height: 280)
            .windowResizability(.contentSize)
    }
}
private struct AssistantView: View {
    @ObservedObject var progress: ProgressPanelController
    @State private var busy = false
    @State private var status = "检查可见列表红点，核对用户后触发一期版识别一次。"
    @State private var found = "—"
    @State private var verified = "—"
    @State private var elapsed = "—"
    @State private var hasPending = false
    private let pending = PendingHandoff(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QianniuUnreadAssistant/pending-handoff.json"))
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("千牛未读助手").font(.title2.bold())
            Text("一次处理一个目标 · 不后台运行 · 回复由一期版处理").foregroundStyle(.secondary)
            Button(action: run) {
                Text(busy ? "检查中…" : "查找并打开")
                    .font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(busy ? Color.gray : Color.blue, in: RoundedRectangle(cornerRadius: 8))
            }.disabled(busy).buttonStyle(.plain)
            Text(status).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("发现 ID：\(found)").textSelection(.enabled)
            Text("已核对 ID：\(verified)").textSelection(.enabled)
            Text("用时：\(elapsed)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("显示进度浮窗") { progress.show() }
                if progress.visible { Button("隐藏进度浮窗") { progress.hide() } }
            }
            ProgressControls(model: progress.model, toggle: { progress.toggleCollapsed() })
            if hasPending {
                Text("已保留待处理客户；下次点击将继续核对。若已尝试触发，则先查看一期版确认结果。").font(.caption)
                Button("已核对／放弃本次，清除待处理标记") {
                    do { try pending.clear(); hasPending = false; status = "待处理标记已清除；未触发识别。" }
                    catch { status = error.localizedDescription }
                }.disabled(busy)
            }
            HStack(spacing: 18) {
                Link("辅助功能设置", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                Link("屏幕录制设置", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }.font(.caption)
        }.padding(24).frame(width: 520, alignment: .leading)
            .onAppear { hasPending = (try? pending.load() != nil) ?? true; progress.show() }
    }
    private func run() {
        guard !busy else { return }
        busy = true; found = "—"; verified = "—"; elapsed = "—"
        progress.model.beginRun()
        progress.show()
        progress.updateInteraction()
        let started = Date()
        Task { @MainActor in
            defer { busy = false; hasPending = (try? pending.load() != nil) ?? true; elapsed = String(format: "%.2f 秒", Date().timeIntervalSince(started)) }
            do {
                let session = NativeSession()
                let outcome = try await OpenWorkflow.run(session: session, pending: pending, status: { message in
                    status = message
                    progress.model.record(message)
                    if message.hasPrefix("发现：") { found = String(message.dropFirst(3)) }
                }, beforeClick: {
                    try PhaseOneLink.checkIdleIfRunning()
                }, afterVerified: { uid in
                    verified = uid
                    status = "已核对用户，正在触发一期版…"
                    progress.model.arm(uid: uid, baseline: PhaseOneStatusReader.read().sample)
                    try await PhaseOneLink.trigger(uid: uid, currentUID: { try await session.header() }, beforePress: { try pending.save(uid: uid, attempted: true) })
                })
                found = outcome.found.isEmpty ? "—" : outcome.found.joined(separator: "、")
                verified = outcome.verifiedUID ?? "—"
                progress.model.finishLookup(noTarget: outcome.verifiedUID == nil)
                status = outcome.verifiedUID == nil ? "当前可见列表未检测到红点；未触发一期版。" : "已核对用户并触发一期版识别一次；后续进度显示在浮窗。"
            } catch {
                status = "停止：" + error.localizedDescription
                progress.model.failLookup(error.localizedDescription)
            }
            progress.updateInteraction()
        }
    }
}
