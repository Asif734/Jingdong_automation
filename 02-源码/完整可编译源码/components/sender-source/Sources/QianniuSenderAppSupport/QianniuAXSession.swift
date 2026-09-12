import AppKit
import ApplicationServices
import Foundation
import OSLog
import QianniuSenderCore

public enum QianniuAXError: LocalizedError {
    case accessibilityMissing
    case appNotRunning
    case windowNotFound
    case elementNotFound(String)
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityMissing: return "请在系统设置的辅助功能权限中允许千牛自动发送"
        case .appNotRunning: return "千牛未运行"
        case .windowNotFound: return "未找到千牛接待中心窗口"
        case .elementNotFound(let name): return "未找到千牛控件：\(name)"
        case .actionFailed(let detail): return "千牛控件操作失败：\(detail)"
        }
    }
}

public final class QianniuAXSession: @unchecked Sendable, QianniuSendingSession {
    private let bundleID = "com.taobao.Aliworkbench"
    private var expectedUID = ""
    private var expectedNickname: String?
    private var nicknamesByUID: [String: String] = [:]
    private var composerPolicy: ComposerSelectionPolicy?
    private var sendTriggerOverride: QianniuSendTrigger?
    private let verificationLog = Logger(subsystem: "com.local.qianniu-auto-sender.stable", category: "send-verification")

    public init(
        composerPolicy: ComposerSelectionPolicy? = nil,
        sendTrigger: QianniuSendTrigger? = nil
    ) {
        self.composerPolicy = composerPolicy
        sendTriggerOverride = sendTrigger
    }

    public func apply(
        composerPolicy: ComposerSelectionPolicy?,
        sendTrigger: QianniuSendTrigger?
    ) {
        self.composerPolicy = composerPolicy
        sendTriggerOverride = sendTrigger
    }

    public func bindNickname(uid: String, nickname: String?) {
        guard let nickname, !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        nicknamesByUID[uid] = nickname
        if expectedUID == uid { expectedNickname = nickname }
    }

    public func activate() async throws {
        try ensureTrusted(prompt: true)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw QianniuAXError.appNotRunning
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 3.0)
        let windows: [AXUIElement] = attribute(kAXWindowsAttribute, from: application) ?? []
        let receptionWindows = windows.filter { window in
            let title: String = attribute(kAXTitleAttribute, from: window) ?? ""
            return title.contains("接待中心")
        }
        let focusedWindow: AXUIElement? = attribute(kAXFocusedWindowAttribute, from: application)
        let focusedReception = focusedWindow.flatMap { focused in
            receptionWindows.first { CFEqual($0, focused) }
        }
        guard let receptionWindow = focusedReception ?? (receptionWindows.count == 1 ? receptionWindows[0] : nil) else {
            throw QianniuAXError.windowNotFound
        }
        if let minimized: Bool = attribute(kAXMinimizedAttribute, from: receptionWindow), minimized {
            _ = AXUIElementSetAttributeValue(
                receptionWindow,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        let focused = try await Self.activateWindow(
            request: {
                try Self.requestApplicationActivation(
                    isHidden: app.isHidden,
                    unhide: { app.unhide() },
                    activate: { app.activate(options: []) }
                )
            },
            focus: {
                let focusedWindow = AXUIElementSetAttributeValue(
                    application, kAXFocusedWindowAttribute as CFString, receptionWindow
                ) == .success
                let main = AXUIElementSetAttributeValue(
                    receptionWindow, kAXMainAttribute as CFString, kCFBooleanTrue
                ) == .success
                let focused = AXUIElementSetAttributeValue(
                    receptionWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue
                ) == .success
                return focusedWindow || main || focused
            },
            raise: {
                AXUIElementPerformAction(receptionWindow, kAXRaiseAction as CFString) == .success
            },
            verify: {
                Self.isFocusedReceptionWindow(
                    receptionWindow,
                    application: application,
                    processIdentifier: app.processIdentifier,
                    isTerminated: app.isTerminated
                )
            },
            maximumAttempts: 10
        )
        guard focused else {
            throw QianniuAXError.actionFailed("千牛接待中心未能切到前台")
        }
    }

    static func activateWindow(
        request: () async throws -> Void,
        focus: () -> Bool,
        raise: () -> Bool,
        verify: () -> Bool,
        maximumAttempts: Int,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }
    ) async throws -> Bool {
        for _ in 0..<max(1, maximumAttempts) {
            try Task.checkCancellation()
            try await request()
            _ = focus()
            _ = raise()
            try await pause()
            if verify() { return true }
        }
        return false
    }

