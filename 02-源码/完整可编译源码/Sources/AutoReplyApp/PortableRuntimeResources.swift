import Foundation
import CryptoKit

enum PortableRuntimeError: LocalizedError {
    case missing(String, URL)
    case installKnowledgeBase(String)
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name, let url):
            return "运行资源缺失：\(name)（\(url.path)）"
        case .installKnowledgeBase(let detail):
            return "无法准备知识库：\(detail)"
        case .invalidManifest(let detail):
            return "知识库 manifest 无效：\(detail)"
        }
    }
}

private struct BundledKnowledgeManifest: Codable, Equatable {
    let knowledgeSHA256: String
    let indexAlgorithmVersion: String

    enum CodingKeys: String, CodingKey {
        case knowledgeSHA256 = "knowledge_sha256"
        case indexAlgorithmVersion = "index_algorithm_version"
    }
}

struct PortableRuntimeResources {
    let pythonURL: URL
    let retrievalScriptURL: URL
    let retrievalWorkerScriptURL: URL
    let sitePackagesURL: URL
    let seedCacheURL: URL
    let writableCacheURL: URL
    let knowledgeBaseURL: URL
    let knowledgeBaseSHA256: String
    let indexAlgorithmVersion: String
    let indexRootURL: URL
    let codexURL: URL
    let senseVoiceWorkerScriptURL: URL
    let senseVoiceSitePackagesURL: URL
    let senseVoiceModelURL: URL
    let senseVoiceTokensURL: URL

    var resolvedURLs: [URL] {
        [pythonURL, retrievalScriptURL, retrievalWorkerScriptURL, sitePackagesURL,
         seedCacheURL, writableCacheURL, knowledgeBaseURL, indexRootURL, codexURL,
         senseVoiceWorkerScriptURL, senseVoiceSitePackagesURL, senseVoiceModelURL, senseVoiceTokensURL]
    }

