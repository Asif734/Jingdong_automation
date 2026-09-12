import Foundation

public enum QueueSnapshot {
    public static func load(from directory: URL, fileManager: FileManager = .default) throws -> [QueuePointer] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()

        return try urls.map { url in
            var pointer = try decoder.decode(QueuePointer.self, from: Data(contentsOf: url))
            pointer.sourceURL = url
            return pointer
        }.sorted { lhs, rhs in
            let leftText = lhs.firstQueuedAt ?? lhs.queuedAt ?? lhs.updatedAt ?? ""
            let rightText = rhs.firstQueuedAt ?? rhs.queuedAt ?? rhs.updatedAt ?? ""
            let left = formatter.date(from: leftText) ?? .distantFuture
            let right = formatter.date(from: rightText) ?? .distantFuture
            if left != right { return left < right }
            return lhs.uid < rhs.uid
        }
    }
}
