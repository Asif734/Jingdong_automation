import Foundation
import Darwin
import CustomerReplyBatchCore

public enum CodexDeadlinePolicy {
    public static let production: (soft: Duration, hard: Duration) = (
        .seconds(90), .seconds(300)
    )
}

public protocol ReplyGenerating: Sendable {
    func generate(for input: PromptInput) async throws -> GeneratedReply
}

public struct ReplyGenerationTiming: Equatable, Sendable {
    public let model: String?
    public let reasoningEffort: String?
    public let loginCheckMilliseconds: Double
    public let codexExecMilliseconds: Double
    public let decodeMilliseconds: Double
    public let totalMilliseconds: Double
    public let cliTraceReportPath: String?
    public let sessionMode: String?
    public let submittedHistoryBytes: Int
    public let submittedImageCount: Int
    public let sessionLeaseAgeMilliseconds: Double?
    public let sessionRecoveryCount: Int

    public init(
        model: String? = nil,
        reasoningEffort: String? = nil,
        loginCheckMilliseconds: Double = 0,
        codexExecMilliseconds: Double = 0,
        decodeMilliseconds: Double = 0,
        totalMilliseconds: Double = 0,
        cliTraceReportPath: String? = nil,
        sessionMode: String? = nil,
        submittedHistoryBytes: Int = 0,
        submittedImageCount: Int = 0,
        sessionLeaseAgeMilliseconds: Double? = nil,
        sessionRecoveryCount: Int = 0
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.loginCheckMilliseconds = loginCheckMilliseconds
        self.codexExecMilliseconds = codexExecMilliseconds
        self.decodeMilliseconds = decodeMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.cliTraceReportPath = cliTraceReportPath
        self.sessionMode = sessionMode
        self.submittedHistoryBytes = submittedHistoryBytes
        self.submittedImageCount = submittedImageCount
        self.sessionLeaseAgeMilliseconds = sessionLeaseAgeMilliseconds
        self.sessionRecoveryCount = sessionRecoveryCount
    }
}

public struct GeneratedReply: Sendable {
    public let reply: ReplyEnvelope
    public let sessionID: String?
    public let timing: ReplyGenerationTiming
    /// Keeps the batch/process slot alive after the validated reply is handed off.
    public let cleanupTask: Task<Void, Never>?

    public init(
        reply: ReplyEnvelope,
        sessionID: String? = nil,
        timing: ReplyGenerationTiming = ReplyGenerationTiming(),
        cleanupTask: Task<Void, Never>? = nil
    ) {
        self.reply = reply
        self.sessionID = sessionID
        self.timing = timing
        self.cleanupTask = cleanupTask
    }
}

public enum CodexGeneratorError: LocalizedError {
    case executableMissing
    case chatGPTLoginRequired(String)
    case commandFailed(Int32, String)
    case invalidReply(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing: return "未找到本机 Codex CLI"
        case .chatGPTLoginRequired(let status): return "Codex 必须使用 ChatGPT 登录，当前状态：\(status)"
        case .commandFailed(let code, let message): return "Codex 退出码 \(code)：\(message)"
        case .invalidReply(let message): return "Codex 返回无效：\(message)"
        }
    }
}

public enum KnowledgeRetrievalFailurePolicy: Sendable {
    case fallbackToFullInput
    case failClosed
}

public struct CodexReplyGenerator: ReplyGenerating {
    public static let model = "gpt-5.6-sol"
    public static let reasoningEffort = "medium"
    public let executableURL: URL
    public let schemaURL: URL
    private let loginCache: CodexLoginCache
    private let traceDirectory: URL?
    private let codexHomeURL: URL?
    private let workingDirectoryURL: URL?
    private let sessionRegistry: CodexSessionRegistry
    private let generationGate: UIDGenerationGate
    private let knowledgeBaseVersioner: KnowledgeBaseVersioner
    private let knowledgeRetriever: (any KnowledgeContextRetrieving)?
    private let retrievalFailurePolicy: KnowledgeRetrievalFailurePolicy
    private let loginDeadlines: (soft: Duration, hard: Duration)
    private let codexDeadlines: (soft: Duration, hard: Duration)
    private let now: @Sendable () -> Date

