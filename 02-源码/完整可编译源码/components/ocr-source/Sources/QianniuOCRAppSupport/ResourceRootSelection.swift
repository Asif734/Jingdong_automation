import Foundation

enum ResourceRootSelection {
    static func installedResourceRoot(
        executablePath: String = CommandLine.arguments[0]
    ) -> URL {
        URL(fileURLWithPath: executablePath)
            .standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("WebOCR", isDirectory: true)
    }

    static func select(
        packaged: URL?,
        exists: (URL) -> Bool,
        development: () throws -> URL
    ) rethrows -> URL {
        if let packaged, exists(packaged) {
            return packaged
        }
        return try development()
    }

    static func openCVScript(
        packaged: URL?,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        development: () throws -> URL
    ) rethrows -> URL {
        try select(packaged: packaged, exists: exists, development: development)
    }
}
