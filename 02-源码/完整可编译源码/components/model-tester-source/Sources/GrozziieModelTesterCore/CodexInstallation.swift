import Foundation

public struct ModelConfiguration: Equatable, Sendable {
    public let model: String
    public let reasoningEffort: String
    public let displayName: String

    public static let production = ModelConfiguration(
        model: "gpt-5.6-sol",
        reasoningEffort: "medium",
        displayName: "GPT-5.6 Sol · 中"
    )
}

public enum CodexInstallationLocator {
    public static func resolve(
        knownLocations: [URL] = candidateLocations(),
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) },
        pathLookup: () -> URL? = lookupOnPath
    ) -> URL? {
        if let found = knownLocations.first(where: isExecutable) { return found }
        guard let path = pathLookup(), isExecutable(path) else { return nil }
        return path
    }

    public static func candidateLocations(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let relativeAppPaths = [
            "ChatGPT.app/Contents/Resources/codex",
            "Codex.app/Contents/Resources/codex",
        ]
        let systemApps = relativeAppPaths.map {
            URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent($0)
        }
        let userApps = relativeAppPaths.map {
            homeDirectory.appendingPathComponent("Applications", isDirectory: true).appendingPathComponent($0)
        }
        return systemApps + userApps + [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
    }

    public static func lookupOnPath() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["codex"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : URL(fileURLWithPath: value)
    }
}
