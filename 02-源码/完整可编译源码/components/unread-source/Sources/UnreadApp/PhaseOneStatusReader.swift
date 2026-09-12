import AppKit
import ApplicationServices
import UnreadCore

/// Observation only: never activates an app, presses controls, or reads editable/chat text.
@MainActor enum PhaseOneStatusReader {
    struct Reading {
        let sample: OCRStatusSample?
        let warning: String?
    }
    static func shouldDescend(role: String) -> Bool {
        ![kAXTextAreaRole as String, kAXTextFieldRole as String, kAXScrollAreaRole as String].contains(role)
    }
    static func read() -> Reading {
        guard AXIsProcessTrusted() else {
            return Reading(sample: nil, warning: "缺少辅助功能权限，无法观察一期版界面；文件日志仍可显示")
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.scy.qianniu-ocr.copy-experiment")
        guard apps.count == 1, let app = apps.first else {
            return Reading(sample: nil, warning: "一期版未运行或存在多个进程，无法可靠观察界面")
        }
        let expected = "/Applications/AI客服三件套-通用复制实验版.app/Contents/Resources/Components/千牛主聊天区OCR-通用复制实验版.app"
        guard app.bundleURL?.standardizedFileURL.path == expected else {
            return Reading(sample: nil, warning: "一期版路径不同，未读取其他版本的状态")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let deadline = Date().addingTimeInterval(0.15)
        var queue = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var index = 0
        var texts: [String] = []
        var enabled: [Bool] = []
        while index < queue.count && index < 140 && Date() < deadline {
            let element = queue[index]; index += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if role == kAXStaticTextRole as String,
               let value = attribute(element, kAXValueAttribute) as? String {
                texts.append(String(value.prefix(1500)))
            }
            if role == kAXButtonRole as String {
                let title = attribute(element, kAXTitleAttribute) as? String
                let description = attribute(element, kAXDescriptionAttribute) as? String
                if PhaseOneLink.matchesRecognitionButton(role: role, title: title, description: description),
                   let value = attribute(element, kAXEnabledAttribute) as? Bool { enabled.append(value) }
            }
            if shouldDescend(role: role) {
                queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }
        }
        guard enabled.count == 1, let value = enabled.first,
              let sample = OCRStatusSample(texts: texts, recognitionButtonEnabled: value) else {
            return Reading(sample: nil, warning: "一期版界面状态暂不可读；未据此判断完成")
        }
        return Reading(sample: sample, warning: nil)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.03)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
