import AppKit
import ApplicationServices
import UnreadCore

/// External button press only. The phase-one bundle and its business logic are unchanged.
@MainActor enum PhaseOneLink {
    private static let appURL = URL(fileURLWithPath: "/Applications/AI客服三件套-通用复制实验版.app/Contents/Resources/Components/千牛主聊天区OCR-通用复制实验版.app")
    private static let bundleID = "com.scy.qianniu-ocr.copy-experiment"

    static func checkIdleIfRunning() throws {
        guard FileManager.default.fileExists(atPath: appURL.path) else { throw AssistantError.unsafe("未找到已安装的一期版；未切换客户。") }
        guard let app = try existingApp() else { return }
        let buttons = try recognitionButtons(AXUIElementCreateApplication(app.processIdentifier), deadline: Date().addingTimeInterval(2))
        guard !buttons.isEmpty else { throw AssistantError.unsafe("未找到一期版识别按钮；请打开一期版主窗口。未切换客户。") }
        guard buttons.count == 1, let button = buttons.first else { throw AssistantError.unsafe("一期版有多个识别按钮；未切换客户。") }
        guard let enabled = attribute(button, kAXEnabledAttribute) as? Bool else { throw AssistantError.unsafe("一期版按钮可用状态读取失败；未切换客户。") }
        guard enabled else { throw AssistantError.unsafe("一期版正在识别；请等待识别完成后重试。未切换客户。") }
    }

    static func trigger(uid: String, currentUID: () async throws -> String?, beforePress: () throws -> Void = {}) async throws {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw AssistantError.unsafe("未找到已安装的一期版；未触发识别。")
        }
        var app = try existingApp()
        if app == nil {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            app = try existingApp()
        }
        guard let app else { throw AssistantError.unsafe("一期版未能启动；未触发识别。") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            guard !app.isTerminated, try existingApp()?.processIdentifier == app.processIdentifier else {
                throw AssistantError.unsafe("一期版进程发生变化；未触发识别。")
            }
            let buttons = try recognitionButtons(root, deadline: deadline)
            guard buttons.count <= 1 else { throw AssistantError.unsafe("一期版有多个识别窗口；未触发，避免重复执行。") }
            if let button = buttons.first {
                guard let enabled = attribute(button, kAXEnabledAttribute) as? Bool else { throw AssistantError.unsafe("一期版按钮可用状态读取失败；未触发。") }
                guard enabled else { throw AssistantError.unsafe("一期版正在识别；本次未触发。") }
                // Opening the old app may have taken time: verify the current customer again.
                guard try await currentUID() == uid else { throw AssistantError.unsafe("触发前千牛用户已变化；未触发一期版。") }
                guard Date() < deadline, !app.isTerminated,
                      attribute(button, kAXEnabledAttribute) as? Bool == true else {
                    throw AssistantError.unsafe("一期版状态变化；本次未触发。")
                }
                // Exactly one AXPress; never retry an uncertain side effect.
                try beforePress()
                guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                    throw AssistantError.unsafe("一期版识别按钮未确认触发；未自动重试，请查看一期版状态。")
                }
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw AssistantError.unsafe("未找到一期版的识别按钮；未触发。")
    }

    private static func existingApp() throws -> NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard apps.count <= 1, apps.allSatisfy({ $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL }) else {
            throw AssistantError.unsafe("存在多个一期版进程或其他位置的同名版本；未触发。")
        }
        return apps.first
    }

    private static func recognitionButtons(_ root: AXUIElement, deadline: Date) throws -> [AXUIElement] {
        var queue = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var cursor = 0
        var buttons: [AXUIElement] = []
        while cursor < queue.count {
            guard cursor < 500, Date() < deadline else { throw AssistantError.unsafe("一期版控件读取超时；未触发。") }
            let element = queue[cursor]; cursor += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if role == kAXButtonRole as String,
               matchesRecognitionButton(role: role, title: attribute(element, kAXTitleAttribute) as? String,
                                        description: attribute(element, kAXDescriptionAttribute) as? String) {
                buttons.append(element)
            }
            // Do not read OCR output or editable text.
            if role != kAXTextAreaRole as String && role != kAXTextFieldRole as String {
                queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }
        }
        return buttons
    }

    static func matchesRecognitionButton(role: String, title: String?, description: String?) -> Bool {
        // SwiftUI exposes the visible button label as AXDescription, with no AXTitle.
        let label = title.flatMap { $0.isEmpty ? nil : $0 } ?? description
        return role == kAXButtonRole as String && label == "识别千牛主聊天区"
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
