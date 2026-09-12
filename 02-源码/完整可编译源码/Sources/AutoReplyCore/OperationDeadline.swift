import Foundation

public struct OperationTimeout: Error, Equatable, LocalizedError, Sendable {
    public let stage: String

    public init(stage: String) {
        self.stage = stage
    }

    public var errorDescription: String? {
        "Operation timed out: \(stage)"
    }
}

private final class OperationRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
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
        guard !resolved, let continuation else {
            lock.unlock()
            return
        }
        resolved = true
        self.continuation = nil
        let tasks = self.tasks
        self.tasks.removeAll()
        lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation.resume(with: result)
    }
}

public func withOperationDeadline<Value: Sendable>(
    _ duration: Duration,
    stage: String,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = OperationRace<Value>()
    return try await withCheckedThrowingContinuation { continuation in
        race.install(continuation)

        let operationTask = Task {
            do {
                race.resolve(.success(try await operation()))
            } catch {
                race.resolve(.failure(error))
            }
        }
        race.register(operationTask)

        let deadlineTask = Task {
            do {
                try await Task.sleep(for: duration)
                race.resolve(.failure(OperationTimeout(stage: stage)))
            } catch {
                return
            }
        }
        race.register(deadlineTask)
    }
}
