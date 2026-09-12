import Darwin
import Foundation

enum CodexLoginState: Equatable, Sendable {
    case loggedIn
    case loginRequired(String)
}

struct CodexLoginProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let output: String
}

protocol CodexLoginRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> CodexLoginProcessResult
}

enum CodexLoginError: LocalizedError, Equatable {
    case timedOut
    case deviceLoginFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Codex 登录检查超时"
        case let .deviceLoginFailed(output):
            return output.isEmpty ? "Codex 登录失败" : output
        }
    }
}

actor CodexLoginCoordinator {
    private let codexURL: URL
    private let codexHomeURL: URL
    private let personalCodexHomeURL: URL
    private let runner: any CodexLoginRunning
    private let statusTimeout: Duration
    private let deviceLoginTimeout: Duration

    init(
        codexURL: URL,
        codexHomeURL: URL,
        personalCodexHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        runner: any CodexLoginRunning = FoundationCodexLoginRunner(),
        statusTimeout: Duration = .seconds(15),
        deviceLoginTimeout: Duration = .seconds(300)
    ) {
        self.codexURL = codexURL
        self.codexHomeURL = codexHomeURL
        self.personalCodexHomeURL = personalCodexHomeURL
        self.runner = runner
        self.statusTimeout = statusTimeout
        self.deviceLoginTimeout = deviceLoginTimeout
    }

    func status() async throws -> CodexLoginState {
        try ensureDedicatedHome()
        var result = try await run(arguments: ["login", "status"], timeout: statusTimeout)
        if !Self.isLoggedIn(result), hasImportableLocalLoginCache() {
            let personalResult = try await run(
                arguments: ["login", "status"],
                timeout: statusTimeout,
                codexHomeURL: personalCodexHomeURL
            )
            if Self.isLoggedIn(personalResult),
               (try? importLocalLoginCache()) == true {
                result = try await run(arguments: ["login", "status"], timeout: statusTimeout)
            }
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isLoggedIn(result) {
            return .loggedIn
        }
        return .loginRequired(output.isEmpty ? "尚未登录 Codex" : output)
    }

    func startDeviceLogin() async throws {
        try ensureDedicatedHome()
        let result = try await run(
            arguments: ["login", "--device-auth"],
            timeout: deviceLoginTimeout
        )
        guard result.exitCode == 0 else {
            throw CodexLoginError.deviceLoginFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func run(
        arguments: [String],
        timeout: Duration,
        codexHomeURL environmentHomeURL: URL? = nil
    ) async throws -> CodexLoginProcessResult {
        let executable = codexURL
        let environment = Self.dedicatedEnvironment(
            codexHomeURL: environmentHomeURL ?? codexHomeURL
        )
        let processRunner = runner
        return try await withThrowingTaskGroup(of: CodexLoginProcessResult.self) { group in
            group.addTask {
                try await processRunner.run(
                    executable: executable,
                    arguments: arguments,
                    environment: environment
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodexLoginError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    private func ensureDedicatedHome() throws {
        try FileManager.default.createDirectory(
            at: codexHomeURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    private func hasImportableLocalLoginCache() -> Bool {
        let source = personalCodexHomeURL.appendingPathComponent("auth.json")
        let destination = codexHomeURL.appendingPathComponent("auth.json")
        guard source.standardizedFileURL != destination.standardizedFileURL else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else { return false }
        return true
    }

    private func importLocalLoginCache() throws -> Bool {
        let source = personalCodexHomeURL.appendingPathComponent("auth.json")
        let destination = codexHomeURL.appendingPathComponent("auth.json")
        let data = try Data(contentsOf: source)
        guard !data.isEmpty else { return false }
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
        )
        return true
    }

    private static func isLoggedIn(_ result: CodexLoginProcessResult) -> Bool {
        result.exitCode == 0
            && result.output.localizedCaseInsensitiveContains("logged in")
    }

    static func dedicatedEnvironment(
        codexHomeURL: URL,
        source: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let allowlist = ["PATH", "TMPDIR", "LANG", "LC_ALL", "TERM", "SSL_CERT_FILE", "SSL_CERT_DIR"]
        var environment = Dictionary(
            uniqueKeysWithValues: allowlist.compactMap { key in
                source[key].map { (key, $0) }
            }
        )
        environment["CODEX_HOME"] = codexHomeURL.path
        return environment
    }
}

actor FoundationCodexLoginRunner: CodexLoginRunning {
    private var activeProcess: Process?

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> CodexLoginProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        activeProcess = process
        return try await withTaskCancellationHandler {
            try process.run()
            _ = setpgid(process.processIdentifier, process.processIdentifier)

            async let outputData = Task.detached(priority: .utility) {
                try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            }.value
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
            let data = try await outputData
            activeProcess = nil
            return CodexLoginProcessResult(
                exitCode: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        } onCancel: {
            Task { await self.terminateActiveProcess() }
        }
    }

    private func terminateActiveProcess() {
        guard let process = activeProcess, process.isRunning else { return }
        let pid = process.processIdentifier
        _ = kill(-pid, SIGTERM)
        process.terminate()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            await self.forceKillIfNeeded(pid: pid)
        }
    }

    private func forceKillIfNeeded(pid: pid_t) {
        guard let process = activeProcess,
              process.processIdentifier == pid,
              process.isRunning else { return }
        _ = kill(-pid, SIGKILL)
    }
}
