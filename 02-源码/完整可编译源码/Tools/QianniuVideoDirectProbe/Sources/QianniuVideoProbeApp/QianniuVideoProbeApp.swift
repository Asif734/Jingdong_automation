import AppKit
import Foundation
import QianniuVideoProbeCore
import SwiftUI

@main
struct QianniuVideoProbeApp: App {
    var body: some Scene {
        WindowGroup("千牛视频直链测试器") {
            ProbeView()
        }
        .windowResizability(.contentSize)
    }
}

private struct ProbeView: View {
    @StateObject private var model = ProbeViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("千牛视频直链测试器")
                .font(.system(size: 28, weight: .bold))
            Text("不使用 OCR、不录屏、不发送消息。只验证这台 Mac 能否从千牛的新播放器日志取得临时地址并下载原始视频。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    Label("打开千牛并进入测试客户的聊天框", systemImage: "1.circle.fill")
                    Label("点击下方“开始监听”", systemImage: "2.circle.fill")
                    Label("60 秒内在聊天框中点开一条测试视频", systemImage: "3.circle.fill")
                    Label("等待自动下载、验证并导出结果 ZIP", systemImage: "4.circle.fill")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack(spacing: 10) {
                ProgressView().opacity(model.isRunning ? 1 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status).font(.headline)
                    Text(model.detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 48, alignment: .leading)

            HStack {
                Button(model.isRunning ? "正在测试…" : "开始监听") {
                    model.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)

                Button("打开结果") { model.revealResult() }
                    .disabled(model.resultURL == nil)
                Spacer()
                Text("不会保存临时签名地址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(26)
        .frame(width: 650)
    }
}

@MainActor
private final class ProbeViewModel: ObservableObject {
    @Published var status = "准备就绪"
    @Published var detail = "开始监听后再点开视频，避免误用旧日志。"
    @Published var isRunning = false
    @Published var resultURL: URL?

    private var task: Task<Void, Never>?
    private var outputFolder: URL?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        resultURL = nil
        status = "正在检查千牛日志"
        detail = "尚未读取任何旧视频地址。"
        task = Task { await runProbe() }
    }

    func revealResult() {
        guard let outputFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
    }

    private func runProbe() async {
        let discoveryStarted = Date()
        var discoveryMilliseconds = 0
        var downloadMilliseconds = 0
        var httpStatus: Int?
        var fileSummary: SanitizedProbeReport.FileSummary?
        let machine = machineSummary()

        do {
            let logRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Aliworkbench/System/log")
            let logURLs = ["app.log", "app.log.old"].map { logRoot.appendingPathComponent($0) }
            guard logURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ProbeUIError.missingLog
            }
            let folder = try makeOutputFolder()
            outputFolder = folder
            status = "正在监听新视频"
            detail = "请现在到千牛聊天框里点开一条测试视频。"

            var watcher = try VideoCandidateWatcher().arm(in: logURLs)
            let signedURL = try await watcher.wait(timeout: .seconds(60))
            discoveryMilliseconds = max(0, Int(Date().timeIntervalSince(discoveryStarted) * 1_000))
            status = "已发现视频，正在下载"
            detail = "临时地址只保留在内存，不会写入报告。"

            let destination = folder.appendingPathComponent("下载的视频.mp4")
            let receipt = try await VideoDownloadClient().download(from: signedURL, to: destination)
            downloadMilliseconds = receipt.elapsedMilliseconds
            httpStatus = receipt.statusCode
            status = "正在验证视频"
            detail = "检查容器、时长、轨道、分辨率和文件哈希。"
            fileSummary = try await VideoFileInspector.inspect(receipt.fileURL)

            let report = SanitizedProbeReport(
                machine: machine,
                result: .passed,
                discoveryMilliseconds: discoveryMilliseconds,
                downloadMilliseconds: downloadMilliseconds,
                httpStatus: httpStatus,
                file: fileSummary,
                failure: nil
            )
            try write(report: report, to: folder)
            let zip = try zipFolder(folder)
            resultURL = zip
            status = "测试通过"
            detail = "视频已下载并验证，脱敏结果 ZIP 已生成在桌面。"
            NSWorkspace.shared.activateFileViewerSelecting([zip])
        } catch {
            let message = publicMessage(for: error)
            if outputFolder == nil {
                outputFolder = try? makeOutputFolder()
            }
            if let folder = outputFolder {
                let report = SanitizedProbeReport(
                    machine: machine,
                    result: .failed,
                    discoveryMilliseconds: discoveryMilliseconds,
                    downloadMilliseconds: downloadMilliseconds,
                    httpStatus: httpStatus,
                    file: fileSummary,
                    failure: message
                )
                try? write(report: report, to: folder)
                if let zip = try? zipFolder(folder) { resultURL = zip }
            }
            status = "测试未通过"
            detail = message
        }
        isRunning = false
    }

    private func makeOutputFolder() throws -> URL {
        let desktop = try FileManager.default.url(
            for: .desktopDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = desktop.appendingPathComponent(
            "千牛视频直链测试结果-\(Host.current().localizedName ?? "Mac")-\(formatter.string(from: Date()))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func write(report: SanitizedProbeReport, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: folder.appendingPathComponent("result.json"),
            options: .atomic
        )
        try Data(ProbeReportMarkdown.render(report).utf8).write(
            to: folder.appendingPathComponent("测试报告.md"),
            options: .atomic
        )
    }

    private func zipFolder(_ folder: URL) throws -> URL {
        let zip = folder.deletingLastPathComponent()
            .appendingPathComponent(folder.lastPathComponent + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, zip.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw VideoProbeError.outputFailed }
        return zip
    }

    private func machineSummary() -> SanitizedProbeReport.Machine {
        let qianniuBundle = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.taobao.Aliworkbench" })?
            .bundleURL.flatMap(Bundle.init(url:))
            ?? Bundle(path: "/Applications/Aliworkbench.app")
        let version = qianniuBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return .init(
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            qianniuVersion: version
        )
    }

    private func publicMessage(for error: Error) -> String {
        if let error = error as? ProbeUIError { return error.localizedDescription }
        if let error = error as? VideoProbeError { return error.localizedDescription }
        return "测试发生未知错误；结果中未记录内部地址或原始错误文本。"
    }
}

private enum ProbeUIError: LocalizedError {
    case missingLog

    var errorDescription: String? {
        switch self {
        case .missingLog: return "没有找到千牛 app.log；请先启动千牛并进入接待中心。"
        }
    }
}
