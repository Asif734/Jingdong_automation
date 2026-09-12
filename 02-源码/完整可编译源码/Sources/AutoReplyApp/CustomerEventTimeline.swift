import Foundation
import CryptoKit
import AutoReplyCore

struct CustomerEventBatch: Equatable {
    let startCursor: CustomerCursor
    let endCursor: CustomerCursor
    let targetJSONL: String
    let imageRelativePaths: [String]
    let hasNonImageContent: Bool
}

struct CustomerEventTimeline {
    private let entries: [Entry]
    private let prefixCursors: [CustomerCursor]

    var currentCursor: CustomerCursor { prefixCursors.last ?? .empty }

    init(
        historyData: Data,
        userDirectory: URL,
        imageIdentityResolver: ((String) throws -> String)? = nil
    ) throws {
        let rawLines: [Data] = historyData
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
        let decoded = try rawLines.map { raw -> (Event, String) in
            let event = try JSONDecoder().decode(Event.self, from: raw)
            guard let line = String(data: raw, encoding: .utf8) else {
                throw HistoryError.invalid("history.jsonl 不是 UTF-8")
            }
            return (event, line)
        }

        var ordinals: [String: Int] = [:]
        var observations: [Observation] = []
        var builtEntries: [Entry] = []
        for (event, rawLine) in decoded where event.sender == "customer" {
            let ordinal = ordinals[event.requestID, default: 0]
            ordinals[event.requestID] = ordinal + 1
            let content: String?
            if event.type == "image" {
                let path = try Self.validatedImagePath(event.path, userDirectory: userDirectory)
                if let imageIdentityResolver {
                    content = try imageIdentityResolver(path)
                } else {
                    content = Self.hash(try Data(contentsOf: userDirectory.appendingPathComponent(path)))
                }
            } else {
                content = event.value
            }
            let identity = Identity(
                requestID: event.requestID,
                ordinal: ordinal,
                type: event.type,
                timestamp: event.timestamp,
                content: content
            )
            observations.append(Observation(identity: identity, readStatus: event.readStatus))
            builtEntries.append(Entry(identity: identity, rawLine: rawLine, imageRelativePath: event.type == "image" ? event.path : nil))
        }

        // Opening a conversation can re-export the same visible customer batch
        // under a new request ID after its read status flips. Keep the first
        // observed identity and omit only that status-only duplicate batch.
        var batches: [[(Observation, Entry)]] = []
        for pair in zip(observations, builtEntries) {
            if batches.last?.last?.0.identity.requestID == pair.0.identity.requestID {
                batches[batches.count - 1].append(pair)
            } else {
                batches.append([pair])
            }
        }
        var canonical: [(Observation, Entry)] = []
        for batch in batches {
            var isReadStatusOnlyDuplicate = false
            if canonical.count >= batch.count {
                for start in 0...(canonical.count - batch.count) {
                    let old = Array(canonical[start..<(start + batch.count)])
                    let sameEvidence = zip(old, batch).allSatisfy {
                        $0.0.identity.type == $1.0.identity.type
                            && $0.0.identity.timestamp == $1.0.identity.timestamp
                            && $0.0.identity.content == $1.0.identity.content
                    }
                    let acknowledged = ReadStatusTransition.isUnreadToRead(
                        old.map { $0.0.readStatus }, batch.map { $0.0.readStatus }
                    )
                    if sameEvidence && acknowledged {
                        isReadStatusOnlyDuplicate = true
                        break
                    }
                }
            }
            if isReadStatusOnlyDuplicate { continue }
            canonical.append(contentsOf: batch)
        }
        builtEntries = canonical.map(\.1)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var cursors: [CustomerCursor] = [.empty]
        for entry in builtEntries {
            var chained = Data(cursors[cursors.count - 1].digest.utf8)
            chained.append(try encoder.encode(entry.identity))
            cursors.append(CustomerCursor(count: cursors.count, digest: Self.hash(chained)))
        }
        entries = builtEntries
        prefixCursors = cursors
    }

    func containsPrefix(_ cursor: CustomerCursor) -> Bool {
        guard cursor.count >= 0, cursor.count < prefixCursors.count else { return false }
        return prefixCursors[cursor.count] == cursor
    }

    func batch(after cursor: CustomerCursor) throws -> CustomerEventBatch {
        guard containsPrefix(cursor) else {
            throw HistoryError.invalid("客户回答游标不是当前聊天记录的有效前缀")
        }
        let remaining = entries.dropFirst(cursor.count)
        let jsonl = remaining.isEmpty ? "" : remaining.map(\.rawLine).joined(separator: "\n") + "\n"
        return CustomerEventBatch(
            startCursor: cursor,
            endCursor: currentCursor,
            targetJSONL: jsonl,
            imageRelativePaths: remaining.compactMap(\.imageRelativePath),
            hasNonImageContent: remaining.contains { $0.imageRelativePath == nil }
        )
    }

    private static func validatedImagePath(_ path: String?, userDirectory: URL) throws -> String {
        guard let path, path.hasPrefix("images/"), !path.split(separator: "/").contains("..") else {
            throw HistoryError.invalid("无效的聊天图片路径")
        }
        let imagesDirectory = userDirectory.appendingPathComponent("images").resolvingSymlinksInPath()
        let url = userDirectory.appendingPathComponent(path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(imagesDirectory.path + "/") else {
            throw HistoryError.invalid("聊天图片路径超出用户目录")
        }
        return path
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Entry {
        let identity: Identity
        let rawLine: String
        let imageRelativePath: String?
    }

    private struct Identity: Codable {
        let requestID: String
        let ordinal: Int
        let type: String
        let timestamp: String?
        let content: String?
    }

    private struct Observation {
        let identity: Identity
        let readStatus: String?
    }

    private struct Event: Decodable {
        let requestID: String
        let sender: String
        let type: String
        let value: String?
        let path: String?
        let timestamp: String?
        let readStatus: String?

        enum CodingKeys: String, CodingKey {
            case requestID = "request_id", sender, type = "t", value = "v", path = "p", timestamp
            case readStatus = "read_status"
        }
    }
}
