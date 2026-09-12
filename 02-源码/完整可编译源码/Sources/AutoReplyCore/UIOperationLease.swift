import Foundation

public struct UIOperationLease: Equatable, Sendable {
    public let operationID: UUID
    public let epoch: UInt64
    public let uid: String

    public init(operationID: UUID = UUID(), epoch: UInt64, uid: String) {
        self.operationID = operationID
        self.epoch = epoch
        self.uid = uid
    }
}

/// A tiny synchronous registry so Stop can invalidate UI authority before it
/// returns to the caller. UI operations may await for seconds, but revocation
/// itself must never wait for the actor that owns those operations.
public final class UIOperationLeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var current: UIOperationLease?

    public init() {}

    public func acquire(uid: String) -> UIOperationLease {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        let lease = UIOperationLease(epoch: epoch, uid: uid)
        current = lease
        return lease
    }

    public func isValid(_ lease: UIOperationLease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == lease
    }

    public func revokeAll() {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        current = nil
    }
}
