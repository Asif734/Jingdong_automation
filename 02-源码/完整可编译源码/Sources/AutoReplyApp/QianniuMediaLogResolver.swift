import CryptoKit
import Foundation
import QianniuOCRAppSupport

enum VisualMediaResolution: Equatable, Sendable {
    case copyImage(messageID: String?)
    case ignoreVideo(messageID: String)
    case videoInFlight(messageID: String)
}

protocol VisualMediaTypeResolving: Sendable {
    func resolve(customerUID: String, now: Date) async -> VisualMediaResolution
}

enum LiveMediaRouting {
    static func action(
        resolver: any VisualMediaTypeResolving,
        customerUID: String,
        now: Date = Date()
    ) async -> DetectedMediaAction {
        switch await resolver.resolve(customerUID: customerUID, now: now) {
        case .copyImage: return .copy
        case .ignoreVideo(let messageID):
            return .openVideo(messageID: messageID, customerUID: customerUID)
        case .videoInFlight(let messageID):
            return .videoInFlight(messageID: messageID)
        }
    }
}

struct ImageFallbackMediaResolver: VisualMediaTypeResolving {
    func resolve(customerUID: String, now: Date) async -> VisualMediaResolution {
        .copyImage(messageID: nil)
    }
}

actor QianniuMediaLogResolver: VisualMediaTypeResolving {
    typealias VideoDetected = @Sendable (String) async -> Void
    private enum MediaType: String, Codable, Sendable {
        case image
        case video
    }

    private struct MessageEvent: Sendable {
        let messageID: String
        let customerUID: String
        let receivedAt: Date
    }

    private struct FileState: Sendable {
        let identity: String
        let offset: UInt64
        let remainder: Data
    }

    private struct ProcessedEntry: Codable, Sendable {
        let messageHash: String
        let customerHash: String
        let type: MediaType
        let processedAt: Date
    }

    private struct Journal: Codable, Sendable {
        var schemaVersion = 1
        var entries: [ProcessedEntry]
    }

    private let logURLs: [URL]
    private let processedStoreURL: URL
    private let videoTransferStore: DurableVideoTransferStore?
    private let maximumInitialBytes: UInt64
    private let maximumRecoveryBytes: UInt64
    private let lookback: TimeInterval
    private let maximumEntries: Int
    private let onVideoDetected: VideoDetected
    private var states: [String: FileState] = [:]
    private var events: [String: MessageEvent] = [:]
    private var typeHints: [String: Set<MediaType>] = [:]
    private var processedHashes = Set<String>()
    private var journal: Journal?

    init(
        logURLs: [URL],
        processedStoreURL: URL,
        videoTransferStore: DurableVideoTransferStore? = nil,
        maximumInitialBytes: UInt64 = 33_554_432,
        maximumRecoveryBytes: UInt64 = 4_194_304,
        lookback: TimeInterval = 15 * 60,
        maximumEntries: Int = 10_000,
        onVideoDetected: @escaping VideoDetected = { _ in }
    ) {
        self.logURLs = logURLs
        self.processedStoreURL = processedStoreURL
        self.videoTransferStore = videoTransferStore
        self.maximumInitialBytes = maximumInitialBytes
        self.maximumRecoveryBytes = maximumRecoveryBytes
        self.lookback = lookback
        self.maximumEntries = max(1, maximumEntries)
        self.onVideoDetected = onVideoDetected
    }

    func resolve(customerUID: String, now: Date = Date()) async -> VisualMediaResolution {
        guard !customerUID.isEmpty else { return .copyImage(messageID: nil) }
        do {
            try loadJournalIfNeeded()
            for url in logURLs where FileManager.default.fileExists(atPath: url.path) {
                let lines = try readNewLines(from: url)
                ingest(lines: lines)
            }
            pruneEvidence(now: now)
            var candidate = newestCandidate(for: customerUID, now: now)
            if candidate.flatMap({ resolvedType(for: $0.messageID) }) == nil {
                // Qianniu writes the customer event and its 105 type marker on
                // separate log lines. They can land on opposite sides of two
                // incremental reads (or a rotation boundary). Re-read only a
                // bounded recent tail so a valid pair cannot be lost forever.
                for url in logURLs where FileManager.default.fileExists(atPath: url.path) {
                    ingest(lines: try readRecentLines(from: url, maximumBytes: maximumRecoveryBytes))
                }
                pruneEvidence(now: now)
                candidate = newestCandidate(for: customerUID, now: now)
            }
            // First bind to the newest exact customer event, then inspect only
            // that event's messageId. An older processed video must never win
            // merely because a newer image/text marker has not reached the log.
            guard let candidate, let type = resolvedType(for: candidate.messageID) else {
                return .copyImage(messageID: nil)
            }
            switch type {
            case .image:
                if !processedHashes.contains(Self.hash(candidate.messageID)) {
                    do {
                        try recordProcessed(candidate, type: type, at: now)
                    } catch {
                        return .copyImage(messageID: nil)
                    }
                }
                return .copyImage(messageID: candidate.messageID)
            case .video:
                await onVideoDetected(candidate.messageID)
                guard let videoTransferStore else {
                    return .ignoreVideo(messageID: candidate.messageID)
                }
                let key = VideoTransferIdentity.key(
                    customerUID: customerUID,
                    messageID: candidate.messageID
                )
                _ = try await videoTransferStore.beginOrRead(key: key, customerUID: customerUID)
                switch try await videoTransferStore.disposition(for: key) {
                case .needsOpen:
                    return .ignoreVideo(messageID: candidate.messageID)
                case .inFlight, .waitingUntil, .terminal:
                    return .videoInFlight(messageID: candidate.messageID)
                }
            }
        } catch {
            return .copyImage(messageID: nil)
        }
    }

    private func ingest(lines: [String]) {
        for line in lines {
            if let (messageID, type) = messageTypeHint(in: line) {
                typeHints[messageID, default: []].insert(type)
            }
        }
        for line in lines {
            for event in parseEvents(in: line) {
                events[event.messageID] = event
            }
        }
    }

    private func resolvedType(for messageID: String) -> MediaType? {
        guard let hints = typeHints[messageID], hints.count == 1 else { return nil }
        return hints.first
    }

    private func newestCandidate(for customerUID: String, now: Date) -> MessageEvent? {
        events.values
            .filter { event in
                event.customerUID == customerUID
                    && abs(now.timeIntervalSince(event.receivedAt)) <= lookback
            }
            .max {
                if $0.receivedAt == $1.receivedAt { return $0.messageID < $1.messageID }
                return $0.receivedAt < $1.receivedAt
            }
    }

    private func pruneEvidence(now: Date) {
        let oldest = now.addingTimeInterval(-lookback)
        let newest = now.addingTimeInterval(60)
        events = events.filter { _, event in event.receivedAt >= oldest && event.receivedAt <= newest }
        let liveIDs = Set(events.keys)
        typeHints = typeHints.filter { liveIDs.contains($0.key) }
    }

    private func loadJournalIfNeeded() throws {
        guard journal == nil else { return }
        if FileManager.default.fileExists(atPath: processedStoreURL.path) {
            let decoded = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: processedStoreURL))
            journal = decoded
            processedHashes = Set(decoded.entries.map(\.messageHash))
        } else {
            journal = Journal(entries: [])
        }
    }

    private func recordProcessed(_ event: MessageEvent, type: MediaType, at date: Date) throws {
        try loadJournalIfNeeded()
        let messageHash = Self.hash(event.messageID)
        guard processedHashes.insert(messageHash).inserted else { return }
        var value = journal ?? Journal(entries: [])
        value.entries.append(ProcessedEntry(
            messageHash: messageHash,
            customerHash: Self.hash(event.customerUID),
            type: type,
            processedAt: date
        ))
        if value.entries.count > maximumEntries {
            value.entries.removeFirst(value.entries.count - maximumEntries)
            processedHashes = Set(value.entries.map(\.messageHash))
        }
        try FileManager.default.createDirectory(
            at: processedStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: processedStoreURL, options: .atomic)
        journal = value
    }

    private func readNewLines(from url: URL) throws -> [String] {
        let current = try metadata(for: url)
        let prior = states[url.path]
        let continuing = prior?.identity == current.identity && current.size >= (prior?.offset ?? 0)
        var start = continuing ? (prior?.offset ?? 0) : 0
        if !continuing, current.size > maximumInitialBytes {
            start = current.size - maximumInitialBytes
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if continuing, let remainder = prior?.remainder, !remainder.isEmpty {
            data = remainder + data
        } else if !continuing, start > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            states[url.path] = FileState(identity: current.identity, offset: current.size, remainder: data)
            return []
        }
        let complete = data[data.startIndex...lastNewline]
        let next = data.index(after: lastNewline)
        states[url.path] = FileState(
            identity: current.identity,
            offset: current.size,
            remainder: Data(data[next...])
        )
        return String(decoding: complete, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
    }

    private func readRecentLines(from url: URL, maximumBytes: UInt64) throws -> [String] {
        let current = try metadata(for: url)
        let start = current.size > maximumBytes ? current.size - maximumBytes : 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
    }

    private func messageTypeHint(in line: String) -> (String, MediaType)? {
        guard line.range(
            of: #"messageType\s*[:=]\s*105|msgType\s*[:=]\s*105|MESSAGETEMPLATETYPE_VIDEO"#,
            options: .regularExpression
        ) != nil else {
            // 101 / IMAGETEXT is a rendering-template family in current
            // Qianniu logs, not reliable evidence that an attachment exists.
            // Only exact video evidence changes the established visual route.
            return nil
        }
        guard let range = line.range(
            of: #"messageId[=:\"\s]+[A-Za-z0-9._-]+"#,
            options: .regularExpression
        ) else { return nil }
        let matched = String(line[range])
        guard let messageID = matched.split(whereSeparator: {
            $0 == "=" || $0 == ":" || $0 == "\"" || $0.isWhitespace
        }).last.map(String.init), !messageID.isEmpty else { return nil }
        return (messageID, .video)
    }

    private func parseEvents(in line: String) -> [MessageEvent] {
        guard let storeNick = storeNick(in: line),
              let data = jsonArrayData(in: line),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.flatMap { row -> [MessageEvent] in
            guard let messages = row["newmsgs"] as? [[String: Any]] else { return [] }
            return messages.compactMap { message in
                let code = message["mcode"] as? [String: Any] ?? [:]
                let messageID = (code["messageId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (code["clientId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let from = message["fromId"] as? [String: Any] ?? [:]
                let sender = cleanNick(from["nick"] as? String ?? "")
                guard let messageID, !sender.isEmpty,
                      !sender.contains(storeNick), !storeNick.contains(sender) else { return nil }
                let milliseconds = (message["sendTime"] as? NSNumber)?.doubleValue ?? 0
                return MessageEvent(
                    messageID: messageID,
                    customerUID: sender,
                    receivedAt: Date(timeIntervalSince1970: milliseconds / 1_000)
                )
            }
        }
    }

    private func storeNick(in line: String) -> String? {
        guard let range = line.range(of: #"\[CHAT ([^#\]]+)#"#, options: .regularExpression) else {
            return nil
        }
        let match = String(line[range])
        return match.dropFirst("[CHAT ".count).split(separator: "#").first.map(String.init).map(cleanNick)
    }

    private func jsonArrayData(in line: String) -> Data? {
        guard let marker = line.range(of: "jsonStr="),
              let start = line[marker.upperBound...].firstIndex(of: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < line.endIndex {
            let character = line[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 { return Data(line[start...index].utf8) }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private func cleanNick(_ value: String) -> String {
        value.replacingOccurrences(of: "cntaobao", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metadata(for url: URL) throws -> (identity: String, size: UInt64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let system = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return ("\(system):\(file)", size)
    }

    private nonisolated static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
