import Foundation

final class BoundedLocalFileReader: @unchecked Sendable {
    let timeout: TimeInterval
    private let readOperation: @Sendable (URL) throws -> Data
    private let queue = DispatchQueue(
        label: "com.scy.qianniu-autoreply.history-reader",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var pathsBeingRead: Set<String> = []

    init(
        timeout: TimeInterval = 2,
        readOperation: @escaping @Sendable (URL) throws -> Data = {
            try Data(contentsOf: $0, options: .mappedIfSafe)
        }
    ) {
        self.timeout = timeout
        self.readOperation = readOperation
    }

    func read(_ source: URL) async throws -> Data {
        let path = source.standardizedFileURL.path
        let startedReading = lock.withLock { pathsBeingRead.insert(path).inserted }
        guard startedReading else {
            throw CustomerRequestExportError.historyReadTimedOut
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completion = DataReadCompletion(continuation)
            queue.async { [self] in
                let result = Result { try readOperation(source) }
                _ = lock.withLock { pathsBeingRead.remove(path) }
                _ = completion.finish(result)
            }
            Task.detached { [timeout] in
                let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                _ = completion.finish(.failure(CustomerRequestExportError.historyReadTimedOut))
            }
        }
    }
}

private final class DataReadCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private let continuation: CheckedContinuation<Data, Error>

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ result: Result<Data, Error>) -> Bool {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return false
        }
        didFinish = true
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
