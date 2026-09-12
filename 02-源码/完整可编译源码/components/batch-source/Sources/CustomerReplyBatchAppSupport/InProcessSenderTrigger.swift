import Foundation

public actor InProcessSenderTrigger: SenderTriggering {
    private let drain: @Sendable () async -> Void
    private var isDraining = false
    private var needsAnotherPass = false

    public init(drain: @escaping @Sendable () async -> Void) {
        self.drain = drain
    }

    public func trigger() async {
        if isDraining {
            needsAnotherPass = true
            return
        }

        isDraining = true
        repeat {
            needsAnotherPass = false
            await drain()
        } while needsAnotherPass
        isDraining = false
    }
}
