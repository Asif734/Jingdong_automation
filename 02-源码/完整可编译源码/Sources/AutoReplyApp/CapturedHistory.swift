import Foundation
import AutoReplyCore

enum ReadStatusTransition {
    static func isUnreadToRead(_ old: [String?], _ new: [String?]) -> Bool {
        var advanced = false
        for (previous, current) in zip(old, new) where previous != current {
            guard previous == "未读", current == "已读" else { return false }
            advanced = true
        }
        return advanced
    }
}
import CryptoKit
import Darwin

struct CapturedHistory {
    let root: URL
    var knowledgeBasePaths: [String]

    init(root: URL, knowledgeBasePaths: [String] = []) {
        self.root = root
        self.knowledgeBasePaths = knowledgeBasePaths
    }

    func currentCursor(uid: String) throws -> CustomerCursor {
        let directory = try userDirectory(uid)
        let historyURL = directory.appendingPathComponent("history.jsonl")
        let data = FileManager.default.fileExists(atPath: historyURL.path)
            ? try Data(contentsOf: historyURL)
            : Data()
        return try cursor(uid: uid, historyJSONL: String(decoding: data, as: UTF8.self))
    }

    func cursor(uid: String, historyJSONL: String) throws -> CustomerCursor {
        let directory = try userDirectory(uid)
        return try timeline(
            historyData: Data(historyJSONL.utf8),
            directory: directory
        ).currentCursor
    }

