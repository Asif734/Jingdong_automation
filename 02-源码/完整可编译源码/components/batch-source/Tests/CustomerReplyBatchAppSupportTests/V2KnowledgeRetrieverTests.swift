import XCTest
@testable import CustomerReplyBatchAppSupport

final class V2KnowledgeRetrieverTests: XCTestCase {
    func testPrepareStartsWorkerOnceAndReportsReadyVersionBeforeFirstQuery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-prepare-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("launches.txt")
        let workerScript = root.appendingPathComponent("worker.py")
        let source = """
        import json, sys
        with open(\(String(reflecting: marker.path)), "a", encoding="utf-8") as handle:
            handle.write("launch\\n")
        print(json.dumps({"type":"ready","version":"v2-lexical-only"}), flush=True)
        for line in sys.stdin:
            value = json.loads(line)
            print(json.dumps({"id":value["id"],"ok":True,"result":{"version":"v2-lexical-only","documents":["answer.md"],"context":"answer"}}), flush=True)
        """
        try Data(source.utf8).write(to: workerScript)
        let zip = root.appendingPathComponent("kb.zip")
        try Data("fixture".utf8).write(to: zip)
        let retriever = V2KnowledgeRetriever(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), scriptURL: workerScript,
            workerScriptURL: workerScript, sitePackagesURL: root, seedCacheURL: root,
            writableCacheURL: root, knowledgeBaseSHA256: String(repeating: "a", count: 64),
            indexRootURL: root.appendingPathComponent("indexes"), indexAlgorithmVersion: "v2-index-1"
        )

        let preparation = try await retriever.prepare(knowledgeBasePaths: [zip.path])
        _ = try await retriever.retrieve(historyJSONL: "question", knowledgeBasePaths: [zip.path])

        XCTAssertEqual(preparation.version, "v2-lexical-only")
        XCTAssertEqual(try String(contentsOf: marker).split(separator: "\n").count, 1)
        await retriever.shutdown()
    }

    func testPersistentWorkerColdStartUsesItsOwnBoundedTimeout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-start-timeout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workerScript = root.appendingPathComponent("worker.py")
        try Data("import time; time.sleep(30)\n".utf8).write(to: workerScript)
        let zip = root.appendingPathComponent("kb.zip")
        try Data("fixture".utf8).write(to: zip)
        let retriever = V2KnowledgeRetriever(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), scriptURL: workerScript,
            workerScriptURL: workerScript, sitePackagesURL: root, seedCacheURL: root,
            writableCacheURL: root, knowledgeBaseSHA256: String(repeating: "a", count: 64),
            indexRootURL: root.appendingPathComponent("indexes"), indexAlgorithmVersion: "v2-index-1",
            startupDeadline: .milliseconds(100), queryDeadline: .milliseconds(50)
        )
        let start = ContinuousClock.now

        do {
            _ = try await retriever.prepare(knowledgeBasePaths: [zip.path])
            XCTFail("cold start must be bounded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("启动超时"))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testMultipleQueriesReuseOnePersistentWorkerProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-worker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("launches.txt")
        let workerScript = root.appendingPathComponent("worker.py")
        let source = """
        import json, sys
        with open(\(String(reflecting: marker.path)), "a", encoding="utf-8") as handle:
            handle.write("launch\\n")
        print(json.dumps({"type":"ready","version":"v2-top12"}), flush=True)
        for line in sys.stdin:
            value = json.loads(line)
            print(json.dumps({"id":value["id"],"ok":True,"result":{"version":"v2-top12","documents":["answer.md"],"context":"SOURCE: answer.md\\nanswer"}}), flush=True)
        """
        try Data(source.utf8).write(to: workerScript)
        let zip = root.appendingPathComponent("kb.zip")
        try Data("fixture".utf8).write(to: zip)
        let retriever = V2KnowledgeRetriever(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            scriptURL: workerScript,
            workerScriptURL: workerScript,
            sitePackagesURL: root,
            seedCacheURL: root,
            writableCacheURL: root,
            knowledgeBaseSHA256: String(repeating: "a", count: 64),
            indexRootURL: root.appendingPathComponent("indexes"),
            indexAlgorithmVersion: "v2-index-1"
        )

        _ = try await retriever.retrieve(historyJSONL: "first", knowledgeBasePaths: [zip.path])
        _ = try await retriever.retrieve(historyJSONL: "second", knowledgeBasePaths: [zip.path])

        let launches = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(launches.count, 1)
        await retriever.shutdown()
    }

    func testWorkerCrashRestartsExactlyOnceForCurrentQuery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-restart-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("launches.txt")
        let workerScript = root.appendingPathComponent("worker.py")
        let source = """
        import json, sys
        marker = \(String(reflecting: marker.path))
        with open(marker, "a", encoding="utf-8") as handle:
            handle.write("launch\\n")
        launch_count = len(open(marker, encoding="utf-8").readlines())
        print(json.dumps({"type":"ready","version":"v2-top12"}), flush=True)
        for line in sys.stdin:
            if launch_count == 1:
                sys.exit(7)
            value = json.loads(line)
            print(json.dumps({"id":value["id"],"ok":True,"result":{"version":"v2-top12","documents":["answer.md"],"context":"answer"}}), flush=True)
        """
        try Data(source.utf8).write(to: workerScript)
        let zip = root.appendingPathComponent("kb.zip")
        try Data("fixture".utf8).write(to: zip)
        let retriever = V2KnowledgeRetriever(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), scriptURL: workerScript,
            workerScriptURL: workerScript, sitePackagesURL: root, seedCacheURL: root,
            writableCacheURL: root, knowledgeBaseSHA256: String(repeating: "a", count: 64),
            indexRootURL: root.appendingPathComponent("indexes"), indexAlgorithmVersion: "v2-index-1"
        )

        let result = try await retriever.retrieve(historyJSONL: "question", knowledgeBasePaths: [zip.path])

        XCTAssertEqual(result.context, "answer")
        XCTAssertEqual(try String(contentsOf: marker).split(separator: "\n").count, 2)
        await retriever.shutdown()
    }

    func testHangingRetrieverStopsAtHardDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-hang-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-python.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let script = root.appendingPathComponent("retrieve.py")
        let zip = root.appendingPathComponent("kb.zip")
        try Data().write(to: script)
        try Data().write(to: zip)
        let retriever = V2KnowledgeRetriever(
            pythonURL: executable,
            scriptURL: script,
            sitePackagesURL: root,
            seedCacheURL: root,
            writableCacheURL: root,
            deadlines: (.milliseconds(20), .milliseconds(100))
        )
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await retriever.retrieve(historyJSONL: "{}\n", knowledgeBasePaths: [zip.path])
            XCTFail("hanging retriever must time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("硬时限"))
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
    }

    func testPythonEnvironmentKeepsSignedBundleReadOnly() {
        let packages = URL(fileURLWithPath: "/portable/V2Knowledge/site-packages")
        let environment = V2KnowledgeRetriever.pythonEnvironment(
            base: ["EXISTING": "yes"], sitePackagesURL: packages
        )

        XCTAssertEqual(environment["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(environment["PYTHONPATH"], packages.path)
        XCTAssertEqual(environment["TOKENIZERS_PARALLELISM"], "false")
        XCTAssertEqual(environment["EXISTING"], "yes")
    }
    func testLiveRuntimeUsesBundledPythonInsteadOfSystemFramework() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let python = root.appendingPathComponent("Python.framework/Versions/3.12/bin/python3.12")
        let script = root.appendingPathComponent("V2Knowledge/retrieve_top12.py")
        let packages = root.appendingPathComponent("V2Knowledge/site-packages")
        let cache = root.appendingPathComponent("V2Knowledge/cache")
        for url in [python, script, packages.appendingPathComponent("marker"), cache.appendingPathComponent("marker")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }

        let runtime = try XCTUnwrap(V2KnowledgeRetriever.live(
            resourcesURL: root,
            applicationSupportURL: root.appendingPathComponent("Support"),
            isExecutable: { $0 == python }
        ))

        let resolvedPython = await runtime.pythonURL
        XCTAssertEqual(resolvedPython, python)
    }
    func testFocusedHistoryUsesRecentContextAndFrozenTargetInsteadOfMonthsOfOldMessages() throws {
        let old = (0..<60).map { index in
            "{\"sender\":\"customer\",\"v\":\"旧针式打印机问题\(index)\"}"
        }
        let recent = [
            "{\"sender\":\"customer\",\"v\":\"M880班次有重叠\"}",
            "{\"sender\":\"service\",\"v\":\"建议手动打卡\"}",
            "{\"sender\":\"customer\",\"v\":\"视频发给我\"}",
        ]
        let full = (old + recent).joined(separator: "\n") + "\n"
        let target = recent.last! + "\n"

        let focused = V2KnowledgeRetriever.focusedHistoryJSONL(
            fullHistoryJSONL: full,
            targetCustomerJSONL: target
        )

        XCTAssertFalse(focused.contains("旧针式打印机问题0"))
        XCTAssertTrue(focused.contains("M880班次有重叠"))
        XCTAssertTrue(focused.contains("建议手动打卡"))
        XCTAssertTrue(focused.contains("视频发给我"))
    }
}
