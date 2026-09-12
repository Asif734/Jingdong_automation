import XCTest
@testable import AutoReplyApp

final class PortableRuntimeResourcesTests: XCTestCase {
    private let fixtureHash = "f16d05ec6b29248d2c61adb1e9263f78e4f7bace1b955014a2d17872cfe4064d"
    private let newFixtureHash = "72168ecf589ac573fc209766fafd6d9ca3933cb2c574bd74199d19210dede80a"

    private func writeManifest(_ hash: String, to resources: URL) throws {
        let manifest = resources.appendingPathComponent("KnowledgeBase/manifest.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let value = [
            "knowledge_sha256": hash,
            "index_algorithm_version": "v2-index-1",
        ]
        try JSONSerialization.data(withJSONObject: value).write(to: manifest)
    }

    private func makeRuntimeFixture(root: URL) throws -> (resources: URL, support: URL, python: URL, codex: URL, seedKB: URL) {
        let resources = root.appendingPathComponent("App.app/Contents/Resources")
        let support = root.appendingPathComponent("Library/Application Support/QianniuAutoReply")
        let python = resources.appendingPathComponent("Python.framework/Versions/3.12/bin/python3.12")
        let script = resources.appendingPathComponent("V2Knowledge/retrieve_top12.py")
        let worker = resources.appendingPathComponent("V2Knowledge/serve_top12.py")
        let packages = resources.appendingPathComponent("V2Knowledge/site-packages")
        let cache = resources.appendingPathComponent("V2Knowledge/cache/models")
        let speechWorker = resources.appendingPathComponent("SenseVoice/serve_sensevoice.py")
        let speechPackages = resources.appendingPathComponent("SenseVoice/site-packages/sherpa_onnx/marker")
        let speechModel = resources.appendingPathComponent("SenseVoice/model/model.int8.onnx")
        let speechTokens = resources.appendingPathComponent("SenseVoice/model/tokens.txt")
        let seedKB = resources.appendingPathComponent("KnowledgeBase/Grozziie-China-KB.zip")
        let codex = root.appendingPathComponent("ChatGPT.app/Contents/Resources/codex")
        for url in [python, script, worker, packages.appendingPathComponent("marker"), cache.appendingPathComponent("marker"), speechWorker, speechPackages, speechModel, speechTokens, seedKB, codex] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        try writeManifest(fixtureHash, to: resources)
        return (resources, support, python, codex, seedKB)
    }

    func testCodexCandidatesCoverSystemUserAppsHomebrewAndPathWithoutFixedUser() {
        let resources = URL(fileURLWithPath: "/Portable.app/Contents/Resources")
        let home = URL(fileURLWithPath: "/Users/colleague")
        let paths = PortableRuntimeResources.codexCandidates(
            resourcesURL: resources,
            homeDirectory: home,
            pathEnvironment: "/custom/bin:/opt/tools"
        ).map(\.path)

        XCTAssertEqual(paths.first, "/Applications/ChatGPT.app/Contents/Resources/codex")
        XCTAssertTrue(paths.contains("/Users/colleague/Applications/Codex.app/Contents/Resources/codex"))
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/codex"))
        XCTAssertTrue(paths.contains("/custom/bin/codex"))
        XCTAssertTrue(paths.contains("/Portable.app/Contents/Resources/codex"))
        XCTAssertFalse(paths.contains { $0.contains("/Users/scy") })
    }
    func testResolvesOnlyBundleRelativeRuntimeAndApplicationSupportKnowledgeBase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRuntimeFixture(root: root)

        let runtime = try PortableRuntimeResources.resolve(
            resourcesURL: fixture.resources,
            applicationSupportURL: fixture.support,
            codexCandidates: [fixture.codex],
            isExecutable: { $0 == fixture.python || $0 == fixture.codex }
        )

