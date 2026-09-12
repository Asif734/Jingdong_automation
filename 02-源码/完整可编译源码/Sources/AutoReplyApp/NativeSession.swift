import AppKit
import ApplicationServices
import QianniuOCRCore
import UnreadCore

@MainActor final class NativeSession: UnreadSession {
    private let preferStructuralUID: Bool
    private var identityPolicy: ConversationIdentityPolicy
    private var conversationListPolicy: ConversationListPolicy
    private var windowPolicy: WindowSelectionPolicy?
    private var application: NSRunningApplication?
    private var windowElement: AXUIElement?
    private var elements: [Int: AXUIElement] = [:]
    private var deadline = Date()

    init(
        preferStructuralUID: Bool = true,
        identityPolicy: ConversationIdentityPolicy = .default,
        conversationListPolicy: ConversationListPolicy = .legacy,
        windowPolicy: WindowSelectionPolicy? = nil
    ) {
        self.preferStructuralUID = preferStructuralUID
        self.identityPolicy = identityPolicy
        self.conversationListPolicy = conversationListPolicy
        self.windowPolicy = windowPolicy
    }

    func apply(profile: MachineCompatibilityProfile) {
        identityPolicy = profile.identityPolicy ?? .default
        conversationListPolicy = profile.conversationListPolicy ?? .legacy
        windowPolicy = profile.windowPolicy
    }

