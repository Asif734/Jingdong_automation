import SwiftUI
import AppKit
import CustomerReplyBatchAppSupport

struct ContentView: View {
    @ObservedObject var model: BatchViewModel
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/AI客服记录")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI客服 · Codex 批处理").font(.title2.bold())
            HStack(spacing: 10) {
                if model.isRunning { ProgressView().controlSize(.small) }
                Text(model.statusText)
            }
            if let summary = model.summary {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    row("启动时队列", summary.total)
                    row("进入待发送", summary.autoSend)
                    row("待人工确认", summary.humanReview)
                    row("无需回复", summary.noAction)
                    row("失败", summary.failed)
                }
                Divider()
                HStack {
                    Button("打开待发送") { open("待发送") }
                    Button("打开待人工确认") { open("待人工确认") }
                    Button("打开失败") { open("失败") }
                }
            }
            Text("本次只处理启动瞬间的队列；运行期间的新消息留到下次启动。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 500)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: Int) -> some View {
        GridRow { Text(label); Text("\(value)").monospacedDigit() }
    }

    private func open(_ name: String) {
        NSWorkspace.shared.open(root.appendingPathComponent(name, isDirectory: true))
    }
}
