import AppKit
import ApplicationServices
import UnreadCore

@MainActor final class NativeSession: UnreadSession {
    private var application: NSRunningApplication?
    private var windowElement: AXUIElement?
    private var elements: [Int: AXUIElement] = [:]
    private var deadline = Date()

    func check() throws {
        guard AXIsProcessTrusted() else { throw AssistantError.unsafe("缺少辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，添加并启用“千牛未读助手”。授权后重新打开本应用。") }
        guard CGPreflightScreenCaptureAccess() else { throw AssistantError.unsafe("缺少屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕与系统音频录制，添加并启用“千牛未读助手”。授权后重新打开本应用。") }
        let matches = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "千牛" || $0.localizedName == "Qianniu" }
        guard matches.count == 1, let app = matches.first else { throw AssistantError.unsafe("请先打开千牛接待中心（未找到唯一千牛进程）。") }
        application = app
    }

    func snapshot() throws -> SceneSnapshot {
        let (nodes, frame, id) = try readWindow()
        writeDiagnostic(nodes: nodes, frame: frame, windowID: id)
        let candidates = try ConversationLocator.candidates(nodes: nodes, window: frame)
        return SceneSnapshot(windowID: id, frame: frame, candidates: candidates)
    }
    func capture(_ snapshot: SceneSnapshot) async throws -> PixelImage {
        guard let app = application else { throw AssistantError.unsafe("千牛进程不可用。") }
        return try await WindowCapture.capture(snapshot, pid: app.processIdentifier)
    }
    func activate() async throws {
        guard let app = application, !app.isTerminated, let appURL = app.bundleURL,
              let window = windowElement else { throw AssistantError.unsafe("千牛窗口不可用。") }
        try await Self.activateWindow(request: {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            let opened = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            guard opened.processIdentifier == app.processIdentifier else {
                throw AssistantError.unsafe("千牛进程发生变化；未点击。")
            }
            return true
        },
                                raise: { AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success },
                                isFrontmost: { !app.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier })
    }
    static func activateWindow(request: () async throws -> Bool, raise: () -> Bool, isFrontmost: () -> Bool) async throws {
        try Task.checkCancellation()
        // Request acceptance is not foreground state. Raise the exact window, then
        // wait briefly for the real PID; click() independently revalidates it again.
        _ = try await request()
        try Task.checkCancellation()
        guard raise() else { throw AssistantError.unsafe("无法激活千牛接待窗口。") }
        for attempt in 0...20 {
            try Task.checkCancellation()
            if isFrontmost() { return }
            if attempt < 20 { try await Task.sleep(for: .milliseconds(50)) }
        }
        throw AssistantError.unsafe("千牛未能切到前台；未点击，请确认接待窗口未被其他应用占用。")
    }
    func click(_ row: ConversationRow, scene: SceneSnapshot) throws {
        // Re-resolve immediately, synchronously, after the last asynchronous capture.
        let freshScene = try snapshot()
        guard freshScene == scene,
              let fresh = ConversationLocator.fresh(uid: row.uid, rows: freshScene.rows), fresh.frame == row.frame,
              elements[fresh.nodeID] != nil, let app = application,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw AssistantError.unsafe("点击前窗口、行位置或前台应用已变化；未点击。")
        }
        // Qianniu row containers can accept AXPress without switching the chat.
        // Always click the freshly resolved row; header verification stays in OpenWorkflow.
        let point = CGPoint(x: fresh.frame.minX + fresh.frame.width * 0.5, y: fresh.frame.midY)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, hitMatchesRow(hit, row: fresh, scene: scene, pid: app.processIdentifier) else { throw AssistantError.unsafe("目标行被遮挡或命中核对失败；未点击。") }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw AssistantError.unsafe("无法创建点击事件。") }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    static func matchesRowHit(_ node: AXNode, row: ConversationRow, hitPID: pid_t, targetPID: pid_t,
                              fallbackNickname: String? = nil) -> Bool {
        guard hitPID == targetPID, ["AXGroup", "AXRow"].contains(node.role), node.frame == row.frame else { return false }
        if ConversationLocator.verified(expected: row.uid, actual: ConversationLocator.displayTitle(node)) { return true }
        // Only rows whose routing identity was itself derived from the unique visible nickname
        // may use this path. A structural UID is never replaced by a nickname during hit checking.
        return row.uid == row.nickname
            && ConversationLocator.verified(expected: row.uid, actual: fallbackNickname)
    }
    private func hitMatchesRow(_ hit: AXUIElement, row: ConversationRow, scene: SceneSnapshot, pid: pid_t) -> Bool {
        guard let window = windowElement else { return false }
        let windowTitle = string(window, kAXTitleAttribute)
        guard !windowTitle.isEmpty else { return false }
        var current = hit, matchedRow = false
        for _ in 0..<20 {
            var hitPID: pid_t = 0
            guard AXUIElementGetPid(current, &hitPID) == .success, hitPID == pid else { return false }
            let role = string(current, kAXRoleAttribute)
            if role == kAXWindowRole as String {
                return matchedRow && frame(current) == scene.frame && string(current, kAXTitleAttribute) == windowTitle
            }
            if ["AXGroup", "AXRow"].contains(role), let bounds = frame(current), bounds == row.frame {
                // Qt may recreate an AX wrapper between traversal and hit testing.
                // Require the same full UID, row geometry, process and owning window.
                let node = AXNode(id: 0, role: role, title: string(current, kAXTitleAttribute),
                                  value: string(current, kAXValueAttribute),
                                  description: string(current, kAXDescriptionAttribute), frame: bounds)
                let fallback = row.uid == row.nickname ? liveNickname(in: current, rowFrame: bounds) : nil
                matchedRow = matchedRow || Self.matchesRowHit(node, row: row, hitPID: hitPID, targetPID: pid,
                                                               fallbackNickname: fallback)
            }
            guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }
    private func liveNickname(in rowElement: AXUIElement, rowFrame: CGRect) -> String? {
        let rowNode = AXNode(id: 0, role: "AXGroup", frame: rowFrame)
        var queue = attribute(rowElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var cursor = 0
        var candidates: Set<String> = []
        while cursor < queue.count && cursor < 60 && Date() < deadline {
            let element = queue[cursor]
            cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            if string(element, kAXRoleAttribute) == kAXStaticTextRole as String,
               let bounds = frame(element) {
                let node = AXNode(id: cursor, role: "AXStaticText", title: string(element, kAXTitleAttribute),
                                  value: string(element, kAXValueAttribute),
                                  description: string(element, kAXDescriptionAttribute), frame: bounds)
                if let value = ConversationLocator.nicknameCandidate(node, in: rowNode) { candidates.insert(value) }
            }
            if queue.count < 60 {
                queue.append(contentsOf: (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(60 - queue.count))
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }
    func header() async throws -> String? {
        let (nodes, frame, _) = try readWindow()
        if let uid = ConversationLocator.header(nodes: nodes, window: frame) { return uid }
        guard let heading = ConversationLocator.displayHeaderNode(nodes: nodes, window: frame),
              let display = ConversationLocator.displayTitle(heading),
              display.hasSuffix("...") || display.hasSuffix("…") else { return nil }
        return try await profileIdentity(heading: heading, display: display)
    }
    private func profileIdentity(heading: AXNode, display: String) async throws -> String? {
        try await activate()
        // App activation completes asynchronously; revalidate the title after yielding.
        try await Task.sleep(for: .milliseconds(150))
        let (freshNodes, freshFrame, _) = try readWindow()
        guard let fresh = ConversationLocator.displayHeaderNode(nodes: freshNodes, window: freshFrame),
              fresh == heading, let element = elements[fresh.id], let app = application,
              let reception = windowElement else { throw AssistantError.unsafe("读取完整身份前聊天标题已变化；未触发一期版。") }
        let initialRows = try ConversationLocator.rows(nodes: freshNodes, window: freshFrame)
        // Profile polling owns a new bounded budget; never reuse the traversal's remaining time.
        deadline = Date().addingTimeInterval(3)
        let receptionTitle = string(reception, kAXTitleAttribute)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        // Do not yield between validating the heading and clicking it.
        let before = try await requiredWindows(root, reception: reception, retryTransient: false)
        guard !before.contains(where: { string($0, kAXTitleAttribute).hasSuffix("的资料") }) else {
            throw AssistantError.unsafe("已有客户资料窗，请关闭后重试；未复用可能过期的身份。")
        }
        let point = CGPoint(x: fresh.frame.midX, y: fresh.frame.midY)
        var hit: AXUIElement?
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw AssistantError.unsafe("千牛尚未成为前台应用（当前：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知")）；未读取资料或触发一期版。")
        }
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, isDescendant(hit, of: element) else {
            throw AssistantError.unsafe("聊天标题被遮挡，无法读取完整身份；未触发一期版。")
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw AssistantError.unsafe("无法创建资料窗点击事件；未触发一期版。")
        }
        // Opens the current chat's read-only profile, never a transfer/send control.
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(80))
            let windows = try await requiredWindows(root, reception: reception)
            let profiles = windows.filter { candidate in
                !before.contains(where: { CFEqual($0, candidate) }) && string(candidate, kAXTitleAttribute).hasSuffix("的资料")
            }
            guard profiles.count <= 1 else { throw AssistantError.unsafe("出现多个资料窗，无法确定当前身份；未触发。") }
            guard let profile = profiles.first else { continue }
            let title = string(profile, kAXTitleAttribute)
            guard let rawClose = attribute(profile, kAXCloseButtonAttribute), CFGetTypeID(rawClose) == AXUIElementGetTypeID(),
                  AXUIElementPerformAction(unsafeDowncast(rawClose, to: AXUIElement.self), kAXPressAction as CFString) == .success else {
                throw AssistantError.unsafe("无法关闭客户资料窗；未触发一期版，请手动关闭。")
            }
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(50))
                let remaining = try await requiredWindows(root, reception: reception)
                if !remaining.contains(where: { CFEqual($0, profile) }) {
                    let (afterNodes, afterFrame, _) = try readWindow()
                    guard ConversationLocator.displayHeaderNode(nodes: afterNodes, window: afterFrame).flatMap(ConversationLocator.displayTitle) == display else {
                        throw AssistantError.unsafe("读取资料时聊天已切换；未触发一期版。")
                    }
                    let rows = try ConversationLocator.rows(nodes: afterNodes, window: afterFrame)
                    guard afterFrame == freshFrame, rows == initialRows,
                          let currentWindow = windowElement, CFEqual(currentWindow, reception),
                          let uid = ConversationLocator.profileUID(profileTitle: title, receptionTitle: receptionTitle, displayTitle: display, rows: rows) else {
                        throw AssistantError.unsafe("资料窗完整 ID 与当前标题或左侧列表不一致；未触发一期版。")
                    }
                    return uid
                }
            }
            throw AssistantError.unsafe("资料窗关闭状态未确认；未触发一期版。")
        }
        throw AssistantError.unsafe("聊天标题被省略且未读到完整会员资料；未触发一期版。")
    }
    private func requiredWindows(_ root: AXUIElement, reception: AXUIElement, retryTransient: Bool = true) async throws -> [AXUIElement] {
        while Date() < deadline {
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &raw)
            // Qianniu briefly returns cannotComplete while its profile window is closing.
            // Retry only this read, within the existing budget; never infer an empty list.
            if result == .cannotComplete && retryTransient {
                try await Task.sleep(for: .milliseconds(75))
                continue
            }
            guard result == .success, let windows = raw as? [AXUIElement], Date() < deadline else {
                throw AssistantError.unsafe("客户资料窗窗口列表读取失败（AX \(result.rawValue)）；未触发一期版。")
            }
            guard windows.contains(where: { CFEqual($0, reception) }) else {
                throw AssistantError.unsafe("客户资料窗核验缺少原接待窗口；未触发一期版。")
            }
            return windows
        }
        throw AssistantError.unsafe("客户资料窗核验超时；未触发一期版。")
    }
    private func isDescendant(_ hit: AXUIElement, of row: AXUIElement) -> Bool {
        var current = hit
        for _ in 0..<20 {
            if CFEqual(current, row) { return true }
            guard let parent = attribute(current, kAXParentAttribute) else { return false }
            guard CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }
    private func readWindow() throws -> ([AXNode], CGRect, UInt32) {
        guard let app = application, !app.isTerminated, !app.isHidden else { throw AssistantError.unsafe("千牛未运行或已隐藏。") }
        deadline = Date().addingTimeInterval(5)
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let candidates = windows.filter { window in
            let title = string(window, kAXTitleAttribute)
            return title.contains("接待") && (attribute(window, kAXMinimizedAttribute) as? Bool != true)
        }
        guard candidates.count == 1, let window = candidates.first, let frame = frame(window), frame.width > 500, frame.height > 300 else {
            throw AssistantError.unsafe("未找到唯一可见接待窗口；请打开接待中心并取消最小化。")
        }
        let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let matching = windowInfo.filter { item in
            guard (item[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (item[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return abs(rect.minX-frame.minX) < 1 && abs(rect.minY-frame.minY) < 1 && abs(rect.width-frame.width) < 1 && abs(rect.height-frame.height) < 1
        }
        guard matching.count == 1, let id = matching.first?[kCGWindowNumber as String] as? UInt32 else { throw AssistantError.unsafe("无法匹配当前可见接待窗口编号。") }
        elements = [:]
        var raw: [(id: Int, parent: Int?, role: String, frame: CGRect)] = []
        var queue: [(AXUIElement, Int?, Int)] = [(window, nil, 0)], cursor = 0
        while cursor < queue.count {
            guard cursor < 2500, Date() < deadline else { throw AssistantError.unsafe("辅助功能结构读取超时或过大；未点击。") }
            let (element, parent, depth) = queue[cursor]
            let nodeID = cursor; cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.2)
            elements[nodeID] = element
            raw.append((nodeID, parent, string(element, kAXRoleAttribute), self.frame(element) ?? .zero))
            if depth < 35 {
                for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { queue.append((child, nodeID, depth + 1)) }
            }
        }
        // Only control labels, row-container identity fields, the row's top nickname region,
        // and header-aligned text are read. Chat body, lower message previews and editable
        // fields are never read.
        var controls: [Int: AXNode] = [:]
        for node in raw where ["AXButton", "AXMenuButton", "AXCheckBox", "AXRadioButton"].contains(node.role) {
            let element = elements[node.id]!
            controls[node.id] = AXNode(id: node.id, parent: node.parent, role: node.role, title: string(element, kAXTitleAttribute), description: string(element, kAXDescriptionAttribute), frame: node.frame)
        }
        let headerY = controls.values.first { $0.labels.contains("转发当前用户") }?.frame.midY
        let rawByID = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rowFrames = Dictionary(uniqueKeysWithValues: raw.compactMap { node -> (Int, CGRect)? in
            let isRow = ["AXGroup", "AXRow"].contains(node.role) && node.frame.width >= 100
                && node.frame.width < frame.width * 0.4 && node.frame.minX < frame.minX + frame.width * 0.28
                && node.frame.height >= 30 && node.frame.height <= 100
            return isRow ? (node.id, node.frame) : nil
        })
        func owningRow(_ node: (id: Int, parent: Int?, role: String, frame: CGRect)) -> AXNode? {
            var parent = node.parent
            for _ in 0..<40 {
                guard let id = parent else { return nil }
                if let rowFrame = rowFrames[id] { return AXNode(id: id, role: "AXGroup", frame: rowFrame) }
                parent = rawByID[id]?.parent
            }
            return nil
        }
        var nodes: [AXNode] = []
        for node in raw {
            if let control = controls[node.id] { nodes.append(control); continue }
            let isRow = ["AXGroup", "AXRow"].contains(node.role) && node.frame.width >= 100 && node.frame.width < frame.width * 0.4 && node.frame.minX < frame.minX + frame.width * 0.28 && node.frame.height >= 30 && node.frame.height <= 100
            let isHeader = node.role == "AXStaticText" && headerY.map { abs(node.frame.midY - $0) < 15 } == true
            let unlabeled = AXNode(id: node.id, parent: node.parent, role: node.role, frame: node.frame)
            let isNicknameCandidate = owningRow(node).map { ConversationLocator.isPotentialNicknameNode(unlabeled, in: $0) } == true
            let element = elements[node.id]!
            nodes.append(AXNode(id: node.id, parent: node.parent, role: node.role,
                                title: isRow || isHeader || isNicknameCandidate ? string(element, kAXTitleAttribute) : "",
                                value: isHeader || isNicknameCandidate ? string(element, kAXValueAttribute) : "",
                                description: isRow || isHeader || isNicknameCandidate ? string(element, kAXDescriptionAttribute) : "", frame: node.frame))
        }
        guard Date() < deadline else { throw AssistantError.unsafe("辅助功能读取超时；未点击。") }
        windowElement = window
        return (nodes, frame, id)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let pos = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(pos, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private func writeDiagnostic(nodes: [AXNode], frame: CGRect, windowID: UInt32) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QianniuUnreadAssistant", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let lines = nodes.map { node in
                let marker = node.labels.contains("正在接待买家列表") ? " receptionAnchor" : node.labels.contains("转发当前用户") ? " headerControl" : node.labels.contains("新建任务") ? " taskControl" : ""
                return "\(node.id) p=\(node.parent.map(String.init) ?? "-") \(node.role) \(NSStringFromRect(node.frame))\(marker)"
            }
            let summary = "\(Date().ISO8601Format()) window=\(windowID) \(NSStringFromRect(frame)) nodes=\(nodes.count)\n" + lines.joined(separator: "\n")
            try summary.write(to: root.appendingPathComponent("last-diagnostic.txt"), atomically: true, encoding: .utf8)
        } catch { /* Diagnostics are best effort, never a reason to click. */ }
    }
}
