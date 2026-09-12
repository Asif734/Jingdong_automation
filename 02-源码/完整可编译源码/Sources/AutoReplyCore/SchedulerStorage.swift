import Foundation

/// The only runtime writer for the authoritative scheduler checkpoint.
///
/// `SchedulerStore` deliberately remains a synchronous, easily testable file
/// format implementation. This actor moves its file I/O off MainActor and
/// serializes every runtime save so UI callbacks cannot interleave checkpoint
/// mutations. Callers must await a successful save before starting a side
/// effect such as OCR, clicking, or sending.
public actor SchedulerStorage {
    private let store: SchedulerStore

    public init(store: SchedulerStore) {
        self.store = store
    }

    public func load() throws -> SchedulerPersistentState {
        try store.load()
    }

    public func saveAndReload(_ state: SchedulerPersistentState) throws -> SchedulerPersistentState {
        var repaired = state
        Self.repairOverlappingExecutions(in: &repaired, date: Date())
        try store.save(repaired)
        return try store.load()
    }

    /// Applies a transition to the actor's latest checkpoint, not to a caller's
    /// potentially stale UI snapshot. This is what makes overlapping Codex and
    /// UI completions serial rather than mutually destructive.
    public func commit(
        date: Date,
        message: String,
        uid: String?,
        change: (inout SchedulerPersistentState) -> Void
    ) throws -> SchedulerPersistentState {
        var next = try store.load()
        change(&next)
        next.events.append(SchedulerEvent(date: date, uid: uid, message: message))
        Self.repairOverlappingExecutions(in: &next, date: date)
        try store.save(next)
        return try store.load()
    }

    public func updateRecord(
        date: Date,
        message: String,
        id: UUID,
        expected: (SchedulerRecord) -> Bool,
        change: (inout SchedulerRecord) -> Void
    ) throws -> (state: SchedulerPersistentState, applied: Bool) {
        var next = try store.load()
        guard let index = next.records.firstIndex(where: { $0.id == id }),
              expected(next.records[index]) else {
            return (next, false)
        }
        let uid = next.records[index].uid
        change(&next.records[index])
        next.records[index].updatedAt = date
        next.events.append(SchedulerEvent(date: date, uid: uid, message: message))
        Self.repairOverlappingExecutions(in: &next, date: date)
        try store.save(next)
        return (try store.load(), true)
    }

    private static func repairOverlappingExecutions(
        in state: inout SchedulerPersistentState,
        date: Date
    ) {
        let executionStates: Set<SchedulerJobState> = [.capturing, .generating, .sending, .uncertain]
        let activeUIDs = Set(state.records.filter { !$0.state.isTerminal }.map(\.uid))
        for uid in activeUIDs {
            var indexes = state.records.indices.filter {
                state.records[$0].uid == uid && executionStates.contains(state.records[$0].state)
            }
            guard indexes.count > 1 else { continue }

            // A send driver may already have produced an external side effect.
            // Never put such work back into the queue where it could be sent twice.
            for index in indexes where state.records[index].state == .sending
                && state.records[index].sendWasInvoked == true {
                state.records[index].state = .completed
                state.records[index].deliveryOutcome = .uncertain
                state.records[index].attemptID = nil
                state.records[index].stageAttempt = nil
                state.records[index].pendingSupplement = nil
                state.records[index].supplementCapturePending = nil
                state.records[index].updatedAt = date
                state.records[index].nextAttemptAt = date
                state.records[index].lastError =
                    "Overlapping invoked send released as uncertain; not automatically resent"
            }

            indexes = state.records.indices.filter {
                state.records[$0].uid == uid && executionStates.contains(state.records[$0].state)
            }
            if indexes.count > 1 {
                let keeper = indexes.max { lhs, rhs in
                    let left = executionPriority(state.records[lhs])
                    let right = executionPriority(state.records[rhs])
                    if left == right {
                        return state.records[lhs].sequence > state.records[rhs].sequence
                    }
                    return left < right
                }
                for index in indexes where index != keeper {
                    switch state.records[index].state {
                    case .sending:
                        state.records[index].state = .ready
                    case .generating:
                        state.records[index].state = .queued
                    case .capturing:
                        state.records[index].state = .discovered
                    case .uncertain:
                        state.records[index].state = .completed
                        state.records[index].deliveryOutcome = .uncertain
                    default:
                        break
                    }
                    state.records[index].attemptID = nil
                    state.records[index].stageAttempt = nil
                    if !state.records[index].state.isTerminal {
                        state.records[index].sequence = state.nextSequence
                        state.nextSequence += 1
                    }
                    state.records[index].updatedAt = date
                    state.records[index].nextAttemptAt = date
                    state.records[index].lastError =
                        "Overlapping customer execution moved behind higher-priority work"
                }
            }
            state.events.append(SchedulerEvent(
                date: date,
                uid: uid,
                message: "Automatically repaired overlapping customer execution"
            ))
        }
    }

    private static func executionPriority(_ record: SchedulerRecord) -> Int {
        switch record.state {
        case .sending: return 3
        case .generating: return 2
        case .capturing: return 1
        case .uncertain: return 4
        default: return 0
        }
    }
}
