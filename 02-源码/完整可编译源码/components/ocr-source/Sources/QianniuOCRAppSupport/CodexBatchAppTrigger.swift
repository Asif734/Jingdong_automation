import Foundation

protocol CustomerQueueTriggering: Sendable {
    func trigger() async
}

struct CodexBatchAppTrigger: CustomerQueueTriggering {
    private let rootDirectory: URL
    private let batchAppURL: URL
    private let launchExecutable: @Sendable (URL) async -> Void

    init(
        rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AI客服记录", isDirectory: true),
        batchAppURL: URL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("AI客服-Codex批处理.app", isDirectory: true),
        launchExecutable: @escaping @Sendable (URL) async -> Void = { executableURL in
            await Self.runExecutable(executableURL)
        }
    ) {
        self.rootDirectory = rootDirectory
        self.batchAppURL = batchAppURL
        self.launchExecutable = launchExecutable
    }

    func trigger() async {
        let fileManager = FileManager.default
        let runtime = rootDirectory.appendingPathComponent("运行状态", isDirectory: true)
        let marker = runtime.appendingPathComponent("needs-run")
        do {
            try fileManager.createDirectory(at: runtime, withIntermediateDirectories: true)
            try Data(ISO8601DateFormatter().string(from: Date()).utf8)
                .write(to: marker, options: .atomic)
        } catch {
            return
        }

        let suiteBatchAppURL = batchAppURL
            .deletingLastPathComponent()
            .appendingPathComponent("AI客服三件套.app", isDirectory: true)
            .appendingPathComponent(
                "Contents/Resources/Components/AI客服-Codex批处理.app",
                isDirectory: true
            )
        let executableURL = [batchAppURL, suiteBatchAppURL]
            .map { appURL in
                appURL
                    .appendingPathComponent("Contents/MacOS", isDirectory: true)
                    .appendingPathComponent(appURL.deletingPathExtension().lastPathComponent)
            }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
        guard let executableURL else { return }
        await launchExecutable(executableURL)
    }

    private static func runExecutable(_ executableURL: URL) async {
        let process = Process()
        process.executableURL = executableURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
