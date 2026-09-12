import AppKit
import CryptoKit
import Darwin
import Foundation
import QianniuOCRCore

protocol CustomerRequestExporting: Sendable {
    func export(result: OCRRunResult) async throws -> URL?
}

enum CustomerRequestExportError: LocalizedError {
    case jpegEncodingFailed
    case requestAlreadyExists(String)
    case lockFailed(Int32)
    case historyReadTimedOut
    case historyReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .jpegEncodingFailed:
            "无法把客户图片编码为 JPEG"
        case .requestAlreadyExists(let requestID):
            "请求 \(requestID) 的客户图片已存在，已停止以防覆盖"
        case .lockFailed(let code):
            "无法锁定 AI 客服记录目录（errno \(code)）"
        case .historyReadTimedOut:
            "读取已有聊天记录超过 2 秒；当前客户稍后重试，其他客户继续处理"
        case .historyReadFailed(let message):
            "读取已有聊天记录失败：\(message)"
        }
    }
}

actor CustomerRequestPackageExporter: CustomerRequestExporting {
    private let rootDirectory: URL
    private let requestID: () -> String
    private let now: () -> Date
    private let queueTrigger: (any CustomerQueueTriggering)?
    private let fileManager = FileManager.default
    private let historyReader: BoundedLocalFileReader

    init(
        rootDirectory: URL = CustomerRequestPackageExporter.defaultRootDirectory(),
        requestID: @escaping () -> String = CustomerRequestPackageExporter.makeRequestID,
        now: @escaping () -> Date = Date.init,
        queueTrigger: (any CustomerQueueTriggering)? = nil,
        historyReader: BoundedLocalFileReader = BoundedLocalFileReader()
    ) {
        self.rootDirectory = rootDirectory
        self.requestID = requestID
        self.now = now
        self.queueTrigger = queueTrigger
        self.historyReader = historyReader
    }

    func export(result: OCRRunResult) async throws -> URL? {
        try await export(result: result, serviceAliases: nil)
    }

    func export(result: OCRRunResult, serviceAliases: Set<String>?) async throws -> URL? {
        let currentRequestID = requestID()
        let createdAt = now()
        let ocrCandidate = result.identityCandidates.ocr
            ?? CustomerIdentityExtractor.detectedValue(
                from: result.lines,
                imageHeight: result.sourceImageSize.height
            )
        let candidates = CustomerIdentityCandidates(
            axHeader: result.identityCandidates.axHeader,
            axSessionList: result.identityCandidates.axSessionList,
            ocr: ocrCandidate
        )
        let resolvedIdentity = CustomerIdentityResolver.resolve(
            candidates: candidates,
            requestID: currentRequestID
        )
        let parsed = ParsedChatParser.parse(
            lines: result.lines,
            imageBoxes: result.images.map(\.box),
            imageHeight: result.sourceImageSize.height,
            serviceAliases: serviceAliases
        )
        let identity = resolvedIdentity.identity
        let messages = parsed.messages
        let pendingDirectory = rootDirectory.appendingPathComponent("待处理", isDirectory: true)
        let userDirectory = rootDirectory
            .appendingPathComponent("用户", isDirectory: true)
            .appendingPathComponent(identity.value, isDirectory: true)
        let userImagesDirectory = userDirectory.appendingPathComponent("images", isDirectory: true)
        try fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userImagesDirectory, withIntermediateDirectories: true)

        let lockDescriptor = try acquireExportLock()
        defer {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = close(lockDescriptor)
        }

        var historyMessages = messages
        var imagePayloads: [(historyName: String, data: Data)] = []
        for (index, detectedImage) in result.images.enumerated() {
            guard let jpeg = NSBitmapImageRep(cgImage: detectedImage.image).representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.85]
            ) else {
                throw CustomerRequestExportError.jpegEncodingFailed
            }
            let historyName = "\(currentRequestID)-\(index + 1).jpg"
            imagePayloads.append((historyName, jpeg))
            historyMessages = historyMessages.map { message in
                guard message.path == "images/\(index + 1).jpg" else { return message }
                return ParsedChatMessage(
                    sender: message.sender,
                    type: "image",
                    value: nil,
                    path: "images/\(historyName)",
                    timestamp: message.timestamp,
                    readStatus: message.readStatus
                )
            }
        }
        let currentImageFingerprints = Dictionary(uniqueKeysWithValues:
            imagePayloads.enumerated().map { index, payload in
                ("images/\(index + 1).jpg", Self.hash(payload.data))
            }
        )

        let historyURL = userDirectory.appendingPathComponent("history.jsonl")
        let readableHistoryURL = userDirectory.appendingPathComponent("history.txt")
        let previousHistory: Data?
        if fileManager.fileExists(atPath: historyURL.path) {
            previousHistory = try await historyReader.read(historyURL)
        } else {
            previousHistory = nil
        }
        let previousReadableHistory: Data?
        if fileManager.fileExists(atPath: readableHistoryURL.path) {
            previousReadableHistory = try await historyReader.read(readableHistoryURL)
        } else {
            previousReadableHistory = nil
        }
        var incrementalMessages = try incrementalMessages(
            current: messages,
            currentImageFingerprints: currentImageFingerprints,
            previousHistory: previousHistory,
            userDirectory: userDirectory
        )
        incrementalMessages = try removingPreviouslySeenLinksBeforeStableAnchor(
            from: incrementalMessages,
            current: messages,
            history: previousHistory
        )
        incrementalMessages = removingImagesBeforeLatestServiceBoundary(
            from: incrementalMessages,
            current: messages,
            history: previousHistory
        )
        guard !incrementalMessages.isEmpty else {
            if previousReadableHistory == nil,
               let previousHistory,
               !previousHistory.isEmpty {
                try readableHistoryData(from: previousHistory).write(
                    to: readableHistoryURL,
                    options: .atomic
                )
            }
            return nil
        }
        historyMessages = rewrittenMessages(
            correspondingTo: incrementalMessages,
            current: messages,
            rewritten: historyMessages
        )
        let incrementalImagePaths = Set(
            incrementalMessages
                .filter { $0.type == "image" }
                .compactMap(\.path)
        )
        imagePayloads = imagePayloads.enumerated().compactMap { index, payload in
            let packagePath = "images/\(index + 1).jpg"
            guard incrementalImagePaths.contains(packagePath) else { return nil }
            return payload
        }

        let createdAtText = Self.iso8601.string(from: createdAt)
        let nextHistory = try historyData(
            previous: previousHistory,
            requestID: currentRequestID,
            createdAt: createdAtText,
            messages: historyMessages
        )
        let nextReadableHistory = try readableHistoryData(from: nextHistory)
        let hasNewCustomerRequest = try hasNewCustomerRequest(
            incremental: incrementalMessages, current: messages, history: previousHistory
        )
        let shouldQueue = hasNewCustomerRequest
        let queueURL = pendingDirectory.appendingPathComponent("\(identity.value).json")
        let nextQueue: Data?
        if shouldQueue {
            let currentCustomerImagePaths = historyMessages
                .filter { $0.sender == "customer" && $0.type == "image" }
                .compactMap(\.path)
            let queue = CustomerQueuePointer(
                uid: identity.value,
                userDirectory: userDirectory.path,
                queuedAt: createdAtText,
                historyVersion: SHA256.hash(data: nextHistory)
                    .map { String(format: "%02x", $0) }
                    .joined(),
                currentCustomerImagePaths: currentCustomerImagePaths
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            nextQueue = try encoder.encode(queue) + Data([0x0A])
        } else {
            nextQueue = nil
        }

        var committedImages: [URL] = []
        var historyWasCommitted = false
        var readableHistoryWasCommitted = false
        do {
            for payload in imagePayloads {
                let destination = userImagesDirectory.appendingPathComponent(payload.historyName)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw CustomerRequestExportError.requestAlreadyExists(currentRequestID)
                }
                try payload.data.write(to: destination, options: .atomic)
                committedImages.append(destination)
            }
            try nextHistory.write(to: historyURL, options: .atomic)
            historyWasCommitted = true
            try nextReadableHistory.write(to: readableHistoryURL, options: .atomic)
            readableHistoryWasCommitted = true
            if let nextQueue {
                try nextQueue.write(to: queueURL, options: .atomic)
            }
        } catch {
            for imageURL in committedImages {
                try? fileManager.removeItem(at: imageURL)
            }
            if historyWasCommitted {
                if let previousHistory {
                    try? previousHistory.write(to: historyURL, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: historyURL)
                }
            }
            if readableHistoryWasCommitted {
                if let previousReadableHistory {
                    try? previousReadableHistory.write(to: readableHistoryURL, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: readableHistoryURL)
                }
            }
            throw error
        }
        if shouldQueue {
            await queueTrigger?.trigger()
            return queueURL
        }
        return nil
    }

    // OCR evidence is still archived verbatim. A changed OCR rendering of an
    // old viewport, however, must not launch another reply to an old request.
    private func hasNewCustomerRequest(
        incremental: [ParsedChatMessage], current: [ParsedChatMessage], history: Data?
    ) throws -> Bool {
        guard incremental.contains(where: { $0.sender == "customer" }) else { return false }
        guard let history, !history.isEmpty else { return true }
        let events = try history.split(separator: 0x0A).map {
            try JSONDecoder().decode(HistoryEvent.self, from: Data($0))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-M-d H:mm:ss"
        let latestTime = events.compactMap { $0.timestamp.flatMap(formatter.date(from:)) }.max()
        var knownLinks: [Date: Set<String>] = [:]
        var eventTime: Date?
        var eventSender: String?
        var request: String?
        for event in events {
            if request != event.requestID {
                eventTime = nil
                eventSender = nil
                request = event.requestID
            }
            if event.timestamp != nil || (event.sender != "unknown" && event.sender != eventSender) {
                eventTime = event.timestamp.flatMap(formatter.date(from:))
                eventSender = event.sender
            }
            if event.sender == "customer", event.type == "link", let value = event.value, let eventTime {
                knownLinks[eventTime, default: []].insert(value)
            }
        }

        var start = 0
        while start < current.count {
            let sender = current[start].sender
            let end = current.indices.dropFirst(start + 1).first {
                current[$0].timestamp != nil
                    || (current[$0].sender != "unknown" && current[$0].sender != sender)
            } ?? current.endIndex
            let group = current[start..<end]
            defer { start = end }
            guard group.contains(where: { $0.sender == "customer" && incremental.contains($0) }) else { continue }
            // Without a readable timestamp, retain the existing behavior;
            // never invent an age or suppress a potentially new customer message.
            guard let time = current[start].timestamp.flatMap(formatter.date(from:)) else { return true }
            let linkEnd = group.lastIndex { $0.sender == "customer" && $0.type == "link" }
            let knownLinkEnd = group.lastIndex {
                $0.sender == "customer" && $0.type == "link"
                    && $0.value.map { knownLinks[time]?.contains($0) == true } == true
            }
            for index in group.indices where current[index].sender == "customer" && incremental.contains(current[index]) {
                // This exact UI provenance label is not a customer request.
                if current[index].timestamp == nil,
                   current[index].value?.filter({ !$0.isWhitespace }) == "当前用户来自商品详情页" { continue }
                if let latestTime, time < latestTime,
                   index == start || linkEnd.map({ index <= $0 }) == true { continue }
                if let knownLinkEnd, index <= knownLinkEnd { continue }
                // Do not extend a card's age beyond its link footer: an
                // unrecognized header there could belong to a real new message.
                return true
            }
        }
        return false
    }

    private func incrementalMessages(
        current: [ParsedChatMessage],
        currentImageFingerprints: [String: String],
        previousHistory: Data?,
        userDirectory: URL
    ) throws -> [ParsedChatMessage] {
        guard !current.isEmpty else { return [] }
        guard let previousHistory, !previousHistory.isEmpty else { return current }
        let decoder = JSONDecoder()
        let historical = try previousHistory
            .split(separator: 0x0A)
            .map { try decoder.decode(HistoryEvent.self, from: Data($0)).message }
        let historicalSignatures = historical.map { message in
            MessageSignature(
                message,
                imageFingerprint: storedImageFingerprint(
                    path: message.path,
                    userDirectory: userDirectory
                )
            )
        }
        let currentSignatures = current.map { message in
            MessageSignature(
                message,
                imageFingerprint: message.path.flatMap { currentImageFingerprints[$0] }
            )
        }

        if currentSignatures.count <= historicalSignatures.count {
            for start in 0...(historicalSignatures.count - currentSignatures.count) {
                let end = start + currentSignatures.count
                if Array(historicalSignatures[start..<end]) == currentSignatures {
                    return []
                }
            }

            for start in 0...(historicalSignatures.count - currentSignatures.count) {
                var upgradedLinks: [ParsedChatMessage] = []
                var isSameVisibleWindow = true
                for index in currentSignatures.indices {
                    let old = historicalSignatures[start + index]
                    let new = currentSignatures[index]
                    if old == new { continue }
                    if isResolvedLinkUpgrade(old: old, new: new) {
                        upgradedLinks.append(current[index])
                    } else {
                        isSameVisibleWindow = false
                        break
                    }
                }
                if isSameVisibleWindow, !upgradedLinks.isEmpty {
                    return upgradedLinks
                }
            }
        }

        // A scrolled or slightly re-OCRed viewport can change an older leading
        // row while its latest timestamped messages are already in history.
        // Anchor on the newest exact timestamped message and only consider
        // messages after it. This prevents an unresolved unread marker from
        // repeatedly re-queuing the same visible tail while preserving a later
        // message (including identical text with a different timestamp).
        for index in current.indices.reversed() where current[index].timestamp != nil {
            if historicalSignatures.contains(currentSignatures[index]) {
                return Array(current.dropFirst(index + 1))
            }
        }

        let maximumOverlap = min(historicalSignatures.count, currentSignatures.count)
        if maximumOverlap > 0 {
            for overlap in stride(from: maximumOverlap, through: 1, by: -1) {
                if Array(historicalSignatures.suffix(overlap))
                    == Array(currentSignatures.prefix(overlap)) {
                    return Array(current.dropFirst(overlap))
                }
            }
        }
        return current
    }

    private func isResolvedLinkUpgrade(
        old: MessageSignature,
        new: MessageSignature
    ) -> Bool {
        guard old.sender == new.sender,
              old.type == "text",
              new.type == "link",
              old.timestamp == new.timestamp,
              old.readStatus == new.readStatus,
              old.normalizedPath == new.normalizedPath,
              let visible = old.value,
              visible.hasSuffix("..") || visible.contains("…"),
              let full = new.value,
              full.hasPrefix(normalizedVisibleLinkPrefix(visible)),
              let visibleHost = URLComponents(string: visible)?.host,
              let fullHost = URLComponents(string: full)?.host else {
            return false
        }
        return visibleHost.caseInsensitiveCompare(fullHost) == .orderedSame
    }

    private func removingPreviouslySeenLinksBeforeStableAnchor(
        from incremental: [ParsedChatMessage],
        current: [ParsedChatMessage],
        history: Data?
    ) throws -> [ParsedChatMessage] {
        guard let history, !history.isEmpty else { return incremental }
        let decoder = JSONDecoder()
        let historical = try history.split(separator: 0x0A).map { line in
            try decoder.decode(HistoryEvent.self, from: Data(line)).message
        }
        let historicalSignatures = historical.map { MessageSignature($0) }
        var nextIndex = current.startIndex

        return incremental.compactMap { message in
            guard nextIndex < current.endIndex,
                  let index = current[nextIndex...].firstIndex(of: message) else {
                return message
            }
            nextIndex = current.index(after: index)
            guard message.type == "link", let value = message.value else { return message }

            let linkWasSeen = historical.contains { historicalMessage in
                historicalMessage.type == "link"
                    && historicalMessage.sender == message.sender
                    && historicalMessage.value == value
            }
            let hasStableFollowingAnchor = current[current.index(after: index)...].contains {
                historicalSignatures.contains(MessageSignature($0))
            }
            return linkWasSeen && hasStableFollowingAnchor ? nil : message
        }
    }

    // A new text message can expose an old image that is still visible above
    // the latest service reply. Keep scanning images for image+text customer
    // turns, but never attach an image from the already-answered side of the
    // latest visible service boundary to that new turn.
    private func removingImagesBeforeLatestServiceBoundary(
        from incremental: [ParsedChatMessage],
        current: [ParsedChatMessage],
        history: Data?
    ) -> [ParsedChatMessage] {
        guard history?.isEmpty == false,
              let serviceBoundary = current.lastIndex(where: { $0.sender == "service" }) else {
            return incremental
        }

        var nextIndex = current.startIndex
        let indexed = incremental.map { message -> (ParsedChatMessage, Int?) in
            guard nextIndex < current.endIndex,
                  let index = current[nextIndex...].firstIndex(of: message) else {
                return (message, nil)
            }
            nextIndex = current.index(after: index)
            return (message, index)
        }
        let hasNewCustomerContentAfterService = indexed.contains { message, index in
            guard let index else { return false }
            return index > serviceBoundary
                && message.sender == "customer"
                && message.type != "image"
        }
        guard hasNewCustomerContentAfterService else { return incremental }

        return indexed.compactMap { message, index in
            guard message.sender == "customer",
                  message.type == "image",
                  let index,
                  index < serviceBoundary else {
                return message
            }
            return nil
        }
    }

    private func normalizedVisibleLinkPrefix(_ visible: String) -> String {
        var prefix = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        while prefix.hasSuffix(".") || prefix.hasSuffix("…") {
            prefix.removeLast()
        }
        return prefix
    }

    private func rewrittenMessages(
        correspondingTo incremental: [ParsedChatMessage],
        current: [ParsedChatMessage],
        rewritten: [ParsedChatMessage]
    ) -> [ParsedChatMessage] {
        var nextIndex = current.startIndex
        return incremental.map { message in
            guard nextIndex < current.endIndex,
                  let index = current[nextIndex...].firstIndex(of: message) else {
                return message
            }
            nextIndex = current.index(after: index)
            return rewritten[index]
        }
    }

    private func historyData(
        previous: Data?,
        requestID: String,
        createdAt: String,
        messages: [ParsedChatMessage]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let newLines = try messages.map { message in
            let event = HistoryEvent(
                requestID: requestID,
                createdAt: createdAt,
                sender: message.sender,
                type: message.type,
                value: message.value,
                path: message.path,
                timestamp: message.timestamp,
                readStatus: message.readStatus
            )
            return try encoder.encode(event) + Data([0x0A])
        }.reduce(into: Data(), { $0.append($1) })
        var combined = previous ?? Data()
        combined.append(newLines)
        return combined
    }

    private func readableHistoryData(from history: Data) throws -> Data {
        let decoder = JSONDecoder()
        let events = try history
            .split(separator: 0x0A)
            .map { try decoder.decode(HistoryEvent.self, from: Data($0)) }
        let text = events.map { event in
            let sender: String
            switch event.sender {
            case "customer": sender = "客户"
            case "service": sender = "客服"
            case "unknown": sender = "未知"
            default: sender = event.sender
            }
            let status = event.readStatus.map { "（\($0)）" } ?? ""
            let time = event.timestamp ?? event.createdAt
            let content: String
            if event.type == "image" {
                content = "[图片] \(event.path ?? "（路径未知）")"
            } else {
                content = event.value ?? ""
            }
            return "[\(time)] \(sender)\(status)\n\(content)\n\n"
        }.joined()
        return Data(text.utf8)
    }

    private func acquireExportLock() throws -> Int32 {
        let lockURL = rootDirectory.appendingPathComponent(".export.lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw CustomerRequestExportError.lockFailed(errno)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw CustomerRequestExportError.lockFailed(code)
        }
        return descriptor
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func defaultRootDirectory() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        return desktop.appendingPathComponent("AI客服记录", isDirectory: true)
    }

    private static func makeRequestID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }

    private func storedImageFingerprint(path: String?, userDirectory: URL) -> String? {
        guard let path,
              path.hasPrefix("images/"),
              !path.split(separator: "/").contains("..") else {
            return nil
        }
        let imagesDirectory = userDirectory
            .appendingPathComponent("images", isDirectory: true)
            .resolvingSymlinksInPath()
        let imageURL = userDirectory
            .appendingPathComponent(path)
            .resolvingSymlinksInPath()
        guard imageURL.path.hasPrefix(imagesDirectory.path + "/"),
              let data = try? Data(contentsOf: imageURL) else {
            return nil
        }
        return Self.hash(data)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CustomerQueuePointer: Codable {
    let uid: String
    let userDirectory: String
    let queuedAt: String
    let historyVersion: String
    let currentCustomerImagePaths: [String]

    enum CodingKeys: String, CodingKey {
        case uid
        case userDirectory = "user_directory"
        case queuedAt = "queued_at"
        case historyVersion = "history_version"
        case currentCustomerImagePaths = "current_customer_image_paths"
    }
}

private struct HistoryEvent: Codable {
    let requestID: String
    let createdAt: String
    let sender: String
    let type: String
    let value: String?
    let path: String?
    let timestamp: String?
    let readStatus: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case createdAt = "created_at"
        case sender
        case type = "t"
        case value = "v"
        case path = "p"
        case timestamp
        case readStatus = "read_status"
    }

    var message: ParsedChatMessage {
        ParsedChatMessage(
            sender: sender,
            type: type,
            value: value,
            path: path,
            timestamp: timestamp,
            readStatus: readStatus
        )
    }
}

private struct MessageSignature: Equatable {
    let sender: String
    let type: String
    let value: String?
    let normalizedPath: String?
    let timestamp: String?
    let readStatus: String?

    init(_ message: ParsedChatMessage, imageFingerprint: String? = nil) {
        sender = message.sender
        type = message.type
        value = message.value
        if message.type == "image", let imageFingerprint {
            normalizedPath = "image:\(imageFingerprint)"
        } else {
            normalizedPath = message.type == "image" ? "image" : message.path
        }
        timestamp = message.timestamp
        readStatus = message.readStatus
    }
}
