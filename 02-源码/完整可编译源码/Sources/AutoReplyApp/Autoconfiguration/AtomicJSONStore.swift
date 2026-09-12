import Foundation

enum AtomicJSONStoreError: LocalizedError {
    case validationRejected

    var errorDescription: String? {
        switch self {
        case .validationRejected:
            return "候选配置验证失败，已保留最后可用配置"
        }
    }
}

struct AtomicJSONStore<Value: Codable & Sendable>: Sendable {
    let root: URL
    let stem: String

    var currentURL: URL { root.appendingPathComponent("\(stem).json") }
    var candidateURL: URL { root.appendingPathComponent("\(stem).candidate.json") }
    var lastKnownGoodURL: URL { root.appendingPathComponent("\(stem).last-known-good.json") }

    func load() throws -> Value? {
        try decodeIfPresent(currentURL)
    }

    func loadLastKnownGood() throws -> Value? {
        try decodeIfPresent(lastKnownGoodURL)
    }

    func loadRecoveringLastKnownGood() throws -> Value? {
        do {
            if let current = try load() { return current }
        } catch {
            return try loadLastKnownGood()
        }
        return try loadLastKnownGood()
    }

    func saveCandidate(
        _ value: Value,
        validate: (Value) throws -> Bool
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let candidateData = try encoder.encode(value)
        try synchronizedWrite(candidateData, to: candidateURL)
        defer { try? fileManager.removeItem(at: candidateURL) }

        let decoded = try JSONDecoder().decode(Value.self, from: Data(contentsOf: candidateURL))
        guard try validate(decoded) else { throw AtomicJSONStoreError.validationRejected }

        if fileManager.fileExists(atPath: currentURL.path) {
            try synchronizedWrite(Data(contentsOf: currentURL), to: lastKnownGoodURL)
        } else {
            try synchronizedWrite(candidateData, to: lastKnownGoodURL)
        }
        try synchronizedWrite(candidateData, to: currentURL)
    }

    private func decodeIfPresent(_ url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    private func synchronizedWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
