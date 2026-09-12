import Foundation

enum AutomationDesiredState: String, Codable, Sendable {
    case running
    case stopped
}

struct AutomationRunIntent: Codable, Equatable, Sendable {
    var desiredState: AutomationDesiredState
    var aliases: [String]

    static let stoppedDefault = AutomationRunIntent(
        desiredState: .stopped,
        aliases: []
    )
}

struct AutomationRunIntentStore: Sendable {
    let url: URL

    func load() throws -> AutomationRunIntent {
        guard FileManager.default.fileExists(atPath: url.path) else { return .stoppedDefault }
        return try JSONDecoder().decode(AutomationRunIntent.self, from: Data(contentsOf: url))
    }

    func save(_ intent: AutomationRunIntent) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(intent).write(to: url, options: .atomic)
    }
}

enum StartRetryPolicy {
    static func delay(afterFailureCount count: Int) -> TimeInterval {
        let values: [TimeInterval] = [1, 2, 5, 10, 30]
        return values[min(max(0, count), values.count - 1)]
    }
}
