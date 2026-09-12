public struct SendVerificationStability: Sendable {
    private let requiredConsecutiveChecks: Int
    private var consecutiveClearChecks = 0

    public init(requiredConsecutiveChecks: Int) {
        self.requiredConsecutiveChecks = max(1, requiredConsecutiveChecks)
    }

    public mutating func record(clearSuccessCandidate: Bool, warningVisible: Bool) -> Bool {
        guard clearSuccessCandidate, !warningVisible else {
            consecutiveClearChecks = 0
            return false
        }
        consecutiveClearChecks += 1
        return consecutiveClearChecks >= requiredConsecutiveChecks
    }
}
