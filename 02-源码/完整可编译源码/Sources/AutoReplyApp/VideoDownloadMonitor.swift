import Foundation

struct VideoDownloadMonitorRecord: Codable, Equatable, Sendable {
    let messageID: String
    let startedAt: Date
    var completedAt: Date?
    var filePath: String?
    var bytes: Int?
}

private struct VideoDownloadMonitorPayload: Codable, Sendable {
    var version = 1
    var records: [VideoDownloadMonitorRecord]
}

/// Records video downloads independently from the customer-processing queue.
/// A pending record is observational only: it has no timeout, failure state,
/// retry action, or authority to pause scanning.
actor VideoDownloadMonitor {
    private let storeURL: URL
    private var loaded = false
    private var records: [String: VideoDownloadMonitorRecord] = [:]
    private let maximumRecords = 2_000

    init(storeURL: URL) {
        self.storeURL = storeURL
    }

    func markStarted(messageID: String, at date: Date) throws {
        guard !messageID.isEmpty else { return }
        try loadIfNeeded()
        if records[messageID] == nil {
            records[messageID] = VideoDownloadMonitorRecord(
                messageID: messageID,
                startedAt: date,
                completedAt: nil,
                filePath: nil,
                bytes: nil
            )
            trimIfNeeded()
            try persist()
        }
    }

    func markCompleted(
        messageID: String,
        startedAt: Date,
        completedAt: Date,
        fileURL: URL,
        bytes: Int
    ) throws {
        guard !messageID.isEmpty else { return }
        try loadIfNeeded()
        var record = records[messageID] ?? VideoDownloadMonitorRecord(
            messageID: messageID,
            startedAt: startedAt,
            completedAt: nil,
            filePath: nil,
            bytes: nil
        )
        record.completedAt = completedAt
        record.filePath = fileURL.path
        record.bytes = bytes
        records[messageID] = record
        trimIfNeeded()
        try persist()
    }

    func record(messageID: String) throws -> VideoDownloadMonitorRecord? {
        try loadIfNeeded()
        return records[messageID]
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let data = try Data(contentsOf: storeURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let payload = try decoder.decode(VideoDownloadMonitorPayload.self, from: data)
        records = Dictionary(uniqueKeysWithValues: payload.records.map { ($0.messageID, $0) })
    }

    private func trimIfNeeded() {
        guard records.count > maximumRecords else { return }
        let overflow = records.values
            .sorted { $0.startedAt < $1.startedAt }
            .prefix(records.count - maximumRecords)
        for record in overflow { records.removeValue(forKey: record.messageID) }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = VideoDownloadMonitorPayload(
            records: records.values.sorted { $0.startedAt < $1.startedAt }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: storeURL, options: .atomic)
    }
}
