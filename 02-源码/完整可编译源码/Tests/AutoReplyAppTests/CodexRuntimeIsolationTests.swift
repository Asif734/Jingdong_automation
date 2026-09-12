import Foundation
import XCTest
@testable import AutoReplyApp

final class CodexRuntimeIsolationTests: XCTestCase {
    func testFirstPreparationBacksUpAndInvalidatesOnlyOldSessionBindings() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("运行状态", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let registry = runtime.appendingPathComponent("Codex客户会话.json")
        let oldBytes = Data("{\"u1\":{\"sessionID\":\"old\"}}".utf8)
        try oldBytes.write(to: registry)
        let history = root.appendingPathComponent("用户/u1/history.jsonl")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("customer history must stay".utf8).write(to: history)

        let prepared = try CodexRuntimeIsolation.prepare(runtimeDirectory: runtime)

        XCTAssertEqual(try Data(contentsOf: registry), Data("{}".utf8))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(prepared.registryBackupURL)), oldBytes)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "customer history must stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.codexHomeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.workingDirectoryURL.path))
    }

    func testPreparationIsIdempotentAndDoesNotInvalidateNewBindings() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("运行状态", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let registry = runtime.appendingPathComponent("Codex客户会话.json")
        try Data("{\"old\":true}".utf8).write(to: registry)
        _ = try CodexRuntimeIsolation.prepare(runtimeDirectory: runtime)
        let newBytes = Data("{\"new\":true}".utf8)
        try newBytes.write(to: registry)

        let second = try CodexRuntimeIsolation.prepare(runtimeDirectory: runtime)

        XCTAssertNil(second.registryBackupURL)
        XCTAssertEqual(try Data(contentsOf: registry), newBytes)
    }

    func testPreparationDoesNotCopyPersonalCodexConfiguration() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("运行状态", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)

        let prepared = try CodexRuntimeIsolation.prepare(runtimeDirectory: runtime)
        let forbiddenNames = ["skills", "plugins", "memories", "AGENTS.md", "config.toml", "auth.json"]

        for name in forbiddenNames {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: prepared.codexHomeURL.appendingPathComponent(name).path
                ),
                "专用 CODEX_HOME 不应预装个人配置：\(name)"
            )
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRuntimeIsolationTests-\(UUID().uuidString)", isDirectory: true)
    }
}
