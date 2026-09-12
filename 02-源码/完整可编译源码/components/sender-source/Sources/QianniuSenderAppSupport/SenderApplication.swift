import AppKit
import Foundation
import QianniuSenderCore

public enum SenderApplicationRunner {
    public static let defaultQueueRoot = FileManager.default
        .urls(for: .desktopDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AI客服记录", isDirectory: true)

    public static func runQueue(root: URL = defaultQueueRoot) async -> SenderRunSummary {
        do {
            let store = try SenderQueueStore(root: root)
            let transaction = QianniuSendTransaction(session: QianniuAXSession())
            return await SenderWorker(store: store, sender: transaction).runUntilDrained()
        } catch {
            var summary = SenderRunSummary()
            summary.failedBeforeSend = 1
            return summary
        }
    }
}

@MainActor
public final class SenderAppDelegate: NSObject, NSApplicationDelegate {
    private let authorizedTestUIDs = ["stoneshishininger", "tb263147182"]
    private var window: NSWindow!
    private var uidPopup: NSPopUpButton!
    private var messageField: NSTextField!
    private var statusLabel: NSTextField!
    private var sendButton: NSButton!

    public func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "千牛自动发送（测试）"
        window.center()
        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "仅限已授权测试账号")
        title.font = .boldSystemFont(ofSize: 18)
        uidPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        uidPopup.addItems(withTitles: authorizedTestUIDs)
        messageField = NSTextField(string: "自动发送测试 \(Int(Date().timeIntervalSince1970))")
        messageField.placeholderString = "要发送的测试消息"
        sendButton = NSButton(title: "打开千牛并发送", target: self, action: #selector(sendNow))
        sendButton.bezelStyle = .rounded
        statusLabel = NSTextField(wrappingLabelWithString: "就绪。队列模式可由 AI 客服批处理程序自动触发。")
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, uidPopup, messageField, sendButton, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        uidPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        messageField.widthAnchor.constraint(equalToConstant: 500).isActive = true
        statusLabel.widthAnchor.constraint(equalToConstant: 500).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
        ])
    }

    @objc private func sendNow() {
        let uid = uidPopup.titleOfSelectedItem ?? ""
        let text = messageField.stringValue
        guard authorizedTestUIDs.contains(uid), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusLabel.stringValue = "UID 或消息无效"
            return
        }
        sendButton.isEnabled = false
        statusLabel.stringValue = "正在打开千牛并核对 UID…"
        let marker = SenderApplicationRunner.defaultQueueRoot
            .appendingPathComponent("运行状态/手动发送尝试", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
        Task { @MainActor in
            let outcome = await QianniuSendTransaction(session: QianniuAXSession())
                .send(uid: uid, text: text, attemptMarkerURL: marker)
            switch outcome {
            case .sent: statusLabel.stringValue = "发送成功：\(uid)"
            case .failedBeforeSend(let reason): statusLabel.stringValue = "未发送：\(reason)"
            case .uncertainAfterSend(let reason): statusLabel.stringValue = "需人工确认：\(reason)"
            }
            sendButton.isEnabled = true
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
