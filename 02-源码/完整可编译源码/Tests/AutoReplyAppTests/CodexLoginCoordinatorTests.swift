import Foundation
import XCTest
@testable import AutoReplyApp

final class CodexLoginCoordinatorTests: XCTestCase {
    func testStatusImportsOnlyLocalLoginCacheWhenDedicatedHomeIsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let personalHome = root.appendingPathComponent("personal", isDirectory: true)
        let dedicatedHome = root.appendingPathComponent("dedicated", isDirectory: true)
        try FileManager.default.createDirectory(at: personalHome, withIntermediateDirectories: true)
        try Data("local-login-cache".utf8).write(
            to: personalHome.appendingPathComponent("auth.json"),
            options: .atomic
        )
        try Data("must-not-copy".utf8).write(
            to: personalHome.appendingPathComponent("config.toml"),
            options: .atomic
        )
        try FileManager.default.createDirectory(
            at: personalHome.appendingPathComponent("skills", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = SequencedCodexLoginRunner(results: [
            CodexLoginProcessResult(exitCode: 1, output: "Not logged in"),
            CodexLoginProcessResult(exitCode: 0, output: "Logged in using ChatGPT"),
            CodexLoginProcessResult(exitCode: 0, output: "Logged in using ChatGPT")
        ])
        let coordinator = CodexLoginCoordinator(
            codexURL: URL(fileURLWithPath: "/bin/codex"),
            codexHomeURL: dedicatedHome,
            personalCodexHomeURL: personalHome,
            runner: runner
        )

        let state = try await coordinator.status()

        XCTAssertEqual(state, .loggedIn)
        XCTAssertEqual(
            try Data(contentsOf: dedicatedHome.appendingPathComponent("auth.json")),
            Data("local-login-cache".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dedicatedHome.appendingPathComponent("config.toml").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dedicatedHome.appendingPathComponent("skills").path
        ))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: dedicatedHome.appendingPathComponent("auth.json").path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(
            calls.map(\.arguments),
            [["login", "status"], ["login", "status"], ["login", "status"]]
        )
        XCTAssertEqual(calls[0].environment["CODEX_HOME"], dedicatedHome.path)
        XCTAssertEqual(calls[1].environment["CODEX_HOME"], personalHome.path)
        XCTAssertEqual(calls[2].environment["CODEX_HOME"], dedicatedHome.path)
    }

    func testStatusUsesDedicatedHomeAndNeverPersonalConfiguration() async throws {
        let runner = RecordingCodexLoginRunner(
            result: CodexLoginProcessResult(exitCode: 0, output: "Logged in using ChatGPT")
        )
        let home = URL(fileURLWithPath: "/tmp/customer-codex-home")
        let coordinator = CodexLoginCoordinator(
            codexURL: URL(fileURLWithPath: "/bin/codex"),
            codexHomeURL: home,
            runner: runner
        )

        let state = try await coordinator.status()
        XCTAssertEqual(state, .loggedIn)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments, ["login", "status"])
        XCTAssertEqual(calls[0].environment["CODEX_HOME"], home.path)
        XCTAssertNil(calls[0].environment["OPENAI_API_KEY"])
        XCTAssertNil(calls[0].environment["CODEX_API_KEY"])
    }

    func testDeviceLoginUsesSameDedicatedHome() async throws {
        let runner = RecordingCodexLoginRunner(
            result: CodexLoginProcessResult(exitCode: 0, output: "Login successful")
        )
        let home = URL(fileURLWithPath: "/tmp/customer-codex-home")
        let coordinator = CodexLoginCoordinator(
            codexURL: URL(fileURLWithPath: "/bin/codex"),
            codexHomeURL: home,
            runner: runner
        )

        try await coordinator.startDeviceLogin()

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments, ["login", "--device-auth"])
        XCTAssertEqual(calls[0].environment["CODEX_HOME"], home.path)
        XCTAssertNil(calls[0].environment["OPENAI_API_KEY"])
    }

    func testNonzeroStatusReturnsActionableLoginRequirement() async throws {
        let runner = RecordingCodexLoginRunner(
            result: CodexLoginProcessResult(exitCode: 1, output: "Not logged in")
        )
        let coordinator = CodexLoginCoordinator(
            codexURL: URL(fileURLWithPath: "/bin/codex"),
            codexHomeURL: URL(fileURLWithPath: "/tmp/customer-codex-home"),
            personalCodexHomeURL: URL(fileURLWithPath: "/tmp/missing-personal-codex-home"),
            runner: runner
        )

        let state = try await coordinator.status()
        XCTAssertEqual(state, .loginRequired("Not logged in"))
    }

    func testFailedLocalCacheImportFallsBackToLoginPromptInsteadOfBlockingReadiness() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let personalHome = root.appendingPathComponent("personal", isDirectory: true)
        let dedicatedHome = root.appendingPathComponent("dedicated", isDirectory: true)
        try FileManager.default.createDirectory(at: personalHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dedicatedHome, withIntermediateDirectories: true)
        try Data("local-login-cache".utf8).write(
            to: personalHome.appendingPathComponent("auth.json"),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: dedicatedHome.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: dedicatedHome.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let runner = SequencedCodexLoginRunner(results: [
            CodexLoginProcessResult(exitCode: 1, output: "Not logged in"),
            CodexLoginProcessResult(exitCode: 0, output: "Logged in using ChatGPT")
        ])
        let coordinator = CodexLoginCoordinator(
            codexURL: URL(fileURLWithPath: "/bin/codex"),
            codexHomeURL: dedicatedHome,
            personalCodexHomeURL: personalHome,
            runner: runner
        )

        let state = try await coordinator.status()

        XCTAssertEqual(state, .loginRequired("Not logged in"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dedicatedHome.appendingPathComponent("auth.json").path
        ))
    }
}

private actor SequencedCodexLoginRunner: CodexLoginRunning {
    struct Call: Sendable {
        let arguments: [String]
        let environment: [String: String]
    }

    private var results: [CodexLoginProcessResult]
    private var calls: [Call] = []

    init(results: [CodexLoginProcessResult]) {
        self.results = results
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> CodexLoginProcessResult {
        calls.append(Call(arguments: arguments, environment: environment))
        return results.removeFirst()
    }

    func recordedCalls() -> [Call] { calls }
}

private actor RecordingCodexLoginRunner: CodexLoginRunning {
    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private let result: CodexLoginProcessResult
    private var calls: [Call] = []

    init(result: CodexLoginProcessResult) {
        self.result = result
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> CodexLoginProcessResult {
        calls.append(Call(executable: executable, arguments: arguments, environment: environment))
        return result
    }

    func recordedCalls() -> [Call] { calls }
}