    func check() throws {
        guard AXIsProcessTrusted() else { throw AssistantError.unsafe("缺少辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能，添加并启用“\(AppIdentity.displayName)”。授权后重新打开本应用。") }
        guard CGPreflightScreenCaptureAccess() else { throw AssistantError.unsafe("缺少屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕与系统音频录制，添加并启用“\(AppIdentity.displayName)”。授权后重新打开本应用。") }
        let matches = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "千牛" || $0.localizedName == "Qianniu" }
        guard matches.count == 1, let app = matches.first else { throw AssistantError.unsafe("请先打开千牛接待中心（未找到唯一千牛进程）。") }
        application = app
    }

    func snapshot() throws -> SceneSnapshot {
        let (nodes, frame, id) = try readWindow()
        writeDiagnostic(nodes: nodes, frame: frame, windowID: id)
        let candidates = try ConversationLocator.candidates(
            nodes: nodes,
            window: frame,
            policy: conversationListPolicy,
            preferStructuralUID: preferStructuralUID,
            identityPolicy: identityPolicy
        )
        return SceneSnapshot(windowID: id, frame: frame, candidates: candidates)
    }
    func calibrationSnapshot() throws -> CalibrationSnapshot {
        let (nodes, frame, _) = try readWindow()
        let process = ProcessInfo.processInfo
        let appURL = application?.bundleURL
        let bundle = appURL.flatMap(Bundle.init(url:))
        let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let normalizedNodes = nodes.map { node -> CalibrationAXNode in
            let relative = CGRect(
                x: (node.frame.minX - frame.minX) / max(frame.width, 1),
                y: (node.frame.minY - frame.minY) / max(frame.height, 1),
                width: node.frame.width / max(frame.width, 1),
                height: node.frame.height / max(frame.height, 1)
            )
            let actions: [String]
            if let element = elements[node.id] {
                var names: CFArray?
                actions = AXUIElementCopyActionNames(element, &names) == .success
                    ? (names as? [String] ?? [])
                    : []
            } else {
                actions = []
            }
            return CalibrationAXNode(
                id: node.id,
                parentID: node.parent,
                role: node.role,
                actionNames: actions,
                labelCategory: CalibrationLabelCategory.classify(
                    rawLabel: node.labels.first,
                    role: node.role,
                    actions: actions
                ),
                relativeFrame: relative,
                hasValue: !node.labels.isEmpty
            )
        }
        let display = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        return CalibrationSnapshot(
            macOSBuild: process.operatingSystemVersionString,
            architecture: Self.runtimeArchitecture,
            qianniuVersion: version,
            qianniuBuild: build,
            qianniuRuntimeArchitecture: Self.runtimeArchitecture,
            displays: display.map {
                [CalibrationDisplay(relativeFrame: $0.frame, scale: $0.backingScaleFactor)]
            } ?? [],
            windows: [CalibrationWindow(
                roleCategory: "reception",
                relativeFrame: frame,
                captureFrame: frame,
                minimized: false,
                focused: true,
                regionCategories: Set(normalizedNodes.map(\.labelCategory).compactMap {
                    switch $0 {
                    case "正在接待买家列表": "conversation-list"
                    case "chat-region": "chat"
                    case "input-control": "composer"
                    default: nil
                    }
                })
            )],
            nodes: normalizedNodes
        )
    }

    func processIdentifier() throws -> pid_t {
        guard let application, !application.isTerminated else {
            throw AssistantError.unsafe("千牛进程不可用。")
        }
        return application.processIdentifier
    }

    func pressTransferCurrentUser() throws -> TransferMenuAnchor {
        let (nodes, window, windowID) = try readWindow()
        var actionNamesByNodeID: [Int: [String]] = [:]
        for node in nodes where node.role == "AXButton" && node.labels.contains("转发当前用户") {
            guard let element = elements[node.id] else { continue }
            var rawNames: CFArray?
            guard AXUIElementCopyActionNames(element, &rawNames) == .success else { continue }
            actionNamesByNodeID[node.id] = rawNames as? [String] ?? []
        }
        guard let nodeID = TransferMenuSelection.select(
            nodes: nodes,
            window: window,
            actionNamesByNodeID: actionNamesByNodeID
        ), let button = elements[nodeID] else {
            throw AssistantError.unsafe("未找到唯一且可按的“转发当前用户”按钮；未点击。")
        }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw AssistantError.unsafe("无法打开转人工选择界面；未执行后续操作。")
        }
        guard let application else { throw AssistantError.unsafe("千牛进程不可用。") }
        return TransferMenuAnchor(
            ownerPID: application.processIdentifier,
            receptionWindowID: windowID,
            receptionFrame: window,
            buttonFrame: nodes.first(where: { $0.id == nodeID })!.frame
        )
    }

    func clickTransferPopup(point: CGPoint, popupFrame: CGRect) throws {
        guard popupFrame.contains(point),
              let application,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw AssistantError.unsafe("转人工弹窗没有处于千牛前台；未点击内部选项。")
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            throw AssistantError.unsafe("无法创建“转交到组”点击事件。")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static var runtimeArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }
    func capture(_ snapshot: SceneSnapshot) async throws -> PixelImage {
        guard let app = application else { throw AssistantError.unsafe("千牛进程不可用。") }
        return try await WindowCapture.capture(
            snapshot,
            pid: app.processIdentifier,
            coordinateMapping: windowPolicy?.coordinateMapping
        )
    }
    func activate() async throws {
        guard let app = application, !app.isTerminated,
              let window = windowElement else { throw AssistantError.unsafe("千牛窗口不可用。") }
        let axApplication = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApplication, 0.2)
        let focused = try await Self.activateWindow(request: {
            if app.isHidden, !app.unhide() {
                throw AssistantError.unsafe("无法取消隐藏千牛；未点击。")
            }
            return app.activate(options: [])
        },
                                focus: {
                                    let focusedWindow = AXUIElementSetAttributeValue(
                                        axApplication, kAXFocusedWindowAttribute as CFString, window
                                    ) == .success
                                    let main = AXUIElementSetAttributeValue(
                                        window, kAXMainAttribute as CFString, kCFBooleanTrue
                                    ) == .success
                                    let focused = AXUIElementSetAttributeValue(
                                        window, kAXFocusedAttribute as CFString, kCFBooleanTrue
                                    ) == .success
                                    return focusedWindow || main || focused
                                },
                                raise: { AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success },
                                verify: {
                                    Self.isFocusedReceptionWindow(
                                        window,
                                        application: axApplication,
                                        processIdentifier: app.processIdentifier,
                                        isTerminated: app.isTerminated
                                    )
                                },
                                maximumAttempts: 10)
        guard focused else {
            throw AssistantError.unsafe("千牛接待中心未能切到前台；未点击。")
        }
    }
    static func activateWindow(
        request: () async throws -> Bool,
        focus: () -> Bool,
        raise: () -> Bool,
        verify: () -> Bool,
        maximumAttempts: Int,
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }
    ) async throws -> Bool {
        for _ in 0..<max(1, maximumAttempts) {
            try Task.checkCancellation()
            _ = try await request()
            _ = focus()
            _ = raise()
            try await pause()
            if verify() { return true }
        }
        return false
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
    static func matchesRowHit(_ node: AXNode, row: ConversationRow, hitPID: pid_t, targetPID: pid_t) -> Bool {
        hitPID == targetPID && ["AXGroup", "AXRow"].contains(node.role) && node.frame == row.frame
        && (ConversationLocator.verified(expected: row.uid, actual: ConversationLocator.displayTitle(node))
            || (row.uid == row.nickname && row.nickname != nil))
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
                                  description: string(current, kAXDescriptionAttribute), frame: bounds)
                matchedRow = matchedRow || Self.matchesRowHit(node, row: row, hitPID: hitPID, targetPID: pid)
            }
            guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return false
    }
    func header() async throws -> String? {
        let (nodes, frame, _) = try readWindow()
        if let uid = ConversationLocator.header(nodes: nodes, window: frame) { return uid }
        guard let heading = ConversationLocator.displayHeaderNode(nodes: nodes, window: frame),
              let display = ConversationLocator.displayTitle(heading),
              ConversationLocator.requiresProfileIdentity(displayTitle: display) else { return nil }
        return try await profileIdentity(heading: heading, display: display)
    }
    func displayHeaderTitle() throws -> String? {
        let (nodes, frame, _) = try readWindow()
        return ConversationLocator.displayHeaderNode(nodes: nodes, window: frame)
            .flatMap(ConversationLocator.displayTitle)
    }
    func currentReceptionTitle() -> String? {
        windowElement.map { string($0, kAXTitleAttribute) }
    }
    private func profileIdentity(heading: AXNode, display: String) async throws -> String? {
        try await activate()
        // App activation completes asynchronously; revalidate the title after yielding.
        try await Task.sleep(for: .milliseconds(150))
        let (freshNodes, freshFrame, _) = try readWindow()
        guard let fresh = ConversationLocator.displayHeaderNode(nodes: freshNodes, window: freshFrame),
              fresh == heading, let element = elements[fresh.id], let app = application,
              let reception = windowElement else { throw AssistantError.unsafe("读取完整身份前聊天标题已变化；未触发一期版。") }
        let initialRows = try ConversationLocator.candidates(
            nodes: freshNodes,
            window: freshFrame,
            policy: conversationListPolicy,
            preferStructuralUID: preferStructuralUID,
            identityPolicy: identityPolicy
        ).compactMap(\.row)
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
                    let rows = try ConversationLocator.candidates(
                        nodes: afterNodes,
                        window: afterFrame,
                        policy: conversationListPolicy,
                        preferStructuralUID: preferStructuralUID,
                        identityPolicy: identityPolicy
                    ).compactMap(\.row)
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
        let windowDescriptions: [ReceptionWindowDescriptor] = windows.map { element -> ReceptionWindowDescriptor in
            ReceptionWindowDescriptor(
                title: string(element, kAXTitleAttribute),
                frame: self.frame(element) ?? .zero,
                minimized: attribute(element, kAXMinimizedAttribute) as? Bool == true
            )
        }
        let focusedElement: AXUIElement? = {
            guard let raw = attribute(axApp, kAXFocusedWindowAttribute),
                  CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(raw, to: AXUIElement.self)
        }()
        let focusedIndex: Int? = focusedElement.flatMap { focused in
            windows.firstIndex { CFEqual($0, focused) }
        }
        guard let selectedIndex = selectedWindowIndex(
            in: windowDescriptions,
            focusedIndex: focusedIndex
        ) else {
            throw AssistantError.unsafe("存在多个接待窗口但无法确认当前窗口；请点一下要处理的接待窗口。")
        }
        let window = windows[selectedIndex]
        let frame: CGRect = windowDescriptions[selectedIndex].frame
        let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let matching = windowInfo.filter { item in
            guard (item[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (item[kCGWindowLayer as String] as? Int) == 0,
                  (item[kCGWindowName as String] as? String) == windowDescriptions[selectedIndex].title,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            if let mapping = windowPolicy?.coordinateMapping {
                return ReceptionWindowGeometry.matches(
                    accessibility: frame,
                    capture: rect,
                    mapping: mapping
                )
            }
            return ReceptionWindowGeometry.matches(accessibility: frame, capture: rect)
        }
        guard matching.count == 1, let id = matching.first?[kCGWindowNumber as String] as? UInt32 else {
            let observed = windowInfo.compactMap { item -> String? in
                guard (item[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                      let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
                let name = item[kCGWindowName as String] as? String ?? "<nil>"
                let layer = item[kCGWindowLayer as String] as? Int ?? -1
                return "\(name) layer=\(layer) frame=\(NSStringFromRect(rect))"
            }.joined(separator: " | ")
            throw AssistantError.unsafe("无法匹配当前可见接待窗口编号：AX=\(windowDescriptions[selectedIndex].title) \(NSStringFromRect(frame))；CG=\(observed)")
        }
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
        // Only control labels, row-container identity fields, header-aligned text,
        // and the exact left-list `[图片]` marker are exposed. Arbitrary preview
        // text, chat body and editable fields are never read into control state.
        var controls: [Int: AXNode] = [:]
        for node in raw where ["AXButton", "AXMenuButton", "AXCheckBox", "AXRadioButton"].contains(node.role) {
            let element = elements[node.id]!
            controls[node.id] = AXNode(id: node.id, parent: node.parent, role: node.role, title: string(element, kAXTitleAttribute), description: string(element, kAXDescriptionAttribute), frame: node.frame)
        }
        let headerY = controls.values.first { $0.labels.contains("转发当前用户") }?.frame.midY
        let rawByID = Dictionary(raw.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rowCandidates = raw.filter {
            ["AXGroup", "AXRow"].contains($0.role) && $0.frame.width >= 100 && $0.frame.width < frame.width * 0.4
                && $0.frame.minX < frame.minX + frame.width * 0.28 && $0.frame.height >= 30 && $0.frame.height <= 100
        }
        func containingRow(for node: (id: Int, parent: Int?, role: String, frame: CGRect)) -> (id: Int, parent: Int?, role: String, frame: CGRect)? {
            var parent = node.parent
            for _ in 0..<20 {
                guard let id = parent, let ancestor = rawByID[id] else { return nil }
                if rowCandidates.contains(where: { $0.id == id }) { return ancestor }
                parent = ancestor.parent
            }
            return nil
        }
        var nodes: [AXNode] = []
        for node in raw {
            if let control = controls[node.id] { nodes.append(control); continue }
            let isRow = ["AXGroup", "AXRow"].contains(node.role) && node.frame.width >= 100 && node.frame.width < frame.width * 0.4 && node.frame.minX < frame.minX + frame.width * 0.28 && node.frame.height >= 30 && node.frame.height <= 100
            let isHeader = node.role == "AXStaticText" && headerY.map { abs(node.frame.midY - $0) < 15 } == true
            let element = elements[node.id]!
            let isLeftStaticText = node.role == "AXStaticText" && node.frame.maxX < frame.minX + frame.width * 0.4
            let rowForText = isLeftStaticText ? containingRow(for: node) : nil
            let isRowNickname = rowForText.map { node.frame.midY <= $0.frame.midY + 2 } ?? false
            let rawTitle = isRow || isHeader || isLeftStaticText ? string(element, kAXTitleAttribute) : ""
            let rawValue = isHeader || isLeftStaticText ? string(element, kAXValueAttribute) : ""
            let rawDescription = isRow || isHeader || isLeftStaticText ? string(element, kAXDescriptionAttribute) : ""
            let exactImageMarker = isLeftStaticText && [rawTitle, rawValue, rawDescription].contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[图片]"
            }
            nodes.append(AXNode(id: node.id, parent: node.parent, role: node.role,
                                title: isRow || isHeader || isRowNickname ? rawTitle : "",
                                value: isHeader || isRowNickname ? rawValue : (exactImageMarker ? "[图片]" : ""),
                                description: isRow || isHeader || isRowNickname ? rawDescription : "", frame: node.frame))
        }
        guard Date() < deadline else { throw AssistantError.unsafe("辅助功能读取超时；未点击。") }
        windowElement = window
        return (nodes, frame, id)
    }
    private func selectedWindowIndex(
        in windows: [ReceptionWindowDescriptor],
        focusedIndex: Int?
    ) -> Int? {
        guard let policy = windowPolicy else {
            return ReceptionWindowSelection.index(in: windows, focusedIndex: focusedIndex)
        }
        let eligible = windows.indices.filter { index in
            let candidate = windows[index]
            return !candidate.minimized
                && candidate.frame.width >= policy.minimumRelativeSize.width
                && candidate.frame.height >= policy.minimumRelativeSize.height
                && policy.requiredTitleTokens.allSatisfy { candidate.title.contains($0) }
        }
        if let focusedIndex, eligible.contains(focusedIndex) { return focusedIndex }
        return eligible.count == 1 ? eligible[0] : nil
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
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QianniuAutoReplyScheduler", isDirectory: true)
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
