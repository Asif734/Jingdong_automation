import Foundation
import CustomerReplyBatchAppSupport

public enum BundledResourcesError: LocalizedError {
    case missingKnowledgeBase
    case missingRuntime(String)

    public var errorDescription: String? {
        switch self {
        case .missingKnowledgeBase: return "应用包中缺少格志知识库"
        case .missingRuntime(let name): return "应用包中缺少模型检索运行资源：\(name)"
        }
    }
}

public struct BundledResources: Sendable {
    public let resourceRoot: URL
    public let knowledgeBaseURL: URL
    public let pythonURL: URL
    public let writableCacheURL: URL
    public let retriever: V2KnowledgeRetriever

    public static func resolve(
        resourceRoot: URL,
        applicationSupportRoot: URL,
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) throws -> BundledResources {
        let knowledgeDirectory = resourceRoot.appendingPathComponent("KnowledgeBase", isDirectory: true)
        let knowledgeBase = try? FileManager.default.contentsOfDirectory(
            at: knowledgeDirectory,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension.lowercased() == "zip" }
        guard let knowledgeBase else { throw BundledResourcesError.missingKnowledgeBase }

        let v2 = resourceRoot.appendingPathComponent("V2Knowledge", isDirectory: true)
        let script = v2.appendingPathComponent("retrieve_top12.py")
        let packages = v2.appendingPathComponent("site-packages", isDirectory: true)
        let seedCache = v2.appendingPathComponent("cache", isDirectory: true)
        let python = resourceRoot
            .appendingPathComponent("Python.framework/Versions/3.12/bin/python3.12")
        let required: [(String, URL)] = [
            ("retrieve_top12.py", script),
            ("site-packages", packages),
            ("cache", seedCache),
        ]
        for (name, url) in required where !FileManager.default.fileExists(atPath: url.path) {
            throw BundledResourcesError.missingRuntime(name)
        }
        guard isExecutable(python) else { throw BundledResourcesError.missingRuntime("Python 3.12") }

        let writable = applicationSupportRoot.appendingPathComponent("V2KnowledgeCache", isDirectory: true)
        try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)
        return BundledResources(
            resourceRoot: resourceRoot,
            knowledgeBaseURL: knowledgeBase,
            pythonURL: python,
            writableCacheURL: writable,
            retriever: V2KnowledgeRetriever(
                pythonURL: python,
                scriptURL: script,
                sitePackagesURL: packages,
                seedCacheURL: seedCache,
                writableCacheURL: writable
            )
        )
    }
}
