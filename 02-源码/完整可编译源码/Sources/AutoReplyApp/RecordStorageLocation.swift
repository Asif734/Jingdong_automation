import Foundation

enum RecordStorageMigrationError: LocalizedError {
    case conflictingDesktopEntry(String)

    var errorDescription: String? {
        switch self {
        case .conflictingDesktopEntry(let path):
            return "桌面记录入口与新存储目录同时存在，未自动合并：\(path)"
        }
    }
}

struct RecordStorageLocation {
    let runtimeRoot: URL
    let desktopEntry: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        runtimeRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/QianniuAutoReplyTaskIsolationCandidate", isDirectory: true)
            .appendingPathComponent("AI客服记录-任务隔离候选版", isDirectory: true)
        desktopEntry = homeDirectory
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("AI客服记录-任务隔离候选版", isDirectory: true)
    }

    func migrateLegacyDesktopRecords(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: runtimeRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: desktopEntry.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: desktopEntry.path) {
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: desktopEntry.path) {
                let destinationURL = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination, isDirectory: true)
                    : desktopEntry.deletingLastPathComponent()
                        .appendingPathComponent(destination, isDirectory: true)
                guard destinationURL.standardizedFileURL == runtimeRoot.standardizedFileURL else {
                    throw RecordStorageMigrationError.conflictingDesktopEntry(desktopEntry.path)
                }
                try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
                return
            }
            guard !fileManager.fileExists(atPath: runtimeRoot.path) else {
                throw RecordStorageMigrationError.conflictingDesktopEntry(desktopEntry.path)
            }
            try fileManager.moveItem(at: desktopEntry, to: runtimeRoot)
        } else {
            try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        }

        try fileManager.createSymbolicLink(at: desktopEntry, withDestinationURL: runtimeRoot)
    }
}
