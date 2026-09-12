import Foundation
import QianniuOCRCore
import QianniuSenderCore
import AutoReplyCore
import AppKit
import ApplicationServices
import Darwin

struct ReceptionWindowDescriptor: Equatable {
    let title: String
    let frame: CGRect
    let minimized: Bool
}

enum ReceptionWindowSelection {
    static func index(in windows: [ReceptionWindowDescriptor], focusedIndex: Int?) -> Int? {
        let eligible = windows.indices.filter { index in
            let window = windows[index]
            return window.title.contains("接待") && !window.minimized
                && window.frame.width > 500 && window.frame.height > 300
        }
        if let focusedIndex, eligible.contains(focusedIndex) { return focusedIndex }
        return eligible.count == 1 ? eligible[0] : nil
    }
}

enum ReceptionWindowGeometry {
    static func matches(
        accessibility: CGRect,
        capture: CGRect,
        mapping: CoordinateMapping
    ) -> Bool {
        mapping.matches(accessibility: accessibility, capture: capture)
    }

    static func matches(accessibility: CGRect, capture: CGRect) -> Bool {
        abs(capture.minX - accessibility.minX) <= 2
            && abs(capture.width - accessibility.width) <= 2
            && abs(capture.height - accessibility.height) <= 2
            && abs(capture.minY - accessibility.minY) <= 24
    }
}

final class SessionLock {
    private let descriptor: Int32
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let opened = url.path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR) }
        guard opened >= 0 else { throw AutomationDriverError.unsafeUI("无法打开会话锁") }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(opened)
            throw AutomationDriverError.unsafeUI("全自动客服已运行；请使用现有窗口")
        }
        descriptor = opened
    }
    deinit { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }
}
enum OperatorProcessPolicy {
    static func blocks(_ command: String, schemaPath: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable: String
        if text.hasPrefix("/"), let range = text.range(of: ".app/Contents/MacOS/"),
           !text[..<range.lowerBound].contains(" -") {
            executable = String(text[range.upperBound...].prefix { !$0.isWhitespace })
        } else {
            executable = URL(fileURLWithPath: String(text.prefix { !$0.isWhitespace })).lastPathComponent
        }
        if ["UnreadApp", "QianniuOCRApp", "千牛主聊天区OCR-PlanB", "CustomerReplyBatchApp", "AI客服-Codex批处理",
            "QianniuAutoSender", "千牛自动发送"].contains(executable) { return true }
        guard executable == "codex" else { return false }
        let needle = "--output-schema " + schemaPath
        guard let match = text.range(of: needle) else { return false }
        return match.upperBound == text.endIndex || text[match.upperBound].isWhitespace
    }
}
enum QuitPolicy {
    static func mayTerminate(uiActive: Bool, liveGenerations: Int) -> Bool { !uiActive && liveGenerations == 0 }
}
enum ConversationListSelection {
    static func searchField(nodes: [SenderAXNode], window: CGRect) -> SenderAXNode? {
        let leftSearch = nodes.filter { $0.frame.maxX < window.minX + window.width * 0.4
            && $0.frame.maxY < window.minY + window.height * 0.4 && $0.role != "AXTextArea" }
        return QianniuElementSelection.searchField(nodes: leftSearch, window: window)
    }
    static func scrollContainer(nodes: [SenderAXNode], rowIDs: [Int], window: CGRect) -> SenderAXNode? {
        guard !rowIDs.isEmpty else { return nil }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func isAncestor(_ id: Int, of row: Int) -> Bool {
            var next = byID[row]?.parentID
            for _ in 0..<40 { guard let n = next else { return false }; if n == id { return true }; next = byID[n]?.parentID }
            return false
        }
        let candidates = nodes.filter { node in ["AXScrollArea", "AXList", "AXOutline", "AXGroup"].contains(node.role)
            && node.isEnabled && window.contains(node.frame) && node.frame.width < window.width * 0.4
            && node.frame.minX < window.minX + window.width * 0.28
            && rowIDs.allSatisfy { isAncestor(node.id, of: $0) } }
        return candidates.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

@MainActor enum AutomationPermissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenCapture: Bool { CGPreflightScreenCaptureAccess() }
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    static func requestScreenCapture() { _ = CGRequestScreenCaptureAccess() }
    static func openSettings(accessibility: Bool) {
        let pane = accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

@MainActor final class NativeSafety {
    let schemaPath: String
    private var nextProcessCheck = Date.distantPast
    init(schemaPath: String) { self.schemaPath = schemaPath }
    func check(includeOwnedCLI: Bool = false, forceProcessCheck: Bool = false) throws {
        guard AutomationPermissions.accessibility, AutomationPermissions.screenCapture else {
            throw AutomationDriverError.unsafeUI("缺少本应用辅助功能或屏幕录制权限，请在状态窗口授权")
        }
        if !includeOwnedCLI && !forceProcessCheck && Date() < nextProcessCheck { return }
        nextProcessCheck = Date().addingTimeInterval(2)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps"); process.arguments = ["-axww", "-o", "command="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
            throw AutomationDriverError.unsafeUI("无法核对竞争进程；未启动")
        }
        let schema = includeOwnedCLI ? schemaPath : "\u{0}never-owned-schema"
        if output.split(separator: "\n").contains(where: { OperatorProcessPolicy.blocks(String($0), schemaPath: schema) }) {
            throw AutomationDriverError.unsafeUI("旧未读/OCR/批处理/发送程序或本应用残留 CLI 仍在运行；请等待结束后再启动")
        }
    }
}
