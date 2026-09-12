import Foundation

/// A task group would wait forever for a non-cooperative screenshot request on scope exit.
/// This race bounds the caller; a late screenshot can only complete this gate, never click.
@MainActor enum CaptureDeadline {
    private static var inFlight = false
    static func run(timeout: Duration, operation: @escaping @MainActor () async throws -> PixelImage) async throws -> PixelImage {
        guard !inFlight else { throw AssistantError.unsafe("上一张截图仍未返回；请稍后重试，持续无响应可重新打开助手。") }
        let gate = Gate()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                inFlight = true
                gate.continuation = continuation
                gate.worker = Task { @MainActor in
                    defer { inFlight = false }
                    do { try Task.checkCancellation(); gate.finish(.success(try await operation())) }
                    catch { gate.finish(.failure(error)) }
                }
                gate.timer = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    gate.finish(.failure(AssistantError.unsafe("截图超时；未点击，请重试。")))
                }
            }
        } onCancel: {
            Task { @MainActor in gate.finish(.failure(CancellationError())) }
        }
    }
    @MainActor private final class Gate {
        var continuation: CheckedContinuation<PixelImage, Error>?
        var worker: Task<Void, Never>?
        var timer: Task<Void, Never>?
        func finish(_ result: Result<PixelImage, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            worker?.cancel(); timer?.cancel()
            worker = nil; timer = nil
            continuation.resume(with: result)
        }
    }
}