    static func resolve(
        resourcesURL: URL,
        applicationSupportURL: URL,
        codexCandidates: [URL],
        fileManager: FileManager = .default,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) throws -> PortableRuntimeResources {
        let python = resourcesURL.appendingPathComponent("Python.framework/Versions/3.12/bin/python3.12")
        let v2 = resourcesURL.appendingPathComponent("V2Knowledge", isDirectory: true)
        let script = v2.appendingPathComponent("retrieve_top12.py")
        let worker = v2.appendingPathComponent("serve_top12.py")
        let packages = v2.appendingPathComponent("site-packages", isDirectory: true)
        let seedCache = v2.appendingPathComponent("cache", isDirectory: true)
        let seedKnowledge = resourcesURL.appendingPathComponent("KnowledgeBase/Grozziie-China-KB.zip")
        let bundledManifestURL = resourcesURL.appendingPathComponent("KnowledgeBase/manifest.json")
        let senseVoice = resourcesURL.appendingPathComponent("SenseVoice", isDirectory: true)
        let senseVoiceWorker = senseVoice.appendingPathComponent("serve_sensevoice.py")
        let senseVoicePackages = senseVoice.appendingPathComponent("site-packages", isDirectory: true)
        let senseVoiceModel = senseVoice.appendingPathComponent("model/model.int8.onnx")
        let senseVoiceTokens = senseVoice.appendingPathComponent("model/tokens.txt")
        guard isExecutable(python) else { throw PortableRuntimeError.missing("Python 3.12", python) }
        guard fileManager.fileExists(atPath: script.path) else { throw PortableRuntimeError.missing("V2 检索脚本", script) }
        guard fileManager.fileExists(atPath: worker.path) else { throw PortableRuntimeError.missing("V2 常驻检索 worker", worker) }
        guard fileManager.fileExists(atPath: packages.path) else { throw PortableRuntimeError.missing("V2 Python 依赖", packages) }
        guard fileManager.fileExists(atPath: seedCache.path) else { throw PortableRuntimeError.missing("V2 模型缓存", seedCache) }
        guard fileManager.fileExists(atPath: seedKnowledge.path) else { throw PortableRuntimeError.missing("格志知识库", seedKnowledge) }
        guard fileManager.fileExists(atPath: bundledManifestURL.path) else {
            throw PortableRuntimeError.missing("知识库 manifest", bundledManifestURL)
        }
        guard fileManager.fileExists(atPath: senseVoiceWorker.path) else {
            throw PortableRuntimeError.missing("SenseVoice 常驻 worker", senseVoiceWorker)
        }
        guard fileManager.fileExists(atPath: senseVoicePackages.path) else {
            throw PortableRuntimeError.missing("SenseVoice Python 依赖", senseVoicePackages)
        }
        guard fileManager.fileExists(atPath: senseVoiceModel.path) else {
            throw PortableRuntimeError.missing("SenseVoice INT8 模型", senseVoiceModel)
        }
        guard fileManager.fileExists(atPath: senseVoiceTokens.path) else {
            throw PortableRuntimeError.missing("SenseVoice tokens", senseVoiceTokens)
        }
        guard let codex = codexCandidates.first(where: isExecutable) else {
            throw PortableRuntimeError.missing("Codex CLI", codexCandidates.first ?? resourcesURL.appendingPathComponent("codex"))
        }

        let knowledgeDirectory = applicationSupportURL.appendingPathComponent("KnowledgeBase", isDirectory: true)
        let knowledge = knowledgeDirectory.appendingPathComponent("current.zip")
        let localManifestURL = knowledgeDirectory.appendingPathComponent("current-manifest.json")
        let writableCache = applicationSupportURL.appendingPathComponent("V2KnowledgeCache", isDirectory: true)
        let indexRoot = applicationSupportURL.appendingPathComponent("V2Indexes", isDirectory: true)
        let manifest: BundledKnowledgeManifest
        do {
            manifest = try JSONDecoder().decode(
                BundledKnowledgeManifest.self,
                from: Data(contentsOf: bundledManifestURL)
            )
        } catch {
            throw PortableRuntimeError.invalidManifest(error.localizedDescription)
        }
        guard manifest.knowledgeSHA256.count == 64,
              manifest.knowledgeSHA256.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
            throw PortableRuntimeError.invalidManifest(
                "knowledge_sha256 必须是 64 位小写十六进制；收到长度 \(manifest.knowledgeSHA256.count)：\(manifest.knowledgeSHA256)"
            )
        }
        guard manifest.indexAlgorithmVersion.range(
            of: "^[A-Za-z0-9_.-]+$", options: .regularExpression
        ) != nil else {
            throw PortableRuntimeError.invalidManifest("index_algorithm_version 含非法字符")
        }
        do {
            try fileManager.createDirectory(at: knowledgeDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: writableCache, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: indexRoot, withIntermediateDirectories: true)
            let localManifest = try? JSONDecoder().decode(
                BundledKnowledgeManifest.self,
                from: Data(contentsOf: localManifestURL)
            )
            let knowledgeExists = fileManager.fileExists(atPath: knowledge.path)
            let existingKnowledgeMatches: Bool
            if knowledgeExists, localManifest != manifest {
                existingKnowledgeMatches = try sha256(of: knowledge) == manifest.knowledgeSHA256
            } else {
                existingKnowledgeMatches = false
            }
            if !knowledgeExists || (localManifest != manifest && !existingKnowledgeMatches) {
                let suffix = UUID().uuidString
                let temporaryKnowledge = knowledgeDirectory.appendingPathComponent("current-\(suffix).zip")
                defer {
                    try? fileManager.removeItem(at: temporaryKnowledge)
                }
                try fileManager.copyItem(at: seedKnowledge, to: temporaryKnowledge)
                guard try sha256(of: temporaryKnowledge) == manifest.knowledgeSHA256 else {
                    throw PortableRuntimeError.invalidManifest("随包 ZIP 的 SHA-256 与 manifest 不一致")
                }
                if fileManager.fileExists(atPath: knowledge.path) {
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: knowledge.path
                    )
                    _ = try fileManager.replaceItemAt(knowledge, withItemAt: temporaryKnowledge)
                } else {
                    try fileManager.moveItem(at: temporaryKnowledge, to: knowledge)
                }
            }
            if localManifest != manifest {
                let suffix = UUID().uuidString
                let temporaryManifest = knowledgeDirectory.appendingPathComponent("current-manifest-\(suffix).json")
                defer { try? fileManager.removeItem(at: temporaryManifest) }
                try Data(contentsOf: bundledManifestURL).write(to: temporaryManifest, options: .atomic)
                if fileManager.fileExists(atPath: localManifestURL.path) {
                    _ = try fileManager.replaceItemAt(localManifestURL, withItemAt: temporaryManifest)
                } else {
                    try fileManager.moveItem(at: temporaryManifest, to: localManifestURL)
                }
            }
        } catch {
            throw PortableRuntimeError.installKnowledgeBase(error.localizedDescription)
        }
        return PortableRuntimeResources(
            pythonURL: python,
            retrievalScriptURL: script,
            retrievalWorkerScriptURL: worker,
            sitePackagesURL: packages,
            seedCacheURL: seedCache,
            writableCacheURL: writableCache,
            knowledgeBaseURL: knowledge,
            knowledgeBaseSHA256: manifest.knowledgeSHA256,
            indexAlgorithmVersion: manifest.indexAlgorithmVersion,
            indexRootURL: indexRoot,
            codexURL: codex,
            senseVoiceWorkerScriptURL: senseVoiceWorker,
            senseVoiceSitePackagesURL: senseVoicePackages,
            senseVoiceModelURL: senseVoiceModel,
            senseVoiceTokensURL: senseVoiceTokens
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func live(bundle: Bundle = .main, fileManager: FileManager = .default) throws -> PortableRuntimeResources {
        guard let resources = bundle.resourceURL else {
            throw PortableRuntimeError.missing("App Resources", bundle.bundleURL)
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QianniuAutoReply", isDirectory: true)
        return try resolve(
            resourcesURL: resources,
            applicationSupportURL: support,
            codexCandidates: codexCandidates(resourcesURL: resources),
            fileManager: fileManager
        )
    }

    static func codexCandidates(
        resourcesURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> [URL] {
        let relativeAppPaths = [
            "ChatGPT.app/Contents/Resources/codex",
            "Codex.app/Contents/Resources/codex",
        ]
        var candidates = relativeAppPaths.map {
            URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent($0)
        }
        candidates += relativeAppPaths.map {
            homeDirectory.appendingPathComponent("Applications", isDirectory: true).appendingPathComponent($0)
        }
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        candidates += pathEnvironment.split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("codex")
        }
        candidates.append(resourcesURL.appendingPathComponent("codex"))
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
