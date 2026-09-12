import Foundation

struct OCRStageTimeout: Error, Equatable, Sendable {
    let stage: String
}

struct OCRExecutionDeadlines: Sendable {
    let capture: Duration
    let recognition: Duration
    let linkResolution: Duration
    let imageResolution: Duration

    static let live = OCRExecutionDeadlines(
        capture: .seconds(3),
        recognition: .seconds(16),
        linkResolution: .seconds(10),
        imageResolution: .seconds(10)
    )
}

private final class OCRDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.withLock { self.continuation = continuation }
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

@MainActor
func withOCRDeadline<Value: Sendable>(
    _ duration: Duration,
    stage: String,
    operation: @escaping @MainActor @Sendable () async throws -> Value
) async throws -> Value {
    let race = OCRDeadlineRace<Value>()
    return try await withCheckedThrowingContinuation { continuation in
        race.install(continuation)
        let operationTask = Task { @MainActor in
            do { race.resolve(.success(try await operation())) }
            catch { race.resolve(.failure(error)) }
        }
        race.register(operationTask)
        let deadlineTask = Task {
            do {
                try await Task.sleep(for: duration)
                race.resolve(.failure(OCRStageTimeout(stage: stage)))
            } catch {}
        }
        race.register(deadlineTask)
    }
}
