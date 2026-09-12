import Foundation

public enum FailureDisposition: Equatable, Sendable {
    case requeueTail
    case park
}

public enum TaskFailurePolicy {
    public static func uiDisposition(previousFailures: Int) -> FailureDisposition {
        previousFailures <= 0 ? .requeueTail : .park
    }
}
