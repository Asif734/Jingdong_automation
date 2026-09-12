import SwiftUI
import UniformTypeIdentifiers
import GrozziieModelTesterCore

struct ContentView: View {
    @ObservedObject var viewModel: ModelTesterViewModel
    @State private var importsImages = false
    @State private var isImageDropTarget = false
    @State private var pendingDeletion: PendingDeletion?

    private enum PendingDeletion: String, Identifiable {
        case current = "当前聊天记录"
        case all = "全部聊天记录"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
            diagnostics
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $pendingDeletion) { target in
            Alert(
                title: Text("删除\(target.rawValue)？"),
                message: Text("此操作只删除模型测试器保存的记录，不会删除知识库或原始图片。"),
                primaryButton: .destructive(Text("删除")) {
                    Task {
                        if target == .current { await viewModel.deleteCurrentHistory() }
                        else { await viewModel.deleteAllHistory() }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("格志客服模型测试器").font(.title2.bold())
                Text("只测试模型，不连接千牛").foregroundStyle(.secondary)
                Text("Codex CLI：\(viewModel.codexDetail)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            statusBadge(title: "Codex", value: viewModel.codexStatus)
            statusBadge(title: "模型", value: viewModel.modelLabel)
            statusBadge(title: "知识库", value: viewModel.knowledgeStatus)
            Button("新建测试") { Task { await viewModel.startNewConversation() } }
            Menu {
                Button("删除当前聊天记录", role: .destructive) { pendingDeletion = .current }
                Button("删除全部聊天记录", role: .destructive) { pendingDeletion = .all }
            } label: {
                Label("删除记录", systemImage: "trash")
            }
            .disabled(viewModel.isGenerating)
        }
        .padding(18)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if viewModel.messages.isEmpty {
                        ContentUnavailableView(
                            "开始测试客服模型",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("输入一个客户问题，软件会使用随包知识库和固定模型回答。")
                        ).padding(.top, 90)
                    }
                    ForEach(viewModel.messages) { message in
                        HStack {
                            if message.role == .service { Spacer(minLength: 100) }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role == .customer ? "客户" : "格志客服")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(message.text).textSelection(.enabled)
                            }
                            .padding(12)
                            .background(message.role == .customer ? Color.blue.opacity(0.12) : Color.green.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            if message.role == .customer { Spacer(minLength: 100) }
                        }
                        .id(message.id)
                    }
                }
                .padding(20)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let id = viewModel.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.attachmentPaths.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.attachmentPaths, id: \.self) { path in
                            attachmentPreview(path: path)
                        }
                        Button("全部移除") { viewModel.attachmentPaths = [] }.buttonStyle(.link)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Button { importsImages = true } label: { Image(systemName: "photo.badge.plus") }
                    .help("添加客户图片")
                TextField("输入客户问题，例如：TD630无法开机怎么办？", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                    .onSubmit { if viewModel.canSend { Task { await viewModel.submit() } } }
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    if viewModel.isGenerating { ProgressView().controlSize(.small) }
                    else { Text("发送测试") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSend)
            }
            HStack {
                Circle().fill(viewModel.isGenerating ? .orange : .green).frame(width: 8, height: 8)
                Text(viewModel.statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(viewModel.showsDiagnostics ? "收起详情" : "查看详情") {
                    viewModel.showsDiagnostics.toggle()
                }.buttonStyle(.link)
            }
        }
        .padding(18)
        .background(isImageDropTarget ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay {
            if isImageDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(6)
                    .overlay {
                        Text("松开即可添加图片")
                            .font(.headline)
                            .padding(10)
                            .background(.regularMaterial, in: Capsule())
                    }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let previousCount = viewModel.attachmentPaths.count
            viewModel.addAttachments(urls: urls)
            return viewModel.attachmentPaths.count > previousCount
        } isTargeted: { isImageDropTarget = $0 }
        .fileImporter(
            isPresented: $importsImages,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                viewModel.addAttachments(urls: urls)
            }
        }
    }

    private func attachmentPreview(path: String) -> some View {
        HStack(spacing: 7) {
            if let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: "photo")
                    .frame(width: 52, height: 52)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                Button("移除") { viewModel.removeAttachment(path: path) }.buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var diagnostics: some View {
        if viewModel.showsDiagnostics, let value = viewModel.diagnostic {
            Divider()
            HStack(spacing: 22) {
                diagnosticItem("总耗时", value.totalMilliseconds)
                diagnosticItem("Codex", value.codexMilliseconds)
                diagnosticItem("登录检查", value.loginCheckMilliseconds)
                Text("会话：\(value.sessionMode)")
                Text("历史：\(value.submittedHistoryBytes) B")
                Text("图片：\(value.submittedImageCount)")
                Spacer()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(12)
            if !viewModel.citations.isEmpty {
                Text("引用资料：\(viewModel.citations.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    private func statusBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.bold())
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func diagnosticItem(_ title: String, _ milliseconds: Double) -> some View {
        Text("\(title)：\(milliseconds / 1000, specifier: "%.2f")秒")
    }
}
