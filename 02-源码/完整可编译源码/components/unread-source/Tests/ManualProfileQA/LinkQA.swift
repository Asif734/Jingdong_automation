import SwiftUI
import ApplicationServices

// Read-only harness, not in the production target. No AXPress or chat actions.
@main struct LinkQA: App {
    @State var result = "只检查一期按钮，不扫描聊天、不发送。"
    var body: some Scene {
        Window("一期按钮 · 隔离检查", id: "link-qa") {
            VStack(alignment: .leading) {
                Button("检查一期按钮（不触发）") {
                    var report: [String] = []
                    do { try PhaseOneLink.checkIdleIfRunning(); report.append("生产检查：通过") }
                    catch { report.append("生产检查：\(error.localizedDescription)") }
                    func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
                        AXUIElementSetMessagingTimeout(element, 0.2)
                        var value: CFTypeRef?
                        let code = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                        return code == .success ? value : nil
                    }
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.scy.qianniu-ocr.copy-experiment") {
                        var queue = read(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
                        var i = 0
                        while i < queue.count && i < 300 {
                            let e = queue[i]; i += 1
                            let role = read(e, kAXRoleAttribute) as? String ?? ""
                            if role == "AXButton" {
                                report.append("button title=\(read(e,kAXTitleAttribute) as? String ?? "nil") desc=\(read(e,kAXDescriptionAttribute) as? String ?? "nil") enabled=\(String(describing:read(e,kAXEnabledAttribute)))")
                            }
                            if role != "AXTextArea" && role != "AXTextField" { queue += read(e,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
                        }
                    }
                    result = report.joined(separator: "\n")
                }
                Text(result).textSelection(.enabled)
            }.padding(24).frame(width: 750)
        }
    }
}
