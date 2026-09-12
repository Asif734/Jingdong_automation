import Foundation

protocol VideoTransferCapabilityRunning: Sendable {
    func hostnameIsReachable(_ hostname: String, timeout: Duration) async -> Bool
}

private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

struct SystemVideoTransferCapabilityRunner: VideoTransferCapabilityRunning {
    func hostnameIsReachable(_ hostname: String, timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            let output = Pipe()
            let gate = CompletionGate()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
            process.arguments = ["+time=1", "+tries=1", "+short", hostname]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                guard gate.claim() else { return }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: process.terminationStatus == 0 && !data.isEmpty)
            }
            do {
                try process.run()
            } catch {
                if gate.claim() { continuation.resume(returning: false) }
                return
            }
            let components = timeout.components
            let seconds = max(
                0.1,
                Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
            )
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                guard gate.claim() else { return }
                if process.isRunning { process.terminate() }
                continuation.resume(returning: false)
            }
        }
    }
}

struct VideoTransferCapabilityProbe: Sendable {
    let curlURL: URL
    let digURL: URL
    let runner: any VideoTransferCapabilityRunning

    init(
        curlURL: URL = URL(fileURLWithPath: "/usr/bin/curl"),
        digURL: URL = URL(fileURLWithPath: "/usr/bin/dig"),
        runner: any VideoTransferCapabilityRunning = SystemVideoTransferCapabilityRunner()
    ) {
        self.curlURL = curlURL
        self.digURL = digURL
        self.runner = runner
    }

    func probe(fileManager: FileManager = .default) async -> [String: CapabilityStatus] {
        let reachable = await runner.hostnameIsReachable(
            "msg2.cloudvideocdn.taobao.com",
            timeout: .seconds(2)
        )
        let curlAvailable = fileManager.isExecutableFile(atPath: curlURL.path)
        let digAvailable = fileManager.isExecutableFile(atPath: digURL.path)
        return [
            "videoDownloadSystem": CapabilityStatus(
                level: reachable ? .verified : .fallback,
                strategy: "ephemeral-urlsession",
                detail: reachable
                    ? "系统视频线路只读解析通过"
                    : "当前未解析到视频域名；收到视频后按有界重试恢复"
            ),
            "videoDownloadAlternate": CapabilityStatus(
                level: curlAvailable && digAvailable ? .verified : .unavailable,
                strategy: "curl-resolve-race",
                detail: curlAvailable && digAvailable
                    ? "系统 curl 与 dig 可用于备用视频线路"
                    : "备用线路工具不完整；仍保留系统下载线路"
            )
        ]
    }

    static let calibrationDefaults: [String: CapabilityStatus] = [
        "videoDownloadSystem": CapabilityStatus(
            level: .fallback,
            strategy: "ephemeral-urlsession",
            detail: "运行时按实际视频地址验证"
        ),
        "videoDownloadAlternate": CapabilityStatus(
            level: .fallback,
            strategy: "curl-resolve-race",
            detail: "首次启动时检测备用线路工具"
        )
    ]
}
