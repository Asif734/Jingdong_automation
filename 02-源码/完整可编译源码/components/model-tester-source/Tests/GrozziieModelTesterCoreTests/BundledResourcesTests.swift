import XCTest
@testable import GrozziieModelTesterCore

final class BundledResourcesTests: XCTestCase {
    func testResolvesAllRuntimeFilesFromAppResourcesAndWritesCacheToApplicationSupport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: support)
        }
        let paths = [
            "KnowledgeBase/Grozziie-China-KB.zip",
            "V2Knowledge/retrieve_top12.py",
            "V2Knowledge/site-packages/marker",
            "V2Knowledge/cache/marker",
            "Python.framework/Versions/3.12/bin/python3.12",
        ]
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data("fixture".utf8))
        }

        let resources = try BundledResources.resolve(
            resourceRoot: root,
            applicationSupportRoot: support,
            isExecutable: { $0.lastPathComponent == "python3.12" }
        )

        XCTAssertEqual(
            resources.knowledgeBaseURL.resolvingSymlinksInPath().path,
            root.appendingPathComponent("KnowledgeBase/Grozziie-China-KB.zip").resolvingSymlinksInPath().path
        )
        XCTAssertEqual(resources.pythonURL.lastPathComponent, "python3.12")
        XCTAssertEqual(
            resources.writableCacheURL.resolvingSymlinksInPath().path,
            support.appendingPathComponent("V2KnowledgeCache").resolvingSymlinksInPath().path
        )
        let scriptPath = await resources.retriever.scriptURL.path
        XCTAssertTrue(scriptPath.hasSuffix("V2Knowledge/retrieve_top12.py"))
    }

    func testMissingKnowledgeBaseProducesActionableError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertThrowsError(try BundledResources.resolve(
            resourceRoot: root,
            applicationSupportRoot: root,
            isExecutable: { _ in false }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("知识库"))
        }
    }
}
