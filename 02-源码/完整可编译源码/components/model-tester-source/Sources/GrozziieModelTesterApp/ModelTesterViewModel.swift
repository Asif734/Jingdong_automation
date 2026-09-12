import Foundation
import SwiftUI
import UniformTypeIdentifiers
import GrozziieModelTesterCore

struct DisplayMessage: Identifiable, Equatable {
    enum Role { case customer, service }
    let id = UUID()
    let role: Role
    let text: String
}

@MainActor
final class ModelTesterViewModel: ObservableObject {
    typealias SendOperation = (String, [String]) async throws -> ModelTestResult
    typealias NewConversationOperation = () async throws -> Void
    typealias DeleteOperation = () async throws -> Void

    @Published var inputText = ""
    @Published var attachmentPaths: [String] = []
    @Published private(set) var messages: [DisplayMessage] = []
    @Published private(set) var statusText = "可以开始测试"
    @Published private(set) var isGenerating = false
    @Published private(set) var diagnostic: RunDiagnostic?
    @Published private(set) var citations: [String] = []
    @Published private(set) var codexStatus = "检查中"
    @Published private(set) var codexDetail = "正在查找本机 Codex CLI"
    @Published private(set) var knowledgeStatus = "检查中"
    @Published var showsDiagnostics = false

    let modelLabel = ModelConfiguration.production.displayName
    private var sendOperation: SendOperation
    private var newConversationOperation: NewConversationOperation
    private var deleteCurrentOperation: DeleteOperation
    private var deleteAllOperation: DeleteOperation

    init(
        sendOperation: @escaping SendOperation,
        newConversationOperation: @escaping NewConversationOperation,
        deleteCurrentOperation: @escaping DeleteOperation = { },
        deleteAllOperation: @escaping DeleteOperation = { }
    ) {
        self.sendOperation = sendOperation
        self.newConversationOperation = newConversationOperation
        self.deleteCurrentOperation = deleteCurrentOperation
        self.deleteAllOperation = deleteAllOperation
    }

    var canSend: Bool {
        !isGenerating && (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachmentPaths.isEmpty)
    }

    func configure(
        sendOperation: @escaping SendOperation,
        newConversationOperation: @escaping NewConversationOperation,
        deleteCurrentOperation: @escaping DeleteOperation,
        deleteAllOperation: @escaping DeleteOperation,
        codexStatus: String,
        codexDetail: String,
        knowledgeStatus: String
    ) {
        self.sendOperation = sendOperation
        self.newConversationOperation = newConversationOperation
        self.deleteCurrentOperation = deleteCurrentOperation
        self.deleteAllOperation = deleteAllOperation
        self.codexStatus = codexStatus
        self.codexDetail = codexDetail
        self.knowledgeStatus = knowledgeStatus
        self.statusText = "可以开始测试"
    }

    func showBootstrapError(_ error: Error) {
        statusText = "初始化失败：\(error.localizedDescription)"
        codexStatus = "不可用"
        codexDetail = "请先安装 Codex CLI，并在终端运行 codex login"
    }

    func submit() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachmentPaths.isEmpty), !isGenerating else { return }
        let images = attachmentPaths
        inputText = ""
        attachmentPaths = []
        messages.append(DisplayMessage(role: .customer, text: text.isEmpty ? "[图片]" : text))
        isGenerating = true
        statusText = "正在检索资料并生成回答…"
        defer { isGenerating = false }
        do {
            let result = try await sendOperation(text, images)
            messages.append(DisplayMessage(role: .service, text: result.answer))
            diagnostic = result.diagnostic
            citations = result.citations
            statusText = "回答完成"
        } catch {
            statusText = "生成失败：\(error.localizedDescription)"
        }
    }

    func startNewConversation() async {
        guard !isGenerating else { return }
        do {
            try await newConversationOperation()
            messages = []
            diagnostic = nil
            citations = []
            attachmentPaths = []
            inputText = ""
            statusText = "可以开始测试"
        } catch {
            statusText = "新建测试失败：\(error.localizedDescription)"
        }
    }

    func addAttachments(urls: [URL]) {
        let imagePaths = urls.compactMap { url -> String? in
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
                return nil
            }
            return url.path
        }
        for path in imagePaths where !attachmentPaths.contains(path) {
            attachmentPaths.append(path)
        }
    }

    func removeAttachment(path: String) {
        attachmentPaths.removeAll { $0 == path }
    }

    func deleteCurrentHistory() async {
        await deleteHistory(operation: deleteCurrentOperation, success: "当前聊天记录已删除")
    }

    func deleteAllHistory() async {
        await deleteHistory(operation: deleteAllOperation, success: "全部聊天记录已删除")
    }

    private func deleteHistory(operation: DeleteOperation, success: String) async {
        guard !isGenerating else { return }
        do {
            try await operation()
            messages = []
            diagnostic = nil
            citations = []
            attachmentPaths = []
            inputText = ""
            statusText = success
        } catch {
            statusText = "删除失败：\(error.localizedDescription)"
        }
    }
}
