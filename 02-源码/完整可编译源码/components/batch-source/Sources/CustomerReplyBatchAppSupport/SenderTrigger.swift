import Foundation

public protocol SenderTriggering: Sendable {
    func trigger() async
}

public struct NoopSenderTrigger: SenderTriggering {
    public init() {}
    public func trigger() async {}
}

public struct ProcessSenderTrigger: SenderTriggering {
    struct LaunchCommand {
        let executableURL: URL
        let arguments: [String]
    }

    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func trigger() async {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return }
        let command = Self.launchCommand(for: executableURL)
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {}
    }

    static func launchCommand(for executableURL: URL) -> LaunchCommand {
        let appURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return LaunchCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-n", appURL.path, "--args", "--run-queue"]
        )
    }
}