    static func requestApplicationActivation(
        isHidden: Bool,
        unhide: () -> Bool,
        activate: () -> Bool
    ) throws {
        if isHidden, !unhide() {
            throw QianniuAXError.actionFailed("无法取消隐藏千牛")
        }
        // Qt/App-Translocation builds can return false even though the request was
        // delivered. The exact AX focused-window check below is authoritative.
        _ = activate()
    }

    private static func isFocusedReceptionWindow(
        _ target: AXUIElement,
        application: AXUIElement,
        processIdentifier: pid_t,
        isTerminated: Bool
    ) -> Bool {
        let appIsFrontmost = !isTerminated
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
        var rawFocused: CFTypeRef?
        let focusedReadSucceeded = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &rawFocused
        ) == .success
        var targetMatchesFocusedWindow = false
        if focusedReadSucceeded, let rawFocused,
           CFGetTypeID(rawFocused) == AXUIElementGetTypeID() {
            targetMatchesFocusedWindow = CFEqual(
                unsafeDowncast(rawFocused, to: AXUIElement.self),
                target
            )
        }
        var rawTitle: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            target,
            kAXTitleAttribute as CFString,
            &rawTitle
        )
        return targetFocusMatches(
            appIsFrontmost: appIsFrontmost,
            targetMatchesFocusedWindow: targetMatchesFocusedWindow,
            targetTitle: rawTitle as? String ?? ""
        )
    }

    static func targetFocusMatches(
        appIsFrontmost: Bool,
        targetMatchesFocusedWindow: Bool,
        targetTitle: String
    ) -> Bool {
        appIsFrontmost && targetMatchesFocusedWindow && targetTitle.contains("接待中心")
    }

    public func isFrontmost() async throws -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw QianniuAXError.appNotRunning
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    public func searchAndOpen(uid: String) async throws {
        expectedUID = uid
        expectedNickname = nicknamesByUID[uid]
        var snapshot = try readSnapshot()
        guard let search = QianniuElementSelection.searchField(nodes: snapshot.nodes, window: snapshot.windowFrame),
              let searchElement = snapshot.elements[search.id] else {
            throw QianniuAXError.elementNotFound("左侧联系人搜索框")
        }
        try setValue(uid, on: searchElement)
        try await wait(milliseconds: 350)
        snapshot = try readSnapshot()
        if let result = QianniuElementSelection.searchResult(uid: uid, nodes: snapshot.nodes, window: snapshot.windowFrame),
           let point = QianniuElementSelection.interactionPoint(for: result, inside: snapshot.windowFrame) {
            try click(point: point, label: "搜索结果")
        } else {
            guard AXUIElementSetAttributeValue(
                searchElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            ) == .success else {
                throw QianniuAXError.actionFailed("无法聚焦联系人搜索框")
            }
            try postKey(keyCode: 36, label: "Return")
        }
        try await wait(milliseconds: 550)
    }

    public func currentChatAssessment(expectedUID: String) async throws -> SendEvidenceAssessment {
        let snapshot = try readSnapshot()
        guard !expectedUID.isEmpty else { throw QianniuAXError.actionFailed("目标客户身份为空") }
        let inputRegion = chatRegion(in: snapshot)
        guard let input = messageInput(in: snapshot, chatRegion: inputRegion) else {
            throw QianniuAXError.elementNotFound("消息输入框")
        }
        let region = chatRegion(in: snapshot, input: input)
        return QianniuElementSelection.routedConversationAssessment(
            uid: expectedUID,
            nodes: snapshot.nodes,
            window: snapshot.windowFrame,
            chatRegion: region
        )
    }

    /// Setup-only probe. Reads the current reception window but never focuses,
    /// types, clicks, or changes the selected customer.
    public func composerAvailableReadOnly() async throws -> Bool {
        let snapshot = try readSnapshot()
        let region = chatRegion(in: snapshot)
        return messageInput(in: snapshot, chatRegion: region) != nil
    }

    public func setMessageInput(_ text: String) async throws {
        let snapshot = try readSnapshot()
        let region = chatRegion(in: snapshot)
        guard let input = messageInput(in: snapshot, chatRegion: region),
              let inputElement = snapshot.elements[input.id] else {
            throw QianniuAXError.elementNotFound("消息输入框")
        }
        try setValue(text, on: inputElement)
        try await wait(milliseconds: 120)
    }

    public func messageInputAssessment(expectedText: String) async throws -> SendEvidenceAssessment {
        let snapshot = try readSnapshot()
        let region = chatRegion(in: snapshot)
        guard let input = messageInput(in: snapshot, chatRegion: region) else {
            throw QianniuAXError.elementNotFound("消息输入框")
        }
        guard let value = input.value else { return .unknown("输入内容暂时无法回读") }
        return value == expectedText
            ? .confirmedCorrect
            : .confirmedWrong("输入内容回读不一致")
    }

    public func waitBeforeUnknownRecheck() async { try? await wait(milliseconds: 1_000) }

    public func recordMarkerWasWritten() async {}

    public func pressSend() async throws {
        let snapshot = try readSnapshot()
        let region = chatRegion(in: snapshot)
        guard let input = messageInput(in: snapshot, chatRegion: region),
              let inputElement = snapshot.elements[input.id],
              let button = QianniuElementSelection.sendButton(nodes: snapshot.nodes, input: input),
              let trigger = sendTriggerOverride ?? QianniuElementSelection.sendTrigger(for: button) else {
            throw QianniuAXError.elementNotFound("发送按钮")
        }
        switch trigger {
        case .accessibilityPress:
            guard let buttonElement = snapshot.elements[button.id] else {
                throw QianniuAXError.elementNotFound("发送按钮")
            }
            try press(element: buttonElement, label: "发送按钮")
        case .returnKeyOnce:
            guard AXUIElementSetAttributeValue(
                inputElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            ) == .success else {
                throw QianniuAXError.actionFailed("按 Enter 发送前无法聚焦消息输入框")
            }
            try postKey(keyCode: 36, label: "Return")
        }
    }

    private func messageInput(in snapshot: Snapshot, chatRegion: CGRect) -> SenderAXNode? {
        if let composerPolicy {
            return QianniuElementSelection.messageInput(
                nodes: snapshot.nodes,
                chatRegion: chatRegion,
                policy: composerPolicy
            )
        }
        return QianniuElementSelection.messageInput(nodes: snapshot.nodes, chatRegion: chatRegion)
    }

    public func verifySent(text: String) async throws -> Bool {
        var didContinueRepeatWarning = false
        var stability = SendVerificationStability(requiredConsecutiveChecks: 2)
        var nextDelay: UInt64 = 350
        for _ in 0..<3 {
            try await wait(milliseconds: nextDelay)
            if repeatWarningIsVisible() {
                guard !didContinueRepeatWarning else { return false }
                try continueRepeatWarning()
                didContinueRepeatWarning = true
                stability = SendVerificationStability(requiredConsecutiveChecks: 1)
                nextDelay = 120
                continue
            }
            let windows = try readWindowSnapshots()
            if let warningIndex = QianniuElementSelection.repeatWarningWindowIndex(
                windowNodes: windows.map { $0.snapshot.nodes }
            ) {
                let snapshot = windows[warningIndex].snapshot
                guard !didContinueRepeatWarning,
                      let button = QianniuElementSelection.continueSendButtonForRepeatWarning(nodes: snapshot.nodes),
                      let buttonElement = snapshot.elements[button.id] else {
                    return false
                }
                try press(element: buttonElement, label: "重复消息提醒中的继续发送")
                didContinueRepeatWarning = true
                stability = SendVerificationStability(requiredConsecutiveChecks: 1)
                nextDelay = 120
                continue
            }
            guard let snapshot = primarySnapshot(from: windows) else {
                throw QianniuAXError.windowNotFound
            }
            let region = chatRegion(in: snapshot)
            let inputEmpty = messageInput(in: snapshot, chatRegion: region)
                .map { $0.value?.isEmpty ?? false } ?? false
            let identityStillMatches = QianniuElementSelection.routedConversationMatches(
                uid: expectedUID,
                nodes: snapshot.nodes,
                window: snapshot.windowFrame,
                chatRegion: region
            )
            verificationLog.info("Initial send check: inputEmpty=\(inputEmpty), identityMatches=\(identityStillMatches)")
            if stability.record(
                clearSuccessCandidate: inputEmpty && identityStillMatches,
                warningVisible: false
            ) {
                return true
            }
            nextDelay = 400
        }
        return false
    }

    public func recheckSent(text: String) async throws -> Bool {
        // Slow UI updates get a bounded second observation window, never another send action.
        var stability = SendVerificationStability(requiredConsecutiveChecks: 2)
        for _ in 0..<5 {
            try await wait(milliseconds: 1_000)
            let windows = try readWindowSnapshots()
            let warningVisible = repeatWarningIsVisible()
                || QianniuElementSelection.repeatWarningWindowIndex(windowNodes: windows.map { $0.snapshot.nodes }) != nil
            guard let snapshot = primarySnapshot(from: windows) else { return false }
            let region = chatRegion(in: snapshot)
            let inputEmpty = messageInput(in: snapshot, chatRegion: region)
                .map { $0.value?.isEmpty ?? false } ?? false
            let identityMatches = QianniuElementSelection.routedConversationMatches(
                uid: expectedUID, nodes: snapshot.nodes, window: snapshot.windowFrame, chatRegion: region
            )
            verificationLog.info("Read-only delayed check: inputEmpty=\(inputEmpty), identityMatches=\(identityMatches), warningVisible=\(warningVisible)")
            if stability.record(clearSuccessCandidate: inputEmpty && identityMatches, warningVisible: warningVisible) {
                return true
            }
        }
        return false
    }

    private func repeatWarningIsVisible() -> Bool {
        if focusedRepeatWarningIsVisible() { return true }
        return repeatWarningWindow() != nil
    }

    private func repeatWarningWindow() -> SenderVisibleWindow? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            CGWindowID(0)
        ) as? [[String: Any]] else {
            return nil
        }
        let windows = rawWindows.compactMap { raw -> SenderVisibleWindow? in
            guard let pidNumber = raw[kCGWindowOwnerPID as String] as? NSNumber,
                  let bounds = raw[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let title = raw[kCGWindowName as String] as? String ?? ""
            return SenderVisibleWindow(ownerPID: pidNumber.int32Value, title: title, frame: frame)
        }
        return QianniuElementSelection.repeatWarningWindow(
            windows: windows,
            qianniuPID: app.processIdentifier
        )
    }

    private func focusedRepeatWarningIsVisible() -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let focused: AXUIElement = attribute(kAXFocusedUIElementAttribute, from: system) else {
            return false
        }
        let role: String = attribute(kAXRoleAttribute, from: focused) ?? ""
        let title: String = attribute(kAXTitleAttribute, from: focused) ?? ""
        guard role == "AXButton", title == "返回修改" || title == "继续发送" else {
            return false
        }
        if let window: AXUIElement = attribute(kAXWindowAttribute, from: focused) {
            let windowTitle: String = attribute(kAXTitleAttribute, from: window) ?? ""
            if windowTitle.contains("服务态度提醒") { return true }
        }
        var current = focused
        for _ in 0..<8 {
            guard let parent: AXUIElement = attribute(kAXParentAttribute, from: current) else { break }
            let labels: [String] = [
                attribute(kAXTitleAttribute, from: parent),
                attribute(kAXDescriptionAttribute, from: parent),
                attribute(kAXValueAttribute, from: parent),
            ].compactMap { $0 }
            if labels.contains(where: { $0.contains("服务态度提醒") }) { return true }
            current = parent
        }
        return false
    }

    private func continueRepeatWarning() throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else {
            throw QianniuAXError.actionFailed("重复消息提醒出现时千牛不在前台")
        }
        guard let warning = repeatWarningWindow(),
              let point = QianniuElementSelection.continueSendPointForRepeatWarning(window: warning) else {
            throw QianniuAXError.actionFailed("无法定位重复消息提醒中的继续发送")
        }
        try click(point: point, label: "重复消息提醒中的继续发送")
    }

    private func postKey(keyCode: CGKeyCode, label: String) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw QianniuAXError.actionFailed("无法创建\(label)键盘事件")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func chatRegion(in snapshot: Snapshot, input: SenderAXNode? = nil) -> CGRect {
        let chosenInput = input ?? snapshot.nodes
            .filter { $0.role == "AXTextArea" && $0.isEnabled }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let chosenInput else { return snapshot.windowFrame }
        let left = max(snapshot.windowFrame.minX, chosenInput.frame.minX - snapshot.windowFrame.width * 0.02)
        let right = min(snapshot.windowFrame.maxX, chosenInput.frame.maxX + snapshot.windowFrame.width * 0.08)
        return CGRect(x: left, y: snapshot.windowFrame.minY, width: max(1, right - left), height: snapshot.windowFrame.height)
    }

    private func readSnapshot() throws -> Snapshot {
        guard let snapshot = primarySnapshot(from: try readWindowSnapshots()) else {
            throw QianniuAXError.windowNotFound
        }
        return snapshot
    }

    private func primarySnapshot(from windows: [WindowSnapshot]) -> Snapshot? {
        windows
            .filter { $0.snapshot.windowFrame.width > 700 && $0.snapshot.windowFrame.height > 500 }
            .sorted {
                if $0.isFocused != $1.isFocused { return $0.isFocused }
                return scoreWindow($0.title) > scoreWindow($1.title)
            }
            .first?
            .snapshot
    }

    private func readWindowSnapshots() throws -> [WindowSnapshot] {
        try ensureTrusted(prompt: false)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw QianniuAXError.appNotRunning
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 3.0)
        var windows: [AXUIElement] = attribute(kAXWindowsAttribute, from: application) ?? []
        let focusedWindow: AXUIElement? = attribute(kAXFocusedWindowAttribute, from: application)
        if let focusedWindow,
           !windows.contains(where: { CFEqual($0, focusedWindow) }) {
            windows.insert(focusedWindow, at: 0)
        }
        return windows.compactMap { element -> WindowSnapshot? in
            guard let windowFrame = frame(of: element), windowFrame.width > 200, windowFrame.height > 100 else { return nil }
            let title: String = attribute(kAXTitleAttribute, from: element) ?? ""
            var queue: [(AXUIElement, Int?)] = [(element, nil)]
            var index = 0
            var nodes: [SenderAXNode] = []
            var elements: [Int: AXUIElement] = [:]
            while index < queue.count, index < 20_000 {
                let (child, parentID) = queue[index]
                index += 1
                var nextParent = parentID
                if let nodeFrame = frame(of: child), nodeFrame.width > 0, nodeFrame.height > 0 {
                    let id = nodes.count
                    let role: String = attribute(kAXRoleAttribute, from: child) ?? ""
                    let node = SenderAXNode(
                        id: id,
                        parentID: parentID,
                        role: role,
                        title: attribute(kAXTitleAttribute, from: child),
                        description: attribute(kAXDescriptionAttribute, from: child),
                        value: attribute(kAXValueAttribute, from: child),
                        frame: nodeFrame,
                        isEnabled: attribute(kAXEnabledAttribute, from: child) ?? true
                    )
                    nodes.append(node)
                    elements[id] = child
                    nextParent = id
                }
                let children: [AXUIElement] = attribute(kAXChildrenAttribute, from: child) ?? []
                queue.append(contentsOf: children.map { ($0, nextParent) })
            }
            return WindowSnapshot(
                title: title,
                isFocused: title.contains("接待中心") && (focusedWindow.map { CFEqual($0, element) } ?? false),
                snapshot: Snapshot(windowFrame: windowFrame, nodes: nodes, elements: elements)
            )
        }
    }

    private func ensureTrusted(prompt: Bool) throws {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary) else {
            throw QianniuAXError.accessibilityMissing
        }
    }

    private func setValue(_ value: String, on element: AXUIElement) throws {
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success else {
            throw QianniuAXError.actionFailed("无法写入文本")
        }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let p: AXValue = attribute(kAXPositionAttribute, from: element),
              let s: AXValue = attribute(kAXSizeAttribute, from: element) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    private func scoreWindow(_ title: String) -> Int {
        (title.contains("接待中心") ? 100 : 0) + (title.contains("千牛") ? 20 : 0)
    }

    private func wait(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private func click(point: CGPoint, label: String) throws {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw QianniuAXError.actionFailed("无法创建\(label)点击事件")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func press(element: AXUIElement, label: String) throws {
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw QianniuAXError.actionFailed("无法按下\(label)")
        }
    }

}

private struct Snapshot {
    let windowFrame: CGRect
    let nodes: [SenderAXNode]
    let elements: [Int: AXUIElement]
}

private struct WindowSnapshot {
    let title: String
    let isFocused: Bool
    let snapshot: Snapshot
}
