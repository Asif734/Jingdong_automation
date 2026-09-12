import Foundation

public struct RefreshSnapshot: Equatable, Sendable {
    public let fingerprint: String
    public let isEnabled: Bool
    public let isBusy: Bool

    public init(fingerprint: String, isEnabled: Bool, isBusy: Bool) {
        self.fingerprint = fingerprint
        self.isEnabled = isEnabled
        self.isBusy = isBusy
    }
}

public enum RefreshWaitDecision: Equatable, Sendable {
    case wait
    case proceedNoChange
    case proceedStable
    case proceedTimeout
}

public enum RefreshStabilityPolicy {
    public static func decision(
        initial: RefreshSnapshot,
        samples: [(elapsedMilliseconds: Int, snapshot: RefreshSnapshot)]
    ) -> RefreshWaitDecision {
        guard let latest = samples.last else { return .wait }

        if latest.elapsedMilliseconds >= 3_000 {
            return .proceedTimeout
        }

        let stateChanged = samples.contains { $0.snapshot != initial }
        if !stateChanged, latest.elapsedMilliseconds >= 1_200 {
            return .proceedNoChange
        }

        guard stateChanged,
              latest.elapsedMilliseconds >= 500,
              samples.count >= 2 else {
            return .wait
        }

        let previous = samples[samples.count - 2].snapshot
        if previous == latest.snapshot,
           latest.snapshot.isEnabled,
           !latest.snapshot.isBusy {
            return .proceedStable
        }

        return .wait
    }
}
