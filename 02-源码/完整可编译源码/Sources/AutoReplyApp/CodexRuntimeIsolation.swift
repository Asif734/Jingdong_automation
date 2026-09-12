import Foundation

struct CodexRuntimeIsolationResult {
    let codexHomeURL: URL
    let workingDirectoryURL: URL
    let registryBackupURL: URL?
}

enum CodexRuntimeIsolation {
    private static let version = "customer-codex-home-v1"

    static func prepare(
        runtimeDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> CodexRuntimeIsolationResult {
        let root = runtimeDirectory.appendingPathComponent("客服Codex", isDirectory: true)
        let codexHome = root.appendingPathComponent("CODEX_HOME", isDirectory: true)
        let workspace = root.appendingPathComponent("空工作目录", isDirectory: true)
        let marker = root.appendingPathComponent("环境版本.txt")
        let registry = runtimeDirectory.appendingPathComponent("Codex客户会话.json")
        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: codexHome.path
        )

        if (try? String(contentsOf: marker, encoding: .utf8)) == version {
            return CodexRuntimeIsolationResult(
                codexHomeURL: codexHome,
                workingDirectoryURL: workspace,
                registryBackupURL: nil
            )
        }

        var backup: URL?
        if fileManager.fileExists(atPath: registry.path) {
            let original = try Data(contentsOf: registry)
            let backupURL = runtimeDirectory.appendingPathComponent(
                "Codex客户会话.pre-isolated-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString).json"
            )
            try original.write(to: backupURL, options: .atomic)
            guard try Data(contentsOf: backupURL) == original else {
                throw CocoaError(.fileWriteUnknown)
            }
            try Data("{}".utf8).write(to: registry, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: registry.path)
            backup = backupURL
        }
        try Data(version.utf8).write(to: marker, options: .atomic)
        return CodexRuntimeIsolationResult(
            codexHomeURL: codexHome,
            workingDirectoryURL: workspace,
            registryBackupURL: backup
        )
    }
}
