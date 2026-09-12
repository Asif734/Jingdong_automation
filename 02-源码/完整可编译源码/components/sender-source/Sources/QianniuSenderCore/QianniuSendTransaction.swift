import CryptoKit
import Foundation

public struct SendTransactionDeadlines: Sendable {
    public let press: Duration
    public let verification: Duration

    public init(press: Duration, verification: Duration) {
        self.press = press
        self.verification = verification
    }

    public static let live = SendTransactionDeadlines(
        press: .seconds(3),
        verification: .seconds(5)
    )
}

public protocol QianniuSendingSession: Sendable {
    func activate() async throws
    func isFrontmost() async throws -> Bool
    func searchAndOpen(uid: String) async throws
    func currentChatAssessment(expectedUID: String) async throws -> SendEvidenceAssessment
    func setMessageInput(_ text: String) async throws
    func messageInputAssessment(expectedText: String) async throws -> SendEvidenceAssessment
    func waitBeforeUnknownRecheck() async
    func recordMarkerWasWritten() async
    func pressSend() async throws
    func verifySent(text: String) async throws -> Bool
    /// Delayed observation only. Must never click send, continue a warning, or edit the composer.
    func recheckSent(text: String) async throws -> Bool
}

public struct QianniuSendTransaction<Session: QianniuSendingSession>: MessageSending, Sendable {
    private let session: Session
    private let deadlines: SendTransactionDeadlines

    public init(session: Session, deadlines: SendTransactionDeadlines = .live) {
        self.session = session
        self.deadlines = deadlines
    }

    public func send(uid: String, text: String, attemptMarkerURL: URL?) async -> SendOutcome {
        let expectedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedUID.isEmpty, !text.isEmpty else {
            return .failedBeforeSend("UID 或发送内容为空")
        }

        do {
            try await session.activate()
            try await session.searchAndOpen(uid: expectedUID)
            if case .confirmedWrong(let reason) = try await session.currentChatAssessment(expectedUID: expectedUID) {
                return .failedBeforeSend(reason)
            }
            try await session.setMessageInput(text)
            if let reason = try await preflightFailure(expectedUID: expectedUID, text: text) {
                return .failedBeforeSend(reason)
            }

            if try await !session.isFrontmost() {
                try await session.activate()
                if let reason = try await preflightFailure(expectedUID: expectedUID, text: text) {
                    return .failedBeforeSend(reason)
                }
            }

            let operationID = UUID()
            if let attemptMarkerURL {
                try writeAttemptMarker(
                    uid: expectedUID,
                    text: text,
                    operationID: operationID,
                    to: attemptMarkerURL
                )
                await session.recordMarkerWasWritten()
            }

            do {
                try await withSendDeadline(deadlines.press, stage: "发送点击") {
                    try await session.pressSend()
                }
            } catch let timeout as SendTransactionTimeout {
                return .uncertainAfterSend("\(timeout.stage)超时；发送动作可能已经发生，禁止自动重发")
            } catch {
                return .uncertainAfterSend("点击发送时状态不确定：\(error.localizedDescription)")
            }

            do {
                let confirmed = try await withSendDeadline(deadlines.verification, stage: "发送后确认") {
                    if try await session.verifySent(text: text) { return true }
                    return try await session.recheckSent(text: text)
                }
                if !confirmed {
                    return .uncertainAfterSend("已点击发送，延迟补查后仍未确认发送结果（输入框或会话状态未满足校验）")
                }
            } catch let timeout as SendTransactionTimeout {
                return .uncertainAfterSend("\(timeout.stage)超时；已点击一次且禁止自动重发")
            } catch {
                return .uncertainAfterSend("已点击发送，但验证失败：\(error.localizedDescription)")
            }
            return .sent
        } catch {
            return .failedBeforeSend(error.localizedDescription)
        }
    }

    private func preflightFailure(expectedUID: String, text: String) async throws -> String? {
        for attempt in 0...3 {
            let identity = try await session.currentChatAssessment(expectedUID: expectedUID)
            let input = try await session.messageInputAssessment(expectedText: text)
            if case .confirmedWrong(let reason) = identity { return reason }
            if case .confirmedWrong(let reason) = input { return reason }
            if identity == .confirmedCorrect, input == .confirmedCorrect { return nil }
            if attempt < 3 { await session.waitBeforeUnknownRecheck() }
        }
        return nil
    }

    private func writeAttemptMarker(uid: String, text: String, operationID: UUID, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = [
            "task_id": url.deletingPathExtension().lastPathComponent,
            "uid": uid,
            "text_sha256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            "operation_id": operationID.uuidString,
            "marked_at": ISO8601DateFormatter().string(from: Date()),
            "phase": "immediately_before_send_action",
            "send_was_invoked": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }
}

private struct SendTransactionTimeout: Error, Sendable {
    let stage: String
}

private final class SendDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func register(_ task: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved, let continuation else { lock.unlock(); return }
        resolved = true
        self.continuation = nil
        let tasks = self.tasks
        self.tasks.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation.resume(with: result)
    }
}

private func withSendDeadline<Value: Sendable>(
    _ duration: Duration,
    stage: String,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = SendDeadlineRace<Value>()
    return try await withCheckedThrowingContinuation { continuation in
        race.install(continuation)
        let operationTask = Task {
            do { race.resolve(.success(try await operation())) }
            catch { race.resolve(.failure(error)) }
        }
        race.register(operationTask)
        let deadlineTask = Task {
            do {
                try await Task.sleep(for: duration)
                race.resolve(.failure(SendTransactionTimeout(stage: stage)))
            } catch {}
        }
        race.register(deadlineTask)
    }
}
