import SwiftUI

@main
struct GrozziieModelTesterApplication: App {
    @StateObject private var viewModel = ModelTesterViewModel(
        sendOperation: { _, _ in throw BootstrapError.notReady },
        newConversationOperation: { throw BootstrapError.notReady }
    )

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 620)
                .task { await bootstrap() }
        }
        .defaultSize(width: 1060, height: 760)
    }

    @MainActor
    private func bootstrap() async {
        do {
            let runtime = try await ModelTesterRuntime.make()
            viewModel.configure(
                sendOperation: { text, images in try await runtime.send(text: text, imagePaths: images) },
                newConversationOperation: { try await runtime.newConversation() },
                deleteCurrentOperation: { try await runtime.deleteCurrentConversation() },
                deleteAllOperation: { try await runtime.deleteAllConversations() },
                codexStatus: "已连接",
                codexDetail: runtime.codexExecutableURL.path,
                knowledgeStatus: "随包知识库"
            )
        } catch {
            viewModel.showBootstrapError(error)
        }
    }
}

private enum BootstrapError: LocalizedError {
    case notReady
    var errorDescription: String? { "应用尚未初始化" }
}
