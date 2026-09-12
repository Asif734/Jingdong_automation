import Foundation

public struct RetrievedKnowledge: Codable, Sendable, Equatable {
    public let version: String
    public let documents: [String]
    public let context: String
}

public protocol KnowledgeContextRetrieving: Sendable {
    func retrieve(historyJSONL: String, knowledgeBasePaths: [String]) async throws -> RetrievedKnowledge
}

public struct KnowledgePreparation: Sendable, Equatable {
    public let version: String

    public init(version: String) { self.version = version }
}

public protocol KnowledgePrewarming: Sendable {
    func prepare(knowledgeBasePaths: [String]) async throws -> KnowledgePreparation
    func shutdown() async
}

public enum KnowledgeRetrieverError: LocalizedError {
    case unavailable(String)
    case failed(Int32, String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let value): return "V2 知识库检索器不可用：\(value)"
        case .failed(let code, let value): return "V2 知识库检索失败（\(code)）：\(value)"
        case .invalidOutput(let value): return "V2 知识库检索结果无效：\(value)"
        }
    }
}

/// One serialized local embedding process prevents concurrent customer tasks from
/// loading several copies of the ONNX model into memory. Codex generation remains concurrent.
public actor V2KnowledgeRetriever: KnowledgeContextRetrieving, KnowledgePrewarming {
    public let pythonURL: URL
    public let scriptURL: URL
    public let workerScriptURL: URL?
    public let sitePackagesURL: URL
    public let seedCacheURL: URL
    public let writableCacheURL: URL
    public let knowledgeBaseSHA256: String
    public let indexRootURL: URL
    public let indexAlgorithmVersion: String
    private let deadlines: (soft: Duration, hard: Duration)
    private let startupDeadline: Duration
    private let queryDeadline: Duration
    private var worker: PersistentJSONLWorker?
    private var workerVersion: String?

    public init(
        pythonURL: URL,
        scriptURL: URL,
        workerScriptURL: URL? = nil,
        sitePackagesURL: URL,
        seedCacheURL: URL,
        writableCacheURL: URL,
        knowledgeBaseSHA256: String = String(repeating: "0", count: 64),
        indexRootURL: URL? = nil,
        indexAlgorithmVersion: String = "v2-index-1",
        deadlines: (soft: Duration, hard: Duration) = (.seconds(2), .seconds(5)),
        startupDeadline: Duration = .seconds(120),
        queryDeadline: Duration = .seconds(5)
    ) {
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
        self.workerScriptURL = workerScriptURL
        self.sitePackagesURL = sitePackagesURL
        self.seedCacheURL = seedCacheURL
        self.writableCacheURL = writableCacheURL
        self.knowledgeBaseSHA256 = knowledgeBaseSHA256
        self.indexRootURL = indexRootURL ?? writableCacheURL.appendingPathComponent("indexes")
        self.indexAlgorithmVersion = indexAlgorithmVersion
        self.deadlines = deadlines
        self.startupDeadline = startupDeadline
        self.queryDeadline = queryDeadline
    }

    public static func live(bundle: Bundle = .main) -> V2KnowledgeRetriever? {
        guard let resources = bundle.resourceURL else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QianniuAutoReply", isDirectory: true)
        return live(resourcesURL: resources, applicationSupportURL: support)
    }

    public static func live(
        resourcesURL resources: URL,
        applicationSupportURL: URL,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> V2KnowledgeRetriever? {
        let root = resources.appendingPathComponent("V2Knowledge", isDirectory: true)
        let python = resources.appendingPathComponent("Python.framework/Versions/3.12/bin/python3.12")
        let script = root.appendingPathComponent("retrieve_top12.py")
        let packages = root.appendingPathComponent("site-packages", isDirectory: true)
        let seed = root.appendingPathComponent("cache", isDirectory: true)
        guard isExecutable(python),
              FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: packages.path),
              FileManager.default.fileExists(atPath: seed.path) else { return nil }
        return V2KnowledgeRetriever(
            pythonURL: python,
            scriptURL: script,
            sitePackagesURL: packages,
            seedCacheURL: seed,
            writableCacheURL: applicationSupportURL.appendingPathComponent("V2KnowledgeCache", isDirectory: true)
        )
    }

    static func pythonEnvironment(
        base: [String: String],
        sitePackagesURL: URL
    ) -> [String: String] {
        var environment = base
        environment["PYTHONPATH"] = sitePackagesURL.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        return environment
    }

    public func retrieve(historyJSONL: String, knowledgeBasePaths: [String]) async throws -> RetrievedKnowledge {
        let knowledgeBasePath = try knowledgeBasePath(from: knowledgeBasePaths)
        guard let workerScriptURL else {
            return try await retrieveOneShot(historyJSONL: historyJSONL, knowledgeBasePath: knowledgeBasePath)
        }
        var lastError: Error = PersistentWorkerError.closed
        for attempt in 0...1 {
            do {
                let active = try await prepareWorker(script: workerScriptURL, knowledgeBasePath: knowledgeBasePath)
                let requestID = UUID().uuidString
                let request = try JSONSerialization.data(withJSONObject: [
                    "id": requestID,
                    "history_jsonl": historyJSONL,
                ])
                let data = try await active.request(request)
                let response = try JSONDecoder().decode(WorkerResponse.self, from: data)
                guard response.id == requestID, response.ok, let result = response.result else {
                    throw KnowledgeRetrieverError.invalidOutput(response.error ?? "响应 ID 不匹配")
                }
                guard ["v2-top12", "v2-lexical-only"].contains(result.version),
                      !result.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw KnowledgeRetrieverError.invalidOutput("常驻 worker 返回空知识上下文")
                }
                return result
            } catch {
                lastError = error
                if let worker { await worker.stop() }
                worker = nil
                workerVersion = nil
                if attempt == 1 { break }
            }
        }
        throw lastError
    }

    public func prepare(knowledgeBasePaths: [String]) async throws -> KnowledgePreparation {
        guard let workerScriptURL else {
            throw KnowledgeRetrieverError.unavailable("未配置常驻 V2 worker")
        }
        let path = try knowledgeBasePath(from: knowledgeBasePaths)
        _ = try await prepareWorker(script: workerScriptURL, knowledgeBasePath: path)
        guard let workerVersion else {
            throw KnowledgeRetrieverError.invalidOutput("常驻 worker 未报告版本")
        }
        return KnowledgePreparation(version: workerVersion)
    }

    public func shutdown() async {
        if let worker { await worker.stop() }
        worker = nil
        workerVersion = nil
    }

    private func knowledgeBasePath(from paths: [String]) throws -> String {
        guard let path = paths.first(where: {
            $0.lowercased().hasSuffix(".zip") && FileManager.default.fileExists(atPath: $0)
        }) else { throw KnowledgeRetrieverError.unavailable("未找到 ZIP 资料库") }
        return path
    }

    private func prepareWorker(script: URL, knowledgeBasePath: String) async throws -> PersistentJSONLWorker {
        if let worker { return worker }
        let candidate = PersistentJSONLWorker(
            executable: pythonURL,
            arguments: [
                script.path,
                "--knowledge-base", knowledgeBasePath,
                "--knowledge-sha256", knowledgeBaseSHA256,
                "--cache-directory", writableCacheURL.path,
                "--seed-cache-directory", seedCacheURL.path,
                "--index-root", indexRootURL.path,
                "--index-algorithm-version", indexAlgorithmVersion,
            ],
            environment: Self.pythonEnvironment(
                base: ProcessInfo.processInfo.environment,
                sitePackagesURL: sitePackagesURL
            ),
            startupDeadline: startupDeadline,
            queryDeadline: queryDeadline
        )
        let ready: WorkerReady
        do {
            ready = try JSONDecoder().decode(WorkerReady.self, from: await candidate.start())
        } catch {
            await candidate.stop()
            throw error
        }
        guard ready.type == "ready", ["v2-top12", "v2-lexical-only"].contains(ready.version) else {
            await candidate.stop()
            throw KnowledgeRetrieverError.invalidOutput("常驻 worker 未返回 ready")
        }
        worker = candidate
        workerVersion = ready.version
        return candidate
    }

    private func retrieveOneShot(historyJSONL: String, knowledgeBasePath: String) async throws -> RetrievedKnowledge {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-knowledge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let requestURL = temporary.appendingPathComponent("request.json")
        let outputURL = temporary.appendingPathComponent("result.json")
        let request: [String: Any] = [
            "knowledge_base_path": knowledgeBasePath,
            "history_jsonl": historyJSONL,
            "cache_directory": writableCacheURL.path,
            "seed_cache_directory": seedCacheURL.path,
        ]
        try JSONSerialization.data(withJSONObject: request).write(to: requestURL, options: .atomic)
        let result = await BoundedProcess.run(
            .init(
                executable: pythonURL,
                arguments: [scriptURL.path, "--request", requestURL.path, "--output", outputURL.path],
                environment: Self.pythonEnvironment(
                    base: ProcessInfo.processInfo.environment,
                    sitePackagesURL: sitePackagesURL
                )
            ),
            softDeadline: deadlines.soft,
            hardDeadline: deadlines.hard
        )
        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        switch result.termination {
        case .exited(0): break
        case .exited(let code):
            throw KnowledgeRetrieverError.failed(code, String(stderr.suffix(2_000)))
        case .hardDeadline:
            throw KnowledgeRetrieverError.failed(124, "超过 5 秒硬时限；\(String(stderr.suffix(2_000)))")
        case .launchFailed(_, let message):
            throw KnowledgeRetrieverError.unavailable(message)
        }
        guard let data = try? Data(contentsOf: outputURL),
              let value = try? JSONDecoder().decode(RetrievedKnowledge.self, from: data),
              value.version == "v2-top12",
              !value.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KnowledgeRetrieverError.invalidOutput(String(stderr.suffix(2_000)))
        }
        return value
    }

    /// Retrieval should follow the frozen unanswered batch, with only enough
    /// recent conversation to resolve short follow-ups such as “视频” or “还是偏”.
    /// Feeding months of old history into retrieval lets unrelated old products
    /// dominate the current question and also wastes embedding/query work.
    static func focusedHistoryJSONL(
        fullHistoryJSONL: String,
        targetCustomerJSONL: String,
        recentLineLimit: Int = 24
    ) -> String {
        let recent = Array(fullHistoryJSONL.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(max(1, recentLineLimit))).map(String.init)
        let target = targetCustomerJSONL.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !target.isEmpty else { return recent.joined(separator: "\n") + (recent.isEmpty ? "" : "\n") }
        let alreadyAtEnd = recent.count >= target.count && Array(recent.suffix(target.count)) == target
        let combined = alreadyAtEnd ? recent : recent + target
        return combined.joined(separator: "\n") + "\n"
    }
}

private struct WorkerReady: Decodable {
    let type: String
    let version: String
}

private struct WorkerResponse: Decodable {
    let id: String?
    let ok: Bool
    let result: RetrievedKnowledge?
    let error: String?
}
