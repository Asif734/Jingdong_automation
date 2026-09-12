import Foundation

public struct CodexSessionBinding: Codable, Equatable, Sendable {
    public let uid: String
    public let sessionID: String
    public let createdAt: Date
    public let lastActivityAt: Date
    public let promptVersion: String
    public let knowledgeBaseVersion: String
    public let checkpoint: HistoryCheckpoint
    public let recoveryCount: Int

    public init(
        uid: String,
        sessionID: String,
        createdAt: Date,
        lastActivityAt: Date,
        promptVersion: String,
        knowledgeBaseVersion: String,
        checkpoint: HistoryCheckpoint,
        recoveryCount: Int
    ) {
        self.uid = uid
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.promptVersion = promptVersion
        self.knowledgeBaseVersion = knowledgeBaseVersion
        self.checkpoint = checkpoint
        self.recoveryCount = recoveryCount
    }
}

public struct CodexSessionPlan: Equatable, Sendable {
    public let binding: CodexSessionBinding?

    public var requiresCreation: Bool { binding == nil }
    public var sessionID: String? { binding?.sessionID }
    public var checkpoint: HistoryCheckpoint? { binding?.checkpoint }

    public static let create = CodexSessionPlan(binding: nil)
}

public actor CodexSessionRegistry {
    private let storageURL: URL
    private var bindings: [String: CodexSessionBinding]

    public init(storageURL: URL) {
        self.storageURL = storageURL
        self.bindings = Self.loadBindings(from: storageURL)
    }

    public func plan(
        uid: String,
        promptVersion: String,
        knowledgeBaseVersion: String,
        at now: Date
    ) throws -> CodexSessionPlan {
        guard let binding = bindings[uid] else { return .create }
        guard binding.uid == uid,
              binding.promptVersion == promptVersion,
              binding.knowledgeBaseVersion == knowledgeBaseVersion
        else {
            bindings.removeValue(forKey: uid)
            try persist()
            return .create
        }
        return CodexSessionPlan(binding: binding)
    }

    public func commit(
        uid: String,
        sessionID: String,
        checkpoint: HistoryCheckpoint,
        promptVersion: String,
        knowledgeBaseVersion: String,
        recoveryCount: Int = 0,
        at now: Date
    ) throws {
        let existing = bindings[uid]
        let createdAt = existing?.sessionID == sessionID ? existing!.createdAt : now
        bindings[uid] = CodexSessionBinding(
            uid: uid,
            sessionID: sessionID,
            createdAt: createdAt,
            lastActivityAt: now,
            promptVersion: promptVersion,
            knowledgeBaseVersion: knowledgeBaseVersion,
            checkpoint: checkpoint,
            recoveryCount: recoveryCount
        )
        try persist()
    }

    public func invalidate(uid: String) throws {
        guard bindings.removeValue(forKey: uid) != nil else { return }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bindings)
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes(
            [FileAttributeKey.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: storageURL.path
        )
    }

    private static func loadBindings(from storageURL: URL) -> [String: CodexSessionBinding] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: storageURL)
            return try JSONDecoder().decode([String: CodexSessionBinding].self, from: data)
        } catch {
            let stem = storageURL.deletingPathExtension().lastPathComponent
            let diagnostic = storageURL.deletingLastPathComponent().appendingPathComponent(
                "\(stem).corrupt-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString).json"
            )
            try? FileManager.default.copyItem(at: storageURL, to: diagnostic)
            return [:]
        }
    }
}
