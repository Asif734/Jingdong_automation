import Foundation
import CustomerReplyBatchCore
import CustomerReplyBatchAppSupport

@main
struct CustomerReplyBatchApplication {
    static func main() async {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AI客服记录", isDirectory: true)
        let knowledgeBase = root
            .appendingPathComponent("知识库", isDirectory: true)
            .appendingPathComponent("Grozziie-China-KB-2026-08-24.zip")
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var outputDirectory = executable
        for _ in 0..<4 { outputDirectory.deleteLastPathComponent() }
        let senderExecutable = outputDirectory
            .appendingPathComponent("千牛自动发送-稳定签名版.app/Contents/MacOS/千牛自动发送")
        let resources = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let schema = resources
            .appendingPathComponent(
                "QianniuCodexBatchRunner_CustomerReplyBatchAppSupport.bundle",
                isDirectory: true
            )
            .appendingPathComponent("reply-output.schema.json")
        let store = try! QueueStore(root: root)
        let timingLogger = BatchTimingLogger(runtimeDirectory: store.layout.runtime)
        let coordinator = BatchCoordinator(
            store: store,
            generator: CodexReplyGenerator(
                schemaURL: schema,
                traceDirectory: store.layout.runtime.appendingPathComponent("CLI明细"),
                sessionRegistry: CodexSessionRegistry(
                    storageURL: store.layout.runtime.appendingPathComponent("Codex客户会话.json")
                )
            ),
            knowledgeBasePaths: [knowledgeBase.path],
            onTiming: { record in timingLogger.record(record) },
            senderTrigger: ProcessSenderTrigger(executableURL: senderExecutable)
        )
        _ = await coordinator.runOnce()
    }
}
