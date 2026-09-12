import SwiftUI

public struct ContentView: View {
    @ObservedObject private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("千牛主聊天区 OCR · Plan B")

            HStack(spacing: 12) {
                Button("识别千牛主聊天区") {
                    Task { await model.runOCR() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isRunning)

                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button("复制全部") {
                    model.copyAll()
                }
                .disabled(model.output == "[]")
            }

            HStack {
                Text(model.status)
                    .foregroundStyle(statusColor)
                Spacer()
                if let elapsed = model.elapsedMilliseconds {
                    Text("总耗时：\(elapsed) ms")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.callout)

            pipelineStatusCard

            Picker("输出视图", selection: Binding(
                get: { model.displayMode },
                set: { model.selectDisplayMode($0) }
            )) {
                ForEach(OCRDisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if let identity = model.resolvedIdentity {
                Text("当前用户：\(identity.identity.value) · 来源：\(identity.source.rawValue)")
                    .font(.caption)
                    .foregroundStyle(
                        identity.identity.status == .needsReview ? Color.orange : Color.secondary
                    )
                    .textSelection(.enabled)
            }

            if let queuePath = model.lastQueuePath {
                Text("AI 客服队列：\(queuePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            if model.status.contains("权限") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("请为本 App 开启辅助功能和屏幕录制权限，然后重新点击识别。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Link("打开屏幕录制权限", destination: URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                        )!)
                        Link("打开辅助功能权限", destination: URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                        )!)
                    }
                    .font(.caption)
                }
            }

            TextEditor(text: Binding(
                get: { model.output },
                set: { _ in }
            ))
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25))
            }

            if !model.detectedImages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("检测到图片（JSON 已插入 [图片]）")
                        .font(.callout.weight(.medium))

                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(model.detectedImages.enumerated()), id: \.offset) { _, image in
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 360, maxHeight: 240)
                                    .background(Color.black.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.25))
                                    }
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 560)
        .task {
            await model.monitorPipelineStatus()
        }
    }

    private var pipelineStatusCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(pipelineColor)
                    .frame(width: 9, height: 9)
                Text("AI 客服处理状态")
                    .font(.callout.weight(.semibold))
                Text(model.isRunning ? model.status : model.pipelineStatus.headline)
                    .font(.callout)
                Spacer()
                if let updatedAt = model.pipelineStatus.updatedAt {
                    Text(updatedAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let uid = model.pipelineStatus.currentUID {
                Text("当前 UID：\(uid)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let detail = model.pipelineStatus.detail {
                Text("原因：\(detail)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let warning = model.pipelineStatus.earlierWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack(spacing: 12) {
                countLabel("排队", model.pipelineStatus.counts.queued)
                countLabel("生成", model.pipelineStatus.counts.generating)
                countLabel("待发送", model.pipelineStatus.counts.awaitingSend)
                countLabel("发送中", model.pipelineStatus.counts.sending)
                countLabel("待人工", model.pipelineStatus.counts.humanReview)
                countLabel("失败", model.pipelineStatus.counts.failed)
                Spacer()
            }
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.secondary.opacity(0.2))
        }
    }

    private func countLabel(_ title: String, _ count: Int) -> some View {
        Text("\(title) \(count)")
            .font(.caption)
            .foregroundStyle(count == 0 ? Color.secondary : Color.primary)
            .monospacedDigit()
    }

    private var pipelineColor: Color {
        if model.isRunning { return .blue }
        switch model.pipelineStatus.stage {
        case .idle, .completed: return .green
        case .queued, .generating, .awaitingSend, .sending: return .blue
        case .humanReview: return .orange
        case .failed: return .red
        }
    }

    private var statusColor: Color {
        if model.status.contains("失败") || model.status.contains("没有找到") || model.status.contains("需要开启") {
            return .red
        }
        return .secondary
    }
}