    public init(
        executableURL: URL = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"
        ),
        schemaURL: URL? = nil,
        loginCache: CodexLoginCache = CodexLoginCache(),
        traceDirectory: URL? = nil,
        codexHomeURL: URL? = nil,
        workingDirectoryURL: URL? = nil,
        sessionRegistry: CodexSessionRegistry? = nil,
        generationGate: UIDGenerationGate = UIDGenerationGate(),
        knowledgeBaseVersioner: KnowledgeBaseVersioner = KnowledgeBaseVersioner(),
        knowledgeRetriever: (any KnowledgeContextRetrieving)? = nil,
        retrievalFailurePolicy: KnowledgeRetrievalFailurePolicy = .fallbackToFullInput,
        loginDeadlines: (soft: Duration, hard: Duration) = (.seconds(1), .seconds(5)),
        codexDeadlines: (soft: Duration, hard: Duration) = CodexDeadlinePolicy.production,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.executableURL = executableURL
        self.schemaURL = schemaURL ?? Self.resolveDefaultSchemaURL()
        self.loginCache = loginCache
        self.traceDirectory = traceDirectory
        self.codexHomeURL = codexHomeURL
        self.workingDirectoryURL = workingDirectoryURL
        self.sessionRegistry = sessionRegistry ?? CodexSessionRegistry(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-customer-sessions-\(UUID().uuidString).json")
        )
        self.generationGate = generationGate
        self.knowledgeBaseVersioner = knowledgeBaseVersioner
        self.knowledgeRetriever = knowledgeRetriever
        self.retrievalFailurePolicy = retrievalFailurePolicy
        self.loginDeadlines = loginDeadlines
        self.codexDeadlines = codexDeadlines
        self.now = now
    }

    static func resolveDefaultSchemaURL(
        executablePath: String = CommandLine.arguments[0],
        fallback: () -> URL? = {
            Bundle.module.url(forResource: "reply-output.schema", withExtension: "json")
        }
    ) -> URL {
        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        let candidate = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(
                "QianniuCodexBatchRunner_CustomerReplyBatchAppSupport.bundle",
                isDirectory: true
            )
            .appendingPathComponent("reply-output.schema.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        guard let bundled = fallback() else {
            preconditionFailure("缺少 reply-output.schema.json")
        }
        return bundled
    }

    public func generate(for input: PromptInput) async throws -> GeneratedReply {
        let knowledgeBaseVersion = try await knowledgeBaseVersioner.version(
            paths: input.knowledgeBasePaths
        )
        let preparedInput: PromptInput
        if let knowledgeRetriever {
            do {
                let knowledge = try await knowledgeRetriever.retrieve(
                    historyJSONL: V2KnowledgeRetriever.focusedHistoryJSONL(
                        fullHistoryJSONL: input.historyJSONL,
                        targetCustomerJSONL: input.targetCustomerJSONL
                    ),
                    knowledgeBasePaths: input.knowledgeBasePaths
                )
                preparedInput = PromptBuilder.addingRetrievedKnowledge(knowledge, to: input)
            } catch {
                switch retrievalFailurePolicy {
                case .fallbackToFullInput:
                    preparedInput = input
                case .failClosed:
                    throw error
                }
            }
        } else {
            preparedInput = input
        }
        return try await generationGate.withPermit(for: input.uid) {
            try await generateWithSession(
                for: preparedInput,
                knowledgeBaseVersion: knowledgeBaseVersion
            )
        }
    }

    private func generateWithSession(
        for input: PromptInput,
        knowledgeBaseVersion: String
    ) async throws -> GeneratedReply {
        let currentDate = now()
        var plan = try await sessionRegistry.plan(
            uid: input.uid,
            promptVersion: PromptBuilder.contractVersion,
            knowledgeBaseVersion: knowledgeBaseVersion,
            at: currentDate
        )
        var submission = try input.preservesHistoryCheckpoint
            ? HistoryContinuation.planExternalEvidence(input: input, preserving: plan.checkpoint)
            : HistoryContinuation.plan(input: input, after: plan.checkpoint)
        var sessionMode = plan.requiresCreation ? "new" : "resumed"

        if !input.preservesHistoryCheckpoint, !plan.requiresCreation, submission.mode == .full {
            try await sessionRegistry.invalidate(uid: input.uid)
            plan = .create
            submission = try HistoryContinuation.plan(input: input, after: nil)
            sessionMode = "rehydrated"
        }

        if let sessionID = plan.sessionID {
            let leaseAge = max(
                0,
                currentDate.timeIntervalSince(plan.binding?.lastActivityAt ?? currentDate) * 1_000
            )
            do {
                let generated = try await runTurn(
                    for: input,
                    submission: submission,
                    mode: .resume(sessionID: sessionID),
                    prompt: PromptBuilder.buildContinuation(input, submission: submission),
                    metadata: SessionExecutionMetadata(
                        mode: sessionMode,
                        leaseAgeMilliseconds: leaseAge,
                        recoveryCount: 0
                    )
                )
                guard generated.sessionID == nil || generated.sessionID == sessionID else {
                    throw CodexGeneratorError.invalidReply("恢复会话返回了不匹配的会话 ID")
                }
                try await sessionRegistry.commit(
                    uid: input.uid,
                    sessionID: sessionID,
                    checkpoint: submission.checkpoint,
                    promptVersion: PromptBuilder.contractVersion,
                    knowledgeBaseVersion: knowledgeBaseVersion,
                    at: now()
                )
                return generated
            } catch {
                try await sessionRegistry.invalidate(uid: input.uid)
                let full = try HistoryContinuation.plan(input: input, after: nil)
                return try await createAndCommit(
                    input: input,
                    submission: full,
                    knowledgeBaseVersion: knowledgeBaseVersion,
                    sessionMode: "recovered",
                    recoveryCount: 1
                )
            }
        }

        return try await createAndCommit(
            input: input,
            submission: submission,
            knowledgeBaseVersion: knowledgeBaseVersion,
            sessionMode: sessionMode,
            recoveryCount: 0
        )
    }

    private func createAndCommit(
        input: PromptInput,
        submission: HistorySubmission,
        knowledgeBaseVersion: String,
        sessionMode: String,
        recoveryCount: Int
    ) async throws -> GeneratedReply {
        let generated = try await runTurn(
            for: input,
            submission: submission,
            mode: .create,
            prompt: PromptBuilder.buildInitial(input, submission: submission),
            metadata: SessionExecutionMetadata(
                mode: sessionMode,
                leaseAgeMilliseconds: nil,
                recoveryCount: recoveryCount
            )
        )
        guard let sessionID = generated.sessionID,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexGeneratorError.invalidReply("CLI 未返回新建客户会话 ID")
        }
        try await sessionRegistry.commit(
            uid: input.uid,
            sessionID: sessionID,
            checkpoint: submission.checkpoint,
            promptVersion: PromptBuilder.contractVersion,
            knowledgeBaseVersion: knowledgeBaseVersion,
            recoveryCount: recoveryCount,
            at: now()
        )
        return generated
    }

    private func runTurn(
        for input: PromptInput,
        submission: HistorySubmission,
        mode: CodexTurnMode,
        prompt: String,
        metadata: SessionExecutionMetadata
    ) async throws -> GeneratedReply {
        try await Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let totalStart = clock.now
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw CodexGeneratorError.executableMissing }
            let loginStart = clock.now
            try await loginCache.ensureLoggedIn {
                try await Self.verifyChatGPTLogin(
                    executableURL: executableURL,
                    environment: codexEnvironment(),
                    codexHomeURL: codexHomeURL,
                    deadlines: loginDeadlines
                )
            }
            let loginMilliseconds = milliseconds(from: loginStart, to: clock.now)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("codex-reply-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            var cleanupTransferred = false
            defer {
                if !cleanupTransferred { try? FileManager.default.removeItem(at: temporary) }
            }
            let resultURL = temporary.appendingPathComponent("result.json")
            let arguments = CodexInvocation(
                mode: mode,
                model: Self.model,
                reasoningEffort: Self.reasoningEffort,
                schemaURL: schemaURL,
                resultURL: resultURL,
                workingDirectoryURL: workingDirectoryURL,
                imagePaths: submission.imagePaths
            ).arguments
            let environment = codexEnvironment()

            let trace = CodexExecutionTrace(directory: traceDirectory, input: input)
            let execStart = clock.now
            let cleanup = DispatchGroup()
            cleanup.enter()
            let cleanupTask = Task<Void, Never> {
                await withCheckedContinuation { continuation in
                    cleanup.notify(queue: .global(qos: .utility)) { continuation.resume() }
                }
            }
            let stream = CLIReplyStream()
            cleanupTransferred = true
            return try await withCheckedThrowingContinuation { continuation in
                let handoff = CLIReplyHandoff(continuation)
                @Sendable func generated(
                    _ reply: ReplyEnvelope,
                    sessionID: String?,
                    exec: Double,
                    decode: Double
                ) -> GeneratedReply {
                    GeneratedReply(reply: reply, sessionID: sessionID, timing: ReplyGenerationTiming(
                        model: Self.model, reasoningEffort: Self.reasoningEffort,
                        loginCheckMilliseconds: loginMilliseconds, codexExecMilliseconds: exec,
                        decodeMilliseconds: decode, totalMilliseconds: milliseconds(from: totalStart, to: clock.now),
                        cliTraceReportPath: trace.reportURL?.path,
                        sessionMode: metadata.mode,
                        submittedHistoryBytes: Data(submission.historyJSONL.utf8).count,
                        submittedImageCount: submission.imagePaths.count,
                        sessionLeaseAgeMilliseconds: metadata.leaseAgeMilliseconds,
                        sessionRecoveryCount: metadata.recoveryCount
                    ), cleanupTask: cleanupTask)
                }
                let processTask = Task.detached(priority: .userInitiated) {
                    await BoundedProcess.run(
                        .init(
                            executable: executableURL,
                            arguments: arguments,
                            environment: environment,
                            standardInput: Data(prompt.utf8),
                            onStandardOutput: { chunk in
                                let elapsed = milliseconds(from: execStart, to: clock.now)
                                trace.consume(chunk, elapsed: elapsed)
                                let decodeStart = clock.now
                                stream.consume(chunk) { reply, sessionID in
                                    trace.replyReady(elapsed: milliseconds(from: execStart, to: clock.now))
                                    handoff.offer(generated(
                                        reply,
                                        sessionID: sessionID,
                                        exec: elapsed,
                                        decode: milliseconds(from: decodeStart, to: clock.now)
                                    ))
                                }
                            }
                        ),
                        softDeadline: codexDeadlines.soft,
                        hardDeadline: codexDeadlines.hard
                    )
                }
                // A valid completed turn can only be emitted after the CLI consumed stdin.
                // Marking this immediately allows that validated answer to hand off while
                // the bounded process reaper independently finishes.
                handoff.didWriteInput()
                Task.detached(priority: .utility) {
                    let processResult = await processTask.value
                    stream.finish()
                    let execMilliseconds = milliseconds(from: execStart, to: clock.now)
                    let exitCode: Int32
                    switch processResult.termination {
                    case .exited(let code): exitCode = code
                    case .hardDeadline: exitCode = 124
                    case .launchFailed(let code, _): exitCode = code == 0 ? -1 : code
                    }
                    trace.finish(elapsed: execMilliseconds, exitCode: exitCode)
                    let final: Result<GeneratedReply, Error> = Result {
                        switch processResult.termination {
                        case .exited(0): break
                        case .exited(let code):
                            let message = String(data: processResult.stderr, encoding: .utf8) ?? "未知错误"
                            throw CodexGeneratorError.commandFailed(code, String(message.suffix(4_000)))
                        case .hardDeadline:
                            let message = String(data: processResult.stderr, encoding: .utf8) ?? ""
                            throw CodexGeneratorError.commandFailed(124, "超过 Codex 硬时限；\(String(message.suffix(4_000)))")
                        case .launchFailed(_, let message):
                            throw CodexGeneratorError.commandFailed(-1, message)
                        }
                        guard !stream.turnFailed else { throw CodexGeneratorError.invalidReply("CLI 本轮生成失败") }
                        let decodeStart = clock.now
                        let data = try Data(contentsOf: resultURL)
                        let decodedReply = try JSONDecoder().decode(ReplyEnvelope.self, from: data)
                        let reply = try ReplyRoutingPolicy.normalize(decodedReply)
                        return generated(
                            reply,
                            sessionID: stream.threadID,
                            exec: execMilliseconds,
                            decode: milliseconds(from: decodeStart, to: clock.now)
                        )
                    }
                    try? FileManager.default.removeItem(at: temporary)
                    cleanup.leave()
                    // After early handoff, later shutdown errors remain in the trace and
                    // must never re-publish or requeue the already accepted reply.
                    handoff.finish(final)
                }
            }
        }.value
    }

    private static func verifyChatGPTLogin(
        executableURL: URL,
        environment: [String: String],
        codexHomeURL: URL?,
        deadlines: (soft: Duration, hard: Duration)
    ) async throws {
        let result = await BoundedProcess.run(
            .init(executable: executableURL, arguments: ["login", "status"], environment: environment),
            softDeadline: deadlines.soft,
            hardDeadline: deadlines.hard
        )
        let text = String(data: result.stdout + result.stderr, encoding: .utf8) ?? "未知"
        guard result.termination == .exited(0), text.contains("Logged in using ChatGPT") else {
            let location = codexHomeURL.map {
                "未能从本机已登录的 Codex 自动继承凭证，请为客服隔离目录 \($0.path) 完成一次授权；"
            } ?? ""
            throw CodexGeneratorError.chatGPTLoginRequired(
                location + text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func codexEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        if let codexHomeURL {
            environment["CODEX_HOME"] = codexHomeURL.path
        }
        return environment
    }
}

private func milliseconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
) -> Double {
    let components = start.duration(to: end).components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private struct SessionExecutionMetadata: Sendable {
    let mode: String
    let leaseAgeMilliseconds: Double?
    let recoveryCount: Int
}