    /// Conservative schema-2 upgrade boundary: only customer events observed
    /// before the latest service reply are known to have been answered. A later
    /// customer tail remains eligible for recapture.
    func migrationBaselineCursor(uid: String) throws -> CustomerCursor {
        let directory = try userDirectory(uid)
        let historyURL = directory.appendingPathComponent("history.jsonl")
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return .empty }
        let lines = try Data(contentsOf: historyURL).split(separator: 0x0A)
        let events = try lines.map { try JSONDecoder().decode(Event.self, from: Data($0)) }
        guard let lastService = events.lastIndex(where: { $0.sender == "service" }) else {
            return .empty
        }
        var prefix = Data()
        for line in lines.prefix(lastService + 1) {
            prefix.append(contentsOf: line)
            prefix.append(0x0A)
        }
        return try timeline(historyData: prefix, directory: directory).currentCursor
    }

    func hasPendingCommit(uid: String) throws -> Bool {
        _ = try userDirectory(uid)
        return FileManager.default.fileExists(
            atPath: root.appendingPathComponent("待处理/\(uid).json").path
        )
    }

    func snapshot(uid: String, latestSpeaker: String?, newlyQueued: Bool) throws -> CaptureSnapshot {
        let directory = try userDirectory(uid)
        let historyURL = directory.appendingPathComponent("history.jsonl")
        let data = FileManager.default.fileExists(atPath: historyURL.path) ? try Data(contentsOf: historyURL) : Data()
        let events = try decode(data)
        let revision = try customerRevision(events, directory: directory)
        let pending = try pendingCommit(uid: uid, history: data)
        guard latestSpeaker != nil || pending == nil else {
            throw HistoryError.invalid("本次未识别到客户或客服消息；保留待处理请求，等待重新采集")
        }
        // Attach only images belonging to the currently committed customer turn.
        // history.jsonl still carries the complete conversation; resubmitting every
        // historical image on each text reply both duplicates evidence and makes an
        // old picture look new to Codex.
        let currentImagePaths: [String]
        if let pending {
            currentImagePaths = pending.currentCustomerImagePaths ?? []
        } else if newlyQueued,
                  let latest = events.last(where: { $0.sender == "customer" && $0.type == "image" })?.path {
            currentImagePaths = [latest]
        } else {
            currentImagePaths = []
        }
        let imagePaths = try frozenImagePaths(currentImagePaths, directory: directory)
        guard let jsonl = String(data: data, encoding: .utf8) else { throw HistoryError.invalid("history.jsonl 不是 UTF-8") }
        let queuedCustomerImage = newlyQueued && (
            pending?.currentCustomerImagePaths?.isEmpty == false
                || (pending?.currentCustomerImagePaths == nil
                    && events.last(where: { $0.sender == "customer" })?.type == "image")
        )
        return CaptureSnapshot(uid: uid, customerRevision: revision, historyJSONL: jsonl,
            imagePaths: imagePaths, knowledgeBasePaths: knowledgeBasePaths,
            hasUnansweredCustomer: latestSpeaker == "customer" || queuedCustomerImage,
            shouldGenerate: newlyQueued || pending?.revision == revision)
    }

    func snapshot(
        uid: String,
        latestSpeaker: String?,
        newlyQueued: Bool,
        after answeredCursor: CustomerCursor
    ) throws -> CaptureSnapshot {
        let directory = try userDirectory(uid)
        let historyURL = directory.appendingPathComponent("history.jsonl")
        let data = FileManager.default.fileExists(atPath: historyURL.path)
            ? try Data(contentsOf: historyURL)
            : Data()
        // Keep validating the durable exporter pointer when one exists. The
        // visible tail speaker is diagnostic only; cursor boundaries decide work.
        _ = try pendingCommit(uid: uid, history: data)
        let timeline = try timeline(historyData: data, directory: directory)
        let batch = try timeline.batch(after: answeredCursor)
        let imagePaths = try frozenImagePaths(batch.imageRelativePaths, directory: directory)
        guard let jsonl = String(data: data, encoding: .utf8) else {
            throw HistoryError.invalid("history.jsonl 不是 UTF-8")
        }
        let hasTarget = batch.endCursor != batch.startCursor
        return CaptureSnapshot(
            uid: uid,
            customerRevision: batch.endCursor.digest,
            historyJSONL: jsonl,
            imagePaths: imagePaths,
            knowledgeBasePaths: knowledgeBasePaths,
            hasUnansweredCustomer: hasTarget,
            shouldGenerate: hasTarget && (batch.hasNonImageContent || !imagePaths.isEmpty),
            targetCustomerJSONL: batch.targetJSONL,
            startCursor: batch.startCursor,
            endCursor: batch.endCursor
        )
    }

    /// An unavailable attachment must not discard usable text/link events from
    /// the same customer batch. Unsafe paths remain fatal; only a validated
    /// attachment whose bytes cannot be read or frozen is skipped locally.
    private func frozenImagePaths(_ relativePaths: [String], directory: URL) throws -> [String] {
        var imagePaths: [String] = []
        var attachedHashes = Set<String>()
        for path in relativePaths {
            let source = try imageURL(path, directory: directory)
            guard let bytes = try? Data(contentsOf: source) else { continue }
            let fingerprint = Self.hash(bytes)
            guard attachedHashes.insert(fingerprint).inserted else { continue }
            let target = root.appendingPathComponent("运行状态/调度器/frozen-images/\(fingerprint).jpg")
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: target.path) {
                    guard try Data(contentsOf: target) == bytes else { continue }
                } else {
                    try bytes.write(to: target, options: .atomic)
                }
                imagePaths.append(target.path)
            } catch {
                continue
            }
        }
        return imagePaths
    }

    /// Called only after the scheduler has durably completed this revision. The
    /// export lock and exact pointer-byte comparison protect a newer handoff.
    func complete(uid: String, revision: String) throws {
        try complete(uid: uid, completedRevisions: [revision])
    }

    /// A status refresh may restore many completed records for one UID. Resolve
    /// the current exporter pointer once, then compare it with all completed
    /// revisions in memory instead of reparsing history once per old record.
    func complete(uid: String, completedRevisions: Set<String>) throws {
        guard !completedRevisions.isEmpty else { return }
        _ = try userDirectory(uid)
        let descriptor = root.appendingPathComponent(".export.lock").path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw HistoryError.invalid("无法打开导出锁") }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { return } // Next status refresh retries acknowledgement.
            throw HistoryError.invalid("无法取得导出锁以确认完成")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        let pointerURL = root.appendingPathComponent("待处理/\(uid).json")
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return }
        let original = try Data(contentsOf: pointerURL)
        let history = try Data(contentsOf: userDirectory(uid).appendingPathComponent("history.jsonl"))
        guard let pending = try pendingCommit(uid: uid, history: history),
              completedRevisions.contains(pending.revision) || completedRevisions.contains(pending.cursor.digest),
              try Data(contentsOf: pointerURL) == original else { return }
        try FileManager.default.removeItem(at: pointerURL)
    }

    static func validUID(_ uid: String) -> Bool {
        !uid.isEmpty && uid.count <= 256 && uid == uid.trimmingCharacters(in: .whitespacesAndNewlines)
            && uid != "." && uid != ".." && !uid.contains("/") && !uid.contains("\\")
            && !uid.contains("...") && !uid.contains("…") && !uid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private func userDirectory(_ uid: String) throws -> URL {
        guard Self.validUID(uid) else { throw HistoryError.invalid("拒绝不完整或不安全的 UID") }
        let directory = root.appendingPathComponent("用户/\(uid)")
        guard directory.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/用户/") else {
            throw HistoryError.invalid("用户路径超出隔离目录")
        }
        return directory
    }
    private func imageURL(_ path: String?, directory: URL) throws -> URL {
        guard let path, path.hasPrefix("images/"), !path.split(separator: "/").contains("..") else {
            throw HistoryError.invalid("无效的聊天图片路径")
        }
        let url = directory.appendingPathComponent(path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(directory.resolvingSymlinksInPath().appendingPathComponent("images").path + "/") else {
            throw HistoryError.invalid("聊天图片路径超出用户目录")
        }
        return url
    }
    private func timeline(historyData: Data, directory: URL) throws -> CustomerEventTimeline {
        try CustomerEventTimeline(
            historyData: historyData,
            userDirectory: directory,
            imageIdentityResolver: { path in
                try imageIdentity(path: path, directory: directory)
            }
        )
    }
    private func imageIdentity(path: String, directory: URL) throws -> String {
        let source = try imageURL(path, directory: directory)
        let identitiesRoot = root.appendingPathComponent(
            "运行状态/调度器/image-identities",
            isDirectory: true
        )
        let identities = identitiesRoot.appendingPathComponent(
            Self.hash(Data(directory.standardizedFileURL.path.utf8)),
            isDirectory: true
        )
        let manifest = identities.appendingPathComponent(Self.hash(Data(path.utf8)) + ".txt")
        if FileManager.default.fileExists(atPath: source.path) {
            let identity = Self.hash(try Data(contentsOf: source))
            try FileManager.default.createDirectory(
                at: identities,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let stored = FileManager.default.fileExists(atPath: manifest.path)
                ? try String(contentsOf: manifest, encoding: .utf8)
                : nil
            if stored != identity {
                try durableWriteIdentity(identity, to: manifest, identitiesRoot: identitiesRoot)
            }
            return identity
        }
        if FileManager.default.fileExists(atPath: manifest.path) {
            let stored = try String(contentsOf: manifest, encoding: .utf8)
            guard stored.count == 64 || (stored.hasPrefix("missing:") && stored.count == 72) else {
                throw HistoryError.invalid("历史图片身份记录损坏")
            }
            return stored
        }
        let identity = "missing:" + Self.hash(Data(path.utf8))
        try FileManager.default.createDirectory(
            at: identities,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try durableWriteIdentity(identity, to: manifest, identitiesRoot: identitiesRoot)
        return identity
    }
    private func durableWriteIdentity(
        _ identity: String,
        to manifest: URL,
        identitiesRoot: URL
    ) throws {
        try Data(identity.utf8).write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifest.path
        )
        let handle = try FileHandle(forWritingTo: manifest)
        defer { try? handle.close() }
        try handle.synchronize()
        for directory in [
            manifest.deletingLastPathComponent(),
            identitiesRoot,
            identitiesRoot.deletingLastPathComponent(),
        ] {
            let descriptor = Darwin.open(directory.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { _ = Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        }
    }
    private func pendingCommit(uid: String, history: Data) throws -> PendingCommit? {
        let url = root.appendingPathComponent("待处理/\(uid).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let pointer = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: url))
        let directory = try userDirectory(uid)
        guard pointer.uid == uid, URL(fileURLWithPath: pointer.userDirectory).standardizedFileURL == directory.standardizedFileURL else {
            throw HistoryError.invalid("待处理指针身份或目录不一致")
        }
        // History is append-only. Match the exact committed bytes, including newline,
        // instead of guessing that a stale pointer refers to the current viewport.
        var prefix = Data()
        var hash = SHA256()
        for line in history.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
            let bytes = Data(line) + Data([0x0A]); prefix.append(bytes); hash.update(data: bytes)
            let candidate = hash.finalize().map { String(format: "%02x", $0) }.joined()
            if candidate == pointer.historyVersion {
                let committedEvents = try decode(prefix)
                if let paths = pointer.currentCustomerImagePaths {
                    let committedCustomerImages = Set(committedEvents.compactMap { event in
                        event.sender == "customer" && event.type == "image" ? event.path : nil
                    })
                    guard paths.allSatisfy(committedCustomerImages.contains) else {
                        throw HistoryError.invalid("待处理图片不属于已提交的客户消息")
                    }
                }
                return PendingCommit(
                    revision: try customerRevision(committedEvents, directory: directory),
                    cursor: try timeline(historyData: prefix, directory: directory).currentCursor,
                    currentCustomerImagePaths: pointer.currentCustomerImagePaths
                )
            }
        }
        throw HistoryError.invalid("待处理指针无法匹配已提交的历史版本；请检查隔离记录")
    }
    private func decode(_ data: Data) throws -> [Event] {
        try data.split(separator: 0x0A).map { try JSONDecoder().decode(Event.self, from: Data($0)) }
    }
    private func customerRevision(_ events: [Event], directory: URL) throws -> String {
        var ordinals: [String: Int] = [:]
        var batches: [[Observation]] = []
        for event in events where event.sender == "customer" {
            let ordinal = ordinals[event.requestID, default: 0]; ordinals[event.requestID] = ordinal + 1
            let content = event.type == "image"
                ? try imageIdentity(path: event.path ?? "", directory: directory)
                : event.value
            let identity = Identity(requestID: event.requestID, ordinal: ordinal, type: event.type, timestamp: event.timestamp, content: content)
            let observation = Observation(identity: identity, readStatus: event.readStatus)
            if batches.last?.last?.identity.requestID == event.requestID { batches[batches.count - 1].append(observation) }
            else { batches.append([observation]) }
        }
        var canonical: [Observation] = []
        for batch in batches {
            var isReadStatusOnlyDuplicate = false
            if canonical.count >= batch.count {
                for start in 0...(canonical.count - batch.count) {
                    let old = Array(canonical[start..<(start + batch.count)])
                    let sameEvidence = zip(old, batch).allSatisfy { $0.identity.type == $1.identity.type
                        && $0.identity.timestamp == $1.identity.timestamp && $0.identity.content == $1.identity.content }
                    let acknowledged = ReadStatusTransition.isUnreadToRead(
                        old.map(\.readStatus), batch.map(\.readStatus)
                    )
                    if sameEvidence && acknowledged {
                        // Opening the conversation can flip the same visible batch
                        // from unread to read before the next exporter pass. Treat
                        // that status-only observation as the already-known batch.
                        isReadStatusOnlyDuplicate = true
                        break
                    }
                }
            }
            if isReadStatusOnlyDuplicate { continue }
            canonical.append(contentsOf: batch)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Self.hash(try encoder.encode(canonical.map(\.identity)))
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private struct Identity: Encodable {
        let requestID: String; let ordinal: Int; let type: String; let timestamp: String?; let content: String?
    }
    private struct Observation { let identity: Identity; let readStatus: String? }
    private struct Event: Decodable {
        let requestID: String; let sender: String; let type: String; let value: String?; let path: String?; let timestamp: String?; let readStatus: String?
        enum CodingKeys: String, CodingKey {
            case requestID = "request_id", sender, type = "t", value = "v", path = "p", timestamp, readStatus = "read_status"
        }
    }
    private struct Pending: Decodable {
        let uid: String; let userDirectory: String; let historyVersion: String; let currentCustomerImagePaths: [String]?
        enum CodingKeys: String, CodingKey {
            case uid, userDirectory = "user_directory", historyVersion = "history_version"
            case currentCustomerImagePaths = "current_customer_image_paths"
        }
    }
    private struct PendingCommit {
        let revision: String
        let cursor: CustomerCursor
        let currentCustomerImagePaths: [String]?
    }
}

enum HistoryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