        XCTAssertEqual(runtime.pythonURL, fixture.python)
        XCTAssertEqual(runtime.retrievalWorkerScriptURL, fixture.resources.appendingPathComponent("V2Knowledge/serve_top12.py"))
        XCTAssertEqual(runtime.senseVoiceWorkerScriptURL, fixture.resources.appendingPathComponent("SenseVoice/serve_sensevoice.py"))
        XCTAssertEqual(runtime.senseVoiceModelURL, fixture.resources.appendingPathComponent("SenseVoice/model/model.int8.onnx"))
        XCTAssertEqual(runtime.senseVoiceTokensURL, fixture.resources.appendingPathComponent("SenseVoice/model/tokens.txt"))
        XCTAssertEqual(runtime.knowledgeBaseURL, fixture.support.appendingPathComponent("KnowledgeBase/current.zip"))
        XCTAssertEqual(runtime.knowledgeBaseSHA256, fixtureHash)
        XCTAssertEqual(runtime.indexAlgorithmVersion, "v2-index-1")
        XCTAssertEqual(runtime.indexRootURL, fixture.support.appendingPathComponent("V2Indexes"))
        XCTAssertEqual(try Data(contentsOf: runtime.knowledgeBaseURL), Data("fixture".utf8))
        XCTAssertFalse(runtime.resolvedURLs.contains { $0.path.contains("/Users/scy/") })
    }

    func testSameManifestPreservesLocalKnowledgeAndNewManifestAtomicallyReplacesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-update-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRuntimeFixture(root: root)
        let resolve = {
            try PortableRuntimeResources.resolve(
                resourcesURL: fixture.resources,
                applicationSupportURL: fixture.support,
                codexCandidates: [fixture.codex],
                isExecutable: { $0 == fixture.python || $0 == fixture.codex }
            )
        }
        let first = try resolve()
        let preservedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: preservedDate], ofItemAtPath: first.knowledgeBaseURL.path)

        _ = try resolve()
        let unchangedDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: first.knowledgeBaseURL.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(unchangedDate, preservedDate)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: first.knowledgeBaseURL.path
        )
        try Data("new fixture".utf8).write(to: fixture.seedKB)
        try writeManifest(newFixtureHash, to: fixture.resources)
        let updated = try resolve()
        XCTAssertEqual(try Data(contentsOf: updated.knowledgeBaseURL), Data("new fixture".utf8))
        XCTAssertEqual(updated.knowledgeBaseSHA256, newFixtureHash)
    }

    func testMigrationAddsManifestWithoutFailingOnLegacyReadOnlyKnowledgeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-readonly-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRuntimeFixture(root: root)
        let resolve = {
            try PortableRuntimeResources.resolve(
                resourcesURL: fixture.resources,
                applicationSupportURL: fixture.support,
                codexCandidates: [fixture.codex],
                isExecutable: { $0 == fixture.python || $0 == fixture.codex }
            )
        }
        let first = try resolve()
        let localManifest = fixture.support.appendingPathComponent("KnowledgeBase/current-manifest.json")
        try FileManager.default.removeItem(at: localManifest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: first.knowledgeBaseURL.path
        )

        let migrated = try resolve()

        XCTAssertEqual(try Data(contentsOf: migrated.knowledgeBaseURL), Data("fixture".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localManifest.path))
    }

    func testMalformedKnowledgeManifestIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-bad-manifest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeRuntimeFixture(root: root)
        try writeManifest("wrong", to: fixture.resources)

        XCTAssertThrowsError(try PortableRuntimeResources.resolve(
            resourcesURL: fixture.resources,
            applicationSupportURL: fixture.support,
            codexCandidates: [fixture.codex],
            isExecutable: { $0 == fixture.python || $0 == fixture.codex }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("manifest"))
        }
    }

    func testMissingComponentNamesExactBlocker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try PortableRuntimeResources.resolve(
            resourcesURL: root,
            applicationSupportURL: root.appendingPathComponent("support"),
            codexCandidates: [],
            isExecutable: { _ in false }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Python"))
        }
    }
}
