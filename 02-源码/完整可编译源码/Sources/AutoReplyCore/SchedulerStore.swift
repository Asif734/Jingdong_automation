import Foundation
import CryptoKit
import Darwin

public enum SchedulerStoreError: LocalizedError {
    case missingState, invalidState(String)
    public var errorDescription: String? {
        switch self {
        case .missingState: return "Existing scheduler directory is missing its persistent state"
        case .invalidState(let reason): return "Invalid scheduler state: \(reason)"
        }
    }
}

/// Single-writer checkpoint plus immutable archived evidence. The application owns its singleton lock.
public final class SchedulerStore: @unchecked Sendable {
    public let rootURL: URL
    public var stateURL: URL { rootURL.appendingPathComponent("state.json") }
    private var recordsURL: URL { rootURL.appendingPathComponent("archive/records", isDirectory: true) }
    private var eventsURL: URL { rootURL.appendingPathComponent("archive/events", isDirectory: true) }
    private var readableRepliesURL: URL { rootURL.appendingPathComponent("archive/replies", isDirectory: true) }
    private var cached: SchedulerPersistentState?
    private var checkpointIdentity: FileIdentity?
    private let readableReplyWriter: ((Data, URL) throws -> Void)?
    public private(set) var optionalWarnings: [String] = []
    private struct FileIdentity: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
    }
    private struct EventSegment: Codable {
        let firstSequence: Int
        let events: [SchedulerEvent]
    }

    public init(
        rootURL: URL,
        idleCursorResolver: ((String) throws -> CustomerCursor?)? = nil,
        legacySnapshotCursorResolver: ((String, String) throws -> CustomerCursor?)? = nil,
        legacyPendingResolver: ((String) throws -> Bool)? = nil,
        readableReplyWriter: ((Data, URL) throws -> Void)? = nil
    ) throws {
        self.rootURL = rootURL
        self.readableReplyWriter = readableReplyWriter
        if FileManager.default.fileExists(atPath: rootURL.path) {
            struct Header: Decodable { let schemaVersion: Int }
            guard FileManager.default.fileExists(atPath: stateURL.path) else { throw SchedulerStoreError.missingState }
            let data = try Data(contentsOf: stateURL)
            let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
            guard version == 2 || version == 3 || version == 4 || version == 5 else {
                throw SchedulerStoreError.invalidState("unsupported schema \(version); expected 2, 3, 4 or 5")
            }
            var state = try JSONDecoder().decode(SchedulerPersistentState.self, from: data)
            if version == 2 {
                state.answeredCursors = try recoveredSentCursors(
                    from: state,
                    legacySnapshotCursorResolver: legacySnapshotCursorResolver
                )
                for uid in Set(state.records.map(\.uid))
                    where state.answeredCursors[uid] == nil {
                    if let cursor = try idleCursorResolver?(uid) {
                        state.answeredCursors[uid] = cursor
                    }
                }
                // A schema-2 ready draft has no provable customer range. Never
                // send it or replay it using an empty cursor; recapture the live
                // history from the conservative migrated boundary instead.
                let activeUIDs = Set(state.records.filter { !$0.state.isTerminal }.map(\.uid))
                for index in state.records.indices {
                    switch state.records[index].state {
                    case .sending:
                        state.records[index].state = .uncertain
                        state.records[index].deliveryOutcome = .uncertain
                        state.records[index].attemptID = nil
                        state.records[index].lastError =
                            "Legacy send was in progress during migration; delivery remains uncertain"
                    case .uncertain:
                        state.records[index].deliveryOutcome = .uncertain
                        state.records[index].attemptID = nil
                    case .discovered, .capturing, .queued, .generating, .ready:
                        state.records[index].state = .discovered
                        state.records[index].snapshot = nil
                        state.records[index].pendingSupplement = nil
                        state.records[index].supplementCapturePending = nil
                        state.records[index].attemptID = nil
                        state.records[index].reply = nil
                        state.records[index].deliveryOutcome = nil
                        state.records[index].retries = 0
                        state.records[index].nextAttemptAt = .distantPast
                        state.records[index].lastError =
                            "Migrated legacy task; recapturing exact customer batch"
                        state.records[index].sessionStage = nil
                    case .completed, .superseded, .failed, .parked:
                        break
                    }
                }
                for uid in Set(state.records.map(\.uid)).sorted() where !activeUIDs.contains(uid) {
                    guard try legacyPendingResolver?(uid) ?? false else { continue }
                    state.records.append(SchedulerRecord(
                        uid: uid,
                        sequence: state.nextSequence,
                        state: .discovered,
                        createdAt: Date(),
                        updatedAt: Date(),
                        nextAttemptAt: .distantPast,
                        lastError: "Recovered durable pending pointer during schema migration"
                    ))
                    state.nextSequence += 1
                }
                state.schemaVersion = 3
                state.events.append(SchedulerEvent(
                    date: Date(),
                    uid: nil,
                    message: "Migrated scheduler checkpoint to schema 3 customer cursors"
                ))
            }
            if state.schemaVersion == 3 {
                state.schemaVersion = 4
                state.events.append(SchedulerEvent(
                    date: Date(), uid: nil,
                    message: "Migrated scheduler checkpoint to schema 4 bounded attempts"
                ))
            }
            if state.schemaVersion == 4 {
                state.schemaVersion = 5
                state.events.append(SchedulerEvent(
                    date: Date(), uid: nil,
                    message: "Migrated scheduler checkpoint to schema 5 typed transfer tasks"
                ))
            }
            try validate(state, checkpoint: true)
            // Startup reads summary metadata, never historical payloads. Missing evidence directories fail closed.
            for url in [recordsURL, eventsURL] {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { throw SchedulerStoreError.invalidState("missing archive directory") }
            }
            do {
                try FileManager.default.createDirectory(at: readableRepliesURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                optionalWarnings.append("Readable reply directory unavailable: \(error.localizedDescription)")
            }
            cached = state
            checkpointIdentity = try identity(stateURL)
            if version < 5 { try writeCheckpoint(state) }
        } else {
            for url in [rootURL, recordsURL, eventsURL] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
            }
            do {
                try FileManager.default.createDirectory(at: readableRepliesURL, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                optionalWarnings.append("Readable reply directory unavailable: \(error.localizedDescription)")
            }
            try writeCheckpoint(SchedulerPersistentState())
        }
    }

    /// O(1) metadata validation for an unchanged single-writer store. No checkpoint/archive decode per tick.
    public func load() throws -> SchedulerPersistentState {
        guard let cached, try identity(stateURL) == checkpointIdentity else {
            throw SchedulerStoreError.invalidState("checkpoint changed outside this store; reopen and inspect")
        }
        return cached
    }

    /// Save a value derived from load(). Active jobs retain full input; terminal jobs become summaries.
    public func save(_ state: SchedulerPersistentState) throws {
        let previous = try load()
        try validate(state, checkpoint: false)
        for (uid, oldCursor) in previous.answeredCursors {
            guard let nextCursor = state.answeredCursors[uid], nextCursor.count >= oldCursor.count else {
                throw SchedulerStoreError.invalidState("answered cursor cannot move backward for \(uid)")
            }
            if nextCursor.count == oldCursor.count, nextCursor != oldCursor {
                throw SchedulerStoreError.invalidState("answered cursor digest changed at same count for \(uid)")
            }
        }
        guard state.events.starts(with: previous.events), state.nextEventSequence == previous.nextEventSequence else {
            throw SchedulerStoreError.invalidState("events must append to the current checkpoint")
        }
        var next = state
        let priorByID = Dictionary(uniqueKeysWithValues: previous.records.map { ($0.id, $0) })
        for index in next.records.indices where next.records[index].state.isTerminal {
            if let prior = priorByID[next.records[index].id], let reference = prior.archiveReference {
                guard next.records[index].archiveReference == reference,
                      next.records[index].snapshot == nil, next.records[index].reply == nil,
                      next.records[index].pendingSupplement == nil,
                      next.records[index].supplementCapturePending == nil,
                      next.records[index].customerRevision == prior.customerRevision,
                      next.records[index].uid == prior.uid, next.records[index].state == prior.state,
                      next.records[index].deliveryOutcome == prior.deliveryOutcome else {
                    throw SchedulerStoreError.invalidState("archived job evidence is immutable")
                }
            } else {
                guard next.records[index].archiveReference == nil else {
                    throw SchedulerStoreError.invalidState("unknown archive reference")
                }
                let data = try encode(next.records[index])
                let digest = hash(data)
                let relative = "archive/records/\(next.records[index].id.uuidString)-\(digest).json"
                try writeEvidence(data, to: rootURL.appendingPathComponent(relative))
                do {
                    try writeReadableReply(for: next.records[index])
                } catch {
                    optionalWarnings.append("Readable reply sidecar failed for \(next.records[index].id): \(error.localizedDescription)")
                }
                next.records[index].archivedCustomerRevision = next.records[index].customerRevision
                next.records[index].archiveReference = SchedulerArchiveReference(relativePath: relative, sha256: digest, byteCount: data.count)
                next.records[index].snapshot = nil; next.records[index].pendingSupplement = nil
                next.records[index].supplementCapturePending = nil
                next.records[index].reply = nil
            }
        }
        let appendedEvents = Array(state.events.dropFirst(previous.events.count))
        if !appendedEvents.isEmpty {
            let data = try encode(EventSegment(firstSequence: previous.nextEventSequence, events: appendedEvents))
            let name = String(format: "%020d", previous.nextEventSequence) + "-\(UUID().uuidString)-\(hash(data)).json"
            try writeEvidence(data, to: eventsURL.appendingPathComponent(name))
            next.nextEventSequence += appendedEvents.count
        }
        next.events = Array(next.events.suffix(100))
        try validate(next, checkpoint: true)
        // Evidence is synchronized first. A crash here can leave orphan evidence, never a dangling checkpoint reference.
        try writeCheckpoint(next)
    }

    /// Explicit history access verifies bytes/hash before decoding; never used by the scheduling pump.
    public func archivedRecord(id: UUID) throws -> SchedulerRecord? {
        guard let summary = try load().records.first(where: { $0.id == id }), let reference = summary.archiveReference else { return nil }
        let data = try Data(contentsOf: rootURL.appendingPathComponent(reference.relativePath))
        guard data.count == reference.byteCount, hash(data) == reference.sha256 else {
            throw SchedulerStoreError.invalidState("archived record checksum mismatch")
        }
        let record = try JSONDecoder().decode(SchedulerRecord.self, from: data)
        guard record.id == id, record.uid == summary.uid, record.customerRevision == summary.customerRevision else {
            throw SchedulerStoreError.invalidState("archived record identity mismatch")
        }
        return record
    }

    /// Explicit audit access includes append-only evidence of attempted transitions, including crash-orphan segments.
    public func archivedEvents() throws -> [SchedulerEvent] {
        _ = try load()
        let urls = try FileManager.default.contentsOfDirectory(at: eventsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.flatMap { url in
            let data = try Data(contentsOf: url)
            let expected = String(url.deletingPathExtension().lastPathComponent.suffix(64))
            guard hash(data) == expected else { throw SchedulerStoreError.invalidState("event archive checksum mismatch") }
            return try JSONDecoder().decode(EventSegment.self, from: data).events
        }
    }

    private func recoveredSentCursors(
        from legacy: SchedulerPersistentState,
        legacySnapshotCursorResolver: ((String, String) throws -> CustomerCursor?)?
    ) throws -> [String: CustomerCursor] {
        var recovered: [String: CustomerCursor] = [:]
        let sent = legacy.records
            .filter { $0.state == .completed && $0.deliveryOutcome == .sent }
            .sorted { $0.sequence < $1.sequence }
        for summary in sent {
            let cursor: CustomerCursor?
            if let snapshot = summary.snapshot {
                cursor = try snapshot.endCursor
                    ?? legacySnapshotCursorResolver?(summary.uid, snapshot.historyJSONL)
            } else if let reference = summary.archiveReference {
                let url = rootURL.appendingPathComponent(reference.relativePath)
                let data = try Data(contentsOf: url)
                guard data.count == reference.byteCount, hash(data) == reference.sha256 else {
                    throw SchedulerStoreError.invalidState(
                        "cannot migrate sent cursor: archived record checksum mismatch"
                    )
                }
                let archived = try JSONDecoder().decode(SchedulerRecord.self, from: data)
                guard archived.id == summary.id, archived.uid == summary.uid,
                      archived.deliveryOutcome == .sent else {
                    throw SchedulerStoreError.invalidState(
                        "cannot migrate sent cursor: archived record identity mismatch"
                    )
                }
                if let snapshot = archived.snapshot {
                    cursor = try snapshot.endCursor
                        ?? legacySnapshotCursorResolver?(summary.uid, snapshot.historyJSONL)
                } else {
                    cursor = nil
                }
            } else {
                cursor = nil
            }
            if let cursor { recovered[summary.uid] = cursor }
        }
        return recovered
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func writeEvidence(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            // Only a retried identical content-addressed write may reuse existing immutable evidence.
            guard try Data(contentsOf: url) == data else { throw SchedulerStoreError.invalidState("existing archive differs") }
            return
        }
        try durableWrite(data, to: url)
    }

    /// A derived operator aid, never read by the scheduling loop and never a
    /// source of work. Immutable JSON remains the authoritative evidence.
    private func writeReadableReply(for record: SchedulerRecord) throws {
        guard let answer = record.reply?.replyText,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let outcome: String
        switch record.deliveryOutcome {
        case .sent: outcome = "已确认发送"
        case .notSent: outcome = "未发送"
        case .uncertain: outcome = "结果不确定（不可视为已发送）"
        case nil: outcome = "未确认（不可视为已发送）"
        }
        let content = """
        自动回复归档（只读，不是待发送队列）
        任务 ID: \(record.id.uuidString)
        客户 UID: \(record.uid)
        终态: \(record.state.rawValue)
        发送结果: \(outcome)
        回复内容:
        \(answer)
        """ + "\n"
        let data = Data(content.utf8)
        let url = readableRepliesURL.appendingPathComponent("\(record.id.uuidString).txt")
        if let readableReplyWriter {
            try readableReplyWriter(data, url)
        } else {
            try writeEvidence(data, to: url)
        }
    }

    private func writeCheckpoint(_ state: SchedulerPersistentState) throws {
        try durableWrite(encode(state), to: stateURL)
        checkpointIdentity = try identity(stateURL); cached = state
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw POSIXError(.EIO) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw POSIXError(.EIO) }
    }

    private func identity(_ url: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw SchedulerStoreError.missingState }
        guard info.st_mode & S_IFMT == S_IFREG else { throw SchedulerStoreError.invalidState("checkpoint is not a regular file") }
        return FileIdentity(inode: UInt64(info.st_ino), size: info.st_size,
                            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec,
                            changedSeconds: info.st_ctimespec.tv_sec, changedNanos: info.st_ctimespec.tv_nsec)
    }

    private func validate(_ value: SchedulerPersistentState, checkpoint: Bool) throws {
        guard value.schemaVersion == 5 else { throw SchedulerStoreError.invalidState("unsupported schema \(value.schemaVersion); expected 5") }
        guard value.answeredCursors.allSatisfy({ uid, cursor in
            !uid.isEmpty && cursor.count >= 0 && cursor.digest.count == 64
                && cursor.digest.unicodeScalars.allSatisfy {
                    ("0"..."9").contains(Character(String($0)))
                        || ("a"..."f").contains(Character(String($0)))
                }
        }) else { throw SchedulerStoreError.invalidState("invalid answered customer cursor") }
        guard value.nextSequence >= 0, value.nextEventSequence >= 0,
              Set(value.records.map(\.id)).count == value.records.count,
              Set(value.records.map(\.sequence)).count == value.records.count,
              value.records.allSatisfy({ !$0.uid.isEmpty && $0.sequence >= 0 && $0.sequence < value.nextSequence && $0.retries >= 0 })
        else { throw SchedulerStoreError.invalidState("invalid job identities/sequences") }
        let active = value.records.filter { !$0.state.isTerminal }
        let activeByUID = Dictionary(grouping: active, by: \.uid)
        guard activeByUID.values.allSatisfy({ records in
            records.filter {
                [.capturing, .generating, .sending, .uncertain].contains($0.state)
            }.count <= 1
        }) else {
            throw SchedulerStoreError.invalidState("multiple executing jobs for one UID")
        }
        for record in value.records {
            if let snapshot = record.snapshot, snapshot.uid != record.uid { throw SchedulerStoreError.invalidState("snapshot UID mismatch") }
            if let supplement = record.pendingSupplement, supplement.uid != record.uid { throw SchedulerStoreError.invalidState("supplement UID mismatch") }
            for snapshot in [record.snapshot, record.pendingSupplement].compactMap({ $0 }) {
                guard (snapshot.startCursor == nil) == (snapshot.endCursor == nil) else {
                    throw SchedulerStoreError.invalidState("incomplete customer cursor range")
                }
                if let start = snapshot.startCursor, let end = snapshot.endCursor, start.count > end.count {
                    throw SchedulerStoreError.invalidState("customer cursor range moves backward")
                }
            }
            if [.queued, .generating, .ready].contains(record.state), record.snapshot == nil { throw SchedulerStoreError.invalidState("missing immutable snapshot") }
            if record.state == .ready, record.reply == nil { throw SchedulerStoreError.invalidState("missing ready reply") }
            if let outcome = record.deliveryOutcome {
                switch outcome {
                case .sent:
                    guard record.state == .completed, record.reply != nil || record.archiveReference != nil else {
                        throw SchedulerStoreError.invalidState("invalid delivery outcome: confirmed send requires a completed reply")
                    }
                case .notSent:
                    guard record.state.isTerminal else {
                        throw SchedulerStoreError.invalidState("invalid delivery outcome: not-sent result requires a terminal record")
                    }
                case .uncertain:
                    guard record.state == .uncertain || record.state == .completed else {
                        throw SchedulerStoreError.invalidState("invalid delivery outcome: uncertain result requires reconciliation or completed release")
                    }
                }
            }
            if let reference = record.archiveReference {
                let expected = "archive/records/\(record.id.uuidString)-\(reference.sha256).json"
                guard record.state.isTerminal, record.snapshot == nil, record.reply == nil, reference.relativePath == expected,
                      record.pendingSupplement == nil, record.supplementCapturePending == nil,
                      reference.byteCount > 0, reference.sha256.count == 64,
                      reference.sha256.allSatisfy({ $0.isHexDigit }) else { throw SchedulerStoreError.invalidState("invalid archive reference") }
            } else if checkpoint && record.state.isTerminal { throw SchedulerStoreError.invalidState("terminal checkpoint lacks archive evidence") }
        }
    }
}
