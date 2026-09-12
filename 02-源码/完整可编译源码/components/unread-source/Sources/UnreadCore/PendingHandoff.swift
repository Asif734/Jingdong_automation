import Foundation

/// One manual operation, not a background queue. Survives app restart after the dot clears.
@MainActor public final class PendingHandoff {
    public struct Entry: Codable, Sendable {
        public let uid: String
        public let attempted: Bool
    }
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Entry? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
        guard !entry.uid.isEmpty else { throw AssistantError.unsafe("待处理 ID 记录无效；未点击。") }
        return entry
    }
    public func save(uid: String, attempted: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(uid: uid, attempted: attempted)).write(to: url, options: .atomic)
    }
    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
