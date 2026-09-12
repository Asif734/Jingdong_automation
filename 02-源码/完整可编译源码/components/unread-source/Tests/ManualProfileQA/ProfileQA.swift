// Isolated manual QA entry point. Never part of the production app target.
// Compiled with the unchanged production NativeSession/WindowCapture sources.
import SwiftUI
import UnreadCore

@main struct ProfileQA: App {
    @State private var result = "仅读取当前聊天身份；不点击会话、不触发一期、不发送。"
    @State private var busy = false
    @State private var compareWorkspaceActivation = false
    var body: some Scene {
        WindowGroup("完整身份读取 · 隔离测试") {
            VStack(alignment: .leading, spacing: 16) {
                Text(result).textSelection(.enabled)
                Toggle("对照：用系统打开现有千牛窗口后再读 ID", isOn: $compareWorkspaceActivation).disabled(busy)
                Button("读取当前完整 ID（不触发一期）") {
                    busy = true
                    let entry = "button: selfActive=\(NSApp.isActive), front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")"
                    Task { @MainActor in
                        let start = Date()
                        try? await Task.sleep(for: .milliseconds(300))
                        let taskEntry = "task: selfActive=\(NSApp.isActive), front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")"
                        do {
                            if compareWorkspaceActivation {
                                let config = NSWorkspace.OpenConfiguration()
                                config.activates = true
                                config.createsNewApplicationInstance = false
                                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Aliworkbench.app"), configuration: config)
                                try await Task.sleep(for: .milliseconds(200))
                            }
                            let session = NativeSession()
                            try session.check()
                            let uid = try await session.header()
                            result = "读取结果：\(uid ?? "nil")；耗时 \(String(format: "%.2f", Date().timeIntervalSince(start))) 秒"
                        } catch {
                            let q = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "千牛" || $0.localizedName == "Qianniu" }.map { "\($0.bundleIdentifier ?? "nil") pid=\($0.processIdentifier) policy=\($0.activationPolicy.rawValue) active=\($0.isActive)" }.joined(separator: ";")
                            result = "失败：\(error.localizedDescription)；\(entry)；\(taskEntry)；前台 \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")；\(q)"
                        }
                        busy = false
                    }
                }.disabled(busy)
            }.padding(24).frame(width: 620, height: 160)
        }
    }
}
