import Foundation

public enum CodexTurnMode: Equatable, Sendable {
    case create
    case resume(sessionID: String)
}

public struct CodexInvocation: Equatable, Sendable {
    public let arguments: [String]

    public init(
        mode: CodexTurnMode,
        model: String,
        reasoningEffort: String,
        schemaURL: URL,
        resultURL: URL,
        workingDirectoryURL: URL? = nil,
        imagePaths: [String]
    ) {
        var arguments = ["-a", "never", "--disable", "shell_tool", "exec"]
        if case .resume = mode {
            arguments.append("resume")
        }
        arguments.append(contentsOf: [
            "--json", "--ignore-user-config", "--ignore-rules",
            "-m", model,
            "-c", "model_reasoning_effort=\"\(reasoningEffort)\"",
            "--skip-git-repo-check"
        ])
        if case .create = mode, let workingDirectoryURL {
            arguments.append(contentsOf: ["-C", workingDirectoryURL.path])
        }
        if case .create = mode {
            arguments.append(contentsOf: ["-s", "read-only"])
        }
        arguments.append(contentsOf: [
            "--output-schema", schemaURL.path,
            "-o", resultURL.path
        ])
        for imagePath in imagePaths {
            arguments.append(contentsOf: ["-i", imagePath])
        }
        if case .resume(let sessionID) = mode {
            arguments.append(sessionID)
        }
        arguments.append("-")
        self.arguments = arguments
    }
}
