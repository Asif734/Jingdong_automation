import CryptoKit
import Foundation

public enum HistorySubmissionMode: String, Codable, Equatable, Sendable {
    case full
    case incremental
}

public struct HistoryCheckpoint: Codable, Equatable, Sendable {
    public let historyByteCount: Int
    public let prefixSHA256: String
    public let attachmentSHA256: [String: String]

    public init(historyByteCount: Int, prefixSHA256: String, attachmentSHA256: [String: String]) {
        self.historyByteCount = historyByteCount
        self.prefixSHA256 = prefixSHA256
        self.attachmentSHA256 = attachmentSHA256
    }
}

public struct HistorySubmission: Equatable, Sendable {
    public let mode: HistorySubmissionMode
    public let historyJSONL: String
    public let imagePaths: [String]
    public let checkpoint: HistoryCheckpoint
}

public enum HistoryContinuationError: LocalizedError, Equatable {
    case unreadableAttachment(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableAttachment(let path):
            return "无法读取聊天图片：\(path)"
        }
    }
}

public enum HistoryContinuation {
    public static func plan(input: PromptInput, after previous: HistoryCheckpoint?) throws -> HistorySubmission {
        let historyData = Data(input.historyJSONL.utf8)
        let attachmentDigests = try digestAttachments(input.imagePaths)
        let checkpoint = HistoryCheckpoint(
            historyByteCount: historyData.count,
            prefixSHA256: sha256(historyData),
            attachmentSHA256: attachmentDigests
        )

        guard let previous,
              previous.historyByteCount <= historyData.count,
              sha256(historyData.prefix(previous.historyByteCount)) == previous.prefixSHA256
        else {
            return HistorySubmission(
                mode: .full,
                historyJSONL: input.historyJSONL,
                imagePaths: input.imagePaths,
                checkpoint: checkpoint
            )
        }

        let knownAttachmentDigests = Set(previous.attachmentSHA256.values)
        let newImagePaths = input.imagePaths.filter { path in
            guard let digest = attachmentDigests[path] else { return false }
            return !knownAttachmentDigests.contains(digest)
        }
        let suffixData = historyData.dropFirst(previous.historyByteCount)
        let suffix = String(decoding: suffixData, as: UTF8.self)
        return HistorySubmission(
            mode: .incremental,
            historyJSONL: suffix,
            imagePaths: newImagePaths,
            checkpoint: checkpoint
        )
    }

    public static func planExternalEvidence(
        input: PromptInput,
        preserving previous: HistoryCheckpoint?
    ) throws -> HistorySubmission {
        let checkpoint = previous ?? HistoryCheckpoint(
            historyByteCount: 0,
            prefixSHA256: sha256(Data()),
            attachmentSHA256: [:]
        )
        return HistorySubmission(
            mode: .incremental,
            historyJSONL: input.historyJSONL,
            imagePaths: input.imagePaths,
            checkpoint: checkpoint
        )
    }

    private static func digestAttachments(_ paths: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw HistoryContinuationError.unreadableAttachment(path)
            }
            result[path] = sha256(data)
        }
        return result
    }

    private static func sha256<D: DataProtocol>(_ data: D) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
