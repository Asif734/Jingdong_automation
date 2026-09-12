import CustomerReplyBatchAppSupport
import Foundation
import QianniuOCRAppSupport

protocol CodexReadinessChecking: Sendable {
    func codexState() async throws -> CodexLoginState
    func runNoToolGenerationProbe() async throws
}

actor LiveCodexReadinessProbe: CodexReadinessChecking {
    private struct ProbeResult: Decodable { let ready: Bool }

    private let login: CodexLoginCoordinator
    private let codexURL: URL
    private let codexHomeURL: URL
    private let workingDirectoryURL: URL

    init(
        login: CodexLoginCoordinator,
        codexURL: URL,
        codexHomeURL: URL,
        workingDirectoryURL: URL
    ) {
        self.login = login
        self.codexURL = codexURL
        self.codexHomeURL = codexHomeURL
        self.workingDirectoryURL = workingDirectoryURL
    }

    func codexState() async throws -> CodexLoginState {
        try await login.status()
    }

    func runNoToolGenerationProbe() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("qianniu-codex-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let schemaURL = temporary.appendingPathComponent("schema.json")
        let resultURL = temporary.appendingPathComponent("result.json")
        let schema = """
        {"type":"object","properties":{"ready":{"type":"boolean"}},"required":["ready"],"additionalProperties":false}
        """
        try Data(schema.utf8).write(to: schemaURL, options: .atomic)
        let invocation = CodexInvocation(
            mode: .create,
            model: CodexReplyGenerator.model,
            reasoningEffort: CodexReplyGenerator.reasoningEffort,
            schemaURL: schemaURL,
            resultURL: resultURL,
            workingDirectoryURL: workingDirectoryURL,
            imagePaths: []
        )
        let prompt = "只输出 JSON：{\"ready\":true}。不得调用工具、命令、文件、Skill、网络或知识库。"
        let result = await BoundedProcess.run(
            .init(
                executable: codexURL,
                arguments: invocation.arguments,
                environment: CodexLoginCoordinator.dedicatedEnvironment(codexHomeURL: codexHomeURL),
                standardInput: Data(prompt.utf8),
                currentDirectory: workingDirectoryURL
            ),
            softDeadline: .seconds(30),
            hardDeadline: .seconds(120)
        )
        guard result.termination == .exited(0) else {
            throw CodexGeneratorError.commandFailed(
                resultExitCode(result.termination),
                String(decoding: result.stderr.suffix(4_000), as: UTF8.self)
            )
        }
        let stream = String(decoding: result.stdout, as: UTF8.self)
        let forbiddenKinds = ["command_execution", "mcp_tool_call", "web_search", "file_change"]
        guard forbiddenKinds.allSatisfy({ !stream.contains("\"type\":\"\($0)\"") }) else {
            throw CodexGeneratorError.invalidReply("Codex 就绪探针调用了禁止的工具")
        }
        let decoded = try JSONDecoder().decode(ProbeResult.self, from: Data(contentsOf: resultURL))
        guard decoded.ready else {
            throw CodexGeneratorError.invalidReply("Codex 就绪探针未返回 ready=true")
        }
    }

    private func resultExitCode(_ termination: BoundedProcessTermination) -> Int32 {
        switch termination {
        case let .exited(code): return code
        case .hardDeadline: return 124
        case let .launchFailed(code, _): return code == 0 ? -1 : code
        }
    }
}

enum ReadinessPrewarmError: LocalizedError, Equatable {
    case codexLoginRequired(String)

    var errorDescription: String? {
        switch self {
        case let .codexLoginRequired(reason):
            return reason.isEmpty ? "请登录 Codex" : reason
        }
    }
}

actor ReadinessPrewarmer: ReadinessPrewarming {
    private let ocr: any OCRPrewarming
    private let knowledge: any KnowledgePrewarming
    private let knowledgeBasePaths: [String]
    private let speech: any VideoSpeechPrewarming
    private let codex: any CodexReadinessChecking
    private var preparationTask: Task<[String: CapabilityStatus], Error>?
    private var cachedStatuses: [String: CapabilityStatus]?

    init(
        ocr: any OCRPrewarming,
        knowledge: any KnowledgePrewarming,
        knowledgeBasePaths: [String],
        speech: any VideoSpeechPrewarming,
        codex: any CodexReadinessChecking
    ) {
        self.ocr = ocr
        self.knowledge = knowledge
        self.knowledgeBasePaths = knowledgeBasePaths
        self.speech = speech
        self.codex = codex
    }

    func prepare() async throws -> [String: CapabilityStatus] {
        if let cachedStatuses { return cachedStatuses }
        if let preparationTask { return try await preparationTask.value }

        let ocr = ocr
        let knowledge = knowledge
        let knowledgeBasePaths = knowledgeBasePaths
        let speech = speech
        let codex = codex
        let task = Task<[String: CapabilityStatus], Error> {
            try await ocr.prepareOCR()
            let knowledgePreparation = try await knowledge.prepare(
                knowledgeBasePaths: knowledgeBasePaths
            )
            try await speech.prepareSpeechRecognition()
            let codexState = try await codex.codexState()
            guard case .loggedIn = codexState else {
                if case let .loginRequired(reason) = codexState {
                    throw ReadinessPrewarmError.codexLoginRequired(reason)
                }
                throw ReadinessPrewarmError.codexLoginRequired("")
            }
            try await codex.runNoToolGenerationProbe()

            let lexicalFallback = knowledgePreparation.version.localizedCaseInsensitiveContains("lexical")
            return [
                "ocr": CapabilityStatus(
                    level: .verified,
                    strategy: "warmed-live-engine",
                    detail: "OCR 模型已预热"
                ),
                "v2": CapabilityStatus(
                    level: lexicalFallback ? .fallback : .verified,
                    strategy: lexicalFallback ? "lexical-fallback" : "persistent-top12",
                    detail: lexicalFallback ? "知识库处于关键词降级模式" : "知识库 Top-12 已就绪"
                ),
                "speech": CapabilityStatus(
                    level: .verified,
                    strategy: "persistent-sensevoice-int8",
                    detail: "SenseVoice 中文语音兜底已预热"
                ),
                "codex": CapabilityStatus(
                    level: .verified,
                    strategy: "isolated-no-tool-probe",
                    detail: "Codex 登录和无工具生成探针已通过"
                )
            ]
        }
        preparationTask = task
        do {
            let statuses = try await task.value
            cachedStatuses = statuses
            preparationTask = nil
            return statuses
        } catch {
            preparationTask = nil
            throw error
        }
    }
}
