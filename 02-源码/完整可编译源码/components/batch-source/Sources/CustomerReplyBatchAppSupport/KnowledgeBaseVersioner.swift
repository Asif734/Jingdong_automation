import CryptoKit
import Foundation

public actor KnowledgeBaseVersioner {
    private struct CacheEntry {
        let size: UInt64
        let modificationDate: Date
        let digest: String
    }

    private var cache: [String: CacheEntry] = [:]

    public init() {}

    public func version(paths: [String]) throws -> String {
        var combined = Data()
        for path in paths.sorted() {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let modificationDate = (attributes[.modificationDate] as? Date) ?? .distantPast
            let digest: String
            if let cached = cache[path],
               cached.size == size,
               cached.modificationDate == modificationDate {
                digest = cached.digest
            } else {
                digest = Self.sha256(try Data(contentsOf: URL(fileURLWithPath: path)))
                cache[path] = CacheEntry(
                    size: size,
                    modificationDate: modificationDate,
                    digest: digest
                )
            }
            combined.append(contentsOf: path.utf8)
            combined.append(0)
            combined.append(contentsOf: digest.utf8)
            combined.append(0)
        }
        return Self.sha256(combined)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
