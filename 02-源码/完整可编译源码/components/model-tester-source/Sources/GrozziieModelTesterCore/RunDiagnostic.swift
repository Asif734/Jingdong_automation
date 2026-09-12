import Foundation
import CustomerReplyBatchAppSupport

public struct RunDiagnostic: Equatable, Sendable {
    public let model: String
    public let reasoningEffort: String
    public let loginCheckMilliseconds: Double
    public let codexMilliseconds: Double
    public let totalMilliseconds: Double
    public let sessionMode: String
    public let submittedHistoryBytes: Int
    public let submittedImageCount: Int

    public init(
        model: String,
        reasoningEffort: String,
        loginCheckMilliseconds: Double,
        codexMilliseconds: Double,
        totalMilliseconds: Double,
        sessionMode: String,
        submittedHistoryBytes: Int,
        submittedImageCount: Int
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.loginCheckMilliseconds = loginCheckMilliseconds
        self.codexMilliseconds = codexMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.sessionMode = sessionMode
        self.submittedHistoryBytes = submittedHistoryBytes
        self.submittedImageCount = submittedImageCount
    }

    public init(timing: ReplyGenerationTiming) {
        self.model = timing.model ?? ModelConfiguration.production.model
        self.reasoningEffort = timing.reasoningEffort ?? ModelConfiguration.production.reasoningEffort
        self.loginCheckMilliseconds = timing.loginCheckMilliseconds
        self.codexMilliseconds = timing.codexExecMilliseconds
        self.totalMilliseconds = timing.totalMilliseconds
        self.sessionMode = timing.sessionMode ?? "unknown"
        self.submittedHistoryBytes = timing.submittedHistoryBytes
        self.submittedImageCount = timing.submittedImageCount
    }
}

public struct ModelTestResult: Sendable {
    public let answer: String
    public let diagnostic: RunDiagnostic
    public let citations: [String]

    public init(answer: String, diagnostic: RunDiagnostic, citations: [String] = []) {
        self.answer = answer
        self.diagnostic = diagnostic
        self.citations = citations
    }
}
