import AppKit
import ApplicationServices
import QianniuSenderCore
import UnreadCore
import AutoReplyCore

/// A narrow UI adapter: only the labelled contact search and freshly resolved
/// conversation-list container can be mutated. No composer/message values read.
@MainActor final class NativeConversationList {
    private struct Snapshot {
        let pid: pid_t
        let frame: CGRect
        let nodes: [SenderAXNode]
        let elements: [Int: AXUIElement]
    }
    private var previousPage: [String] = []
    private var direction: Int32 = -1
    private var conversationListPolicy: ConversationListPolicy
    private var identityPolicy: ConversationIdentityPolicy

    init(
        conversationListPolicy: ConversationListPolicy = .legacy,
        identityPolicy: ConversationIdentityPolicy = .default
    ) {
        self.conversationListPolicy = conversationListPolicy
        self.identityPolicy = identityPolicy
    }

    func apply(profile: MachineCompatibilityProfile) {
        conversationListPolicy = profile.conversationListPolicy ?? .legacy
        identityPolicy = profile.identityPolicy ?? .default
    }

    func restoreSearch() async throws {
        let snapshot = try read()
        guard let node = ConversationListSelection.searchField(nodes: snapshot.nodes, window: snapshot.frame),
              let element = snapshot.elements[node.id] else {
            throw AutomationDriverError.unsafeUI("无法唯一识别左侧联系人搜索框；未清空任何输入")
        }
        let value: String? = attribute(element, kAXValueAttribute)
        guard let value else { throw AutomationDriverError.unsafeUI("搜索框值不可读；未修改") }
        guard !value.isEmpty else { return }
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, "" as CFString) == .success else {
            throw AutomationDriverError.unsafeUI("无法恢复联系人列表")
        }
        try await Task.sleep(for: .milliseconds(350))
        let fresh = try read()
        guard let field = ConversationListSelection.searchField(nodes: fresh.nodes, window: fresh.frame),
              let target = fresh.elements[field.id], let empty: String = attribute(target, kAXValueAttribute), empty.isEmpty else {
            throw AutomationDriverError.unsafeUI("联系人搜索清空回读失败")
        }
    }

    func scrollOnePage(expectedRows: [ConversationRow]) throws {
        let snapshot = try read()
        // Never activate the app solely to poll/scroll an idle list.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return }
        let nodes = snapshot.nodes.map { AXNode(id: $0.id, parent: $0.parentID, role: $0.role,
            title: $0.title ?? "", description: $0.description ?? "", frame: $0.frame) }
        let rows = try ConversationLocator.candidates(
            nodes: nodes,
            window: snapshot.frame,
            policy: conversationListPolicy,
            identityPolicy: identityPolicy
        ).compactMap(\.row)
        guard rows.map(\.uid) == expectedRows.map(\.uid), rows.map(\.frame) == expectedRows.map(\.frame),
              let container = ConversationListSelection.scrollContainer(nodes: snapshot.nodes, rowIDs: rows.map(\.nodeID), window: snapshot.frame),
              let element = snapshot.elements[container.id] else {
            throw AutomationDriverError.unsafeUI("滚动前列表已变化或容器不唯一；未滚动")
        }
        let point = CGPoint(x: container.frame.midX, y: container.frame.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, descendant(hit, of: element, pid: snapshot.pid) else {
            throw AutomationDriverError.unsafeUI("会话列表被遮挡；未滚动")
        }
        let page = rows.map(\.uid)
        if page == previousPage { direction *= -1 }
        previousPage = page
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: direction * Int32(container.frame.height * 0.8), wheel2: 0, wheel3: 0) else {
            throw AutomationDriverError.unsafeUI("无法创建列表滚动事件")
        }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    private func descendant(_ hit: AXUIElement, of element: AXUIElement, pid: pid_t) -> Bool {
        var current = hit
        for _ in 0..<40 {
            var actual: pid_t = 0
            guard AXUIElementGetPid(current, &actual) == .success, actual == pid else { return false }
            if CFEqual(current, element) { return true }
            guard let parent: AXUIElement = attribute(current, kAXParentAttribute) else { return false }
            current = parent
        }
        return false
    }
    private func read() throws -> Snapshot {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.taobao.Aliworkbench")
        guard apps.count == 1, let app = apps.first else { throw AutomationDriverError.unsafeUI("未找到唯一千牛进程") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        let windows: [AXUIElement] = attribute(root, kAXWindowsAttribute) ?? []
        let descriptions = windows.map {
            ReceptionWindowDescriptor(
                title: attribute($0, kAXTitleAttribute) ?? "",
                frame: bounds($0) ?? .zero,
                minimized: attribute($0, kAXMinimizedAttribute) ?? false
            )
        }
        let focusedWindow: AXUIElement? = attribute(root, kAXFocusedWindowAttribute)
        let focusedIndex = focusedWindow.flatMap { focused in windows.firstIndex { CFEqual($0, focused) } }
        guard let selectedIndex = ReceptionWindowSelection.index(in: descriptions, focusedIndex: focusedIndex) else {
            throw AutomationDriverError.unsafeUI("存在多个接待窗口但无法确认当前窗口")
        }
        let window = windows[selectedIndex]
        let frame = descriptions[selectedIndex].frame
        let deadline = Date().addingTimeInterval(5)
        var queue: [(AXUIElement, Int?, Int)] = [(window, nil, 0)], cursor = 0
        var nodes: [SenderAXNode] = [], elements: [Int: AXUIElement] = [:]
        while cursor < queue.count {
            guard cursor < 2500, Date() < deadline else { throw AutomationDriverError.unsafeUI("联系人结构读取超时或过大") }
            let (element, parent, depth) = queue[cursor]; let id = cursor; cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.2)
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            let rect = bounds(element) ?? .zero
            let left = rect.maxX <= frame.minX + frame.width * 0.4
            let readLabel = left && ["AXGroup", "AXRow", "AXButton", "AXTextField", "AXComboBox", "AXCheckBox", "AXRadioButton"].contains(role)
            nodes.append(SenderAXNode(id: id, parentID: parent, role: role,
                title: readLabel ? attribute(element, kAXTitleAttribute) : nil,
                description: readLabel ? attribute(element, kAXDescriptionAttribute) : nil,
                value: nil, frame: rect, isEnabled: attribute(element, kAXEnabledAttribute) ?? true))
            elements[id] = element
            if depth < 35 {
                let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
                queue.append(contentsOf: children.map { ($0, id, depth + 1) })
            }
        }
        guard Date() < deadline else { throw AutomationDriverError.unsafeUI("联系人结构读取超时") }
        return Snapshot(pid: app.processIdentifier, frame: frame, nodes: nodes, elements: elements)
    }
    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
    private func bounds(_ element: AXUIElement) -> CGRect? {
        guard let p: AXValue = attribute(element, kAXPositionAttribute), let s: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
