import CoreGraphics
import Foundation

public enum SendEvidenceAssessment: Equatable, Sendable {
    case confirmedCorrect
    case confirmedWrong(String)
    case unknown(String)
}

public struct SenderVisibleWindow: Equatable, Sendable {
    public let ownerPID: Int32
    public let title: String
    public let frame: CGRect

    public init(ownerPID: Int32, title: String, frame: CGRect = .zero) {
        self.ownerPID = ownerPID
        self.title = title
        self.frame = frame
    }
}

public enum QianniuSendTrigger: String, Codable, Equatable, Sendable {
    case accessibilityPress
    case returnKeyOnce
}

public enum QianniuElementSelection {
    public static func repeatWarningWindow(
        windows: [SenderVisibleWindow],
        qianniuPID: Int32
    ) -> SenderVisibleWindow? {
        let matches = windows.filter {
            $0.ownerPID == qianniuPID && $0.title.contains("服务态度提醒")
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func continueSendPointForRepeatWarning(window: SenderVisibleWindow) -> CGPoint? {
        guard window.title.contains("服务态度提醒"),
              window.frame.width >= 300, window.frame.width <= 650,
              window.frame.height >= 150, window.frame.height <= 400 else { return nil }
        return CGPoint(
            x: window.frame.minX + window.frame.width * 0.82,
            y: window.frame.minY + window.frame.height * 0.82
        )
    }

    public static func hasBlockingRepeatMessageWarning(nodes: [SenderAXNode]) -> Bool {
        let labels = nodes.flatMap(\.labels)
        let hasWarningText = labels.contains {
            $0.contains("已向该消费者发送重复消息") && $0.contains("继续发送可能引起消费者反感或差评")
        }
        let hasReturnButton = nodes.contains { $0.role == "AXButton" && $0.labels.contains("返回修改") }
        let hasContinueButton = nodes.contains { $0.role == "AXButton" && $0.labels.contains("继续发送") }
        return hasWarningText && hasReturnButton && hasContinueButton
    }

    public static func continueSendButtonForRepeatWarning(nodes: [SenderAXNode]) -> SenderAXNode? {
        guard hasBlockingRepeatMessageWarning(nodes: nodes) else { return nil }
        let matches = nodes.filter {
            $0.isEnabled && $0.role == "AXButton" && $0.labels.contains("继续发送")
        }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func repeatWarningWindowIndex(windowNodes: [[SenderAXNode]]) -> Int? {
        let matches = windowNodes.indices.filter { hasBlockingRepeatMessageWarning(nodes: windowNodes[$0]) }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func searchResult(uid: String, nodes: [SenderAXNode], window: CGRect) -> SenderAXNode? {
        let exact = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exact.isEmpty else { return nil }
        return rankedUnique(nodes.compactMap { node -> (SenderAXNode, Int)? in
            guard node.isEnabled,
                  !["AXTextField", "AXTextArea", "AXComboBox"].contains(node.role),
                  node.labels.contains(where: { exactOrTruncatedPrefixMatches(exact, $0) }),
                  window.contains(node.frame.center) else { return nil }
            let relativeX = (node.frame.midX - window.minX) / max(window.width, 1)
            let relativeY = (node.frame.midY - window.minY) / max(window.height, 1)
            guard relativeX < 0.34, relativeY > 0.12 else { return nil }
            var score = 100
            if node.role == "AXGroup" { score += 50 }
            if node.role == "AXStaticText" { score += 20 }
            if node.frame.height >= 35 { score += 10 }
            return (node, score)
        })
    }

    public static func interactionPoint(for node: SenderAXNode, inside window: CGRect) -> CGPoint? {
        guard node.isEnabled,
              !["AXButton", "AXMenuButton"].contains(node.role),
              window.contains(node.frame.center) else { return nil }
        return node.frame.center
    }

    public static func searchField(nodes: [SenderAXNode], window: CGRect) -> SenderAXNode? {
        rankedUnique(nodes.compactMap { node -> (SenderAXNode, Int)? in
            guard node.isEnabled, ["AXTextField", "AXTextArea", "AXComboBox"].contains(node.role),
                  window.contains(node.frame.center) else { return nil }
            let text = node.labels.joined(separator: " ")
            guard text.contains("联系人") || text.contains("订单号") || text.contains("聊天记录") else { return nil }
            let x = (node.frame.midX - window.minX) / max(window.width, 1)
            let y = (node.frame.midY - window.minY) / max(window.height, 1)
            var score = 100
            if x < 0.32 { score += 30 }
            if y < 0.35 { score += 20 }
            if text.contains("联系人、订单号、聊天记录") { score += 40 }
            return (node, score)
        })
    }

    public static func chatHeader(uid: String, nodes: [SenderAXNode], chatRegion: CGRect) -> SenderAXNode? {
        let exact = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !exact.isEmpty else { return nil }
        return rankedUnique(nodes.compactMap { node -> (SenderAXNode, Int)? in
            guard node.isEnabled, node.labels.contains(exact), chatRegion.intersects(node.frame) else { return nil }
            let relativeY = (node.frame.midY - chatRegion.minY) / max(chatRegion.height, 1)
            guard relativeY >= 0, relativeY <= 0.18 else { return nil }
            var score = 100
            if node.role == "AXStaticText" { score += 20 }
            score += max(0, Int((0.18 - relativeY) * 100))
            return (node, score)
        })
    }

    public static func chatHeaderMatches(uid: String, nodes: [SenderAXNode], chatRegion: CGRect) -> Bool {
        let expected = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return false }
        if chatHeader(uid: expected, nodes: nodes, chatRegion: chatRegion) != nil { return true }
        let matches = nodes.filter { node in
            guard node.isEnabled, node.role == "AXStaticText", chatRegion.intersects(node.frame) else { return false }
            let relativeY = (node.frame.midY - chatRegion.minY) / max(chatRegion.height, 1)
            guard relativeY >= 0, relativeY <= 0.18 else { return false }
            return node.labels.contains { exactOrTruncatedPrefixMatches(expected, $0) }
        }
        return matches.count == 1
    }

    public static func chatIdentityMatches(
        uid: String,
        nickname: String? = nil,
        nodes: [SenderAXNode],
        window: CGRect,
        chatRegion: CGRect
    ) -> Bool {
        let expected = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return false }
        if chatHeader(uid: expected, nodes: nodes, chatRegion: chatRegion) != nil { return true }
        let searchHasExactUID = searchField(nodes: nodes, window: window)?
            .value?.trimmingCharacters(in: .whitespacesAndNewlines) == expected
        guard searchHasExactUID else { return false }
        if chatHeaderMatches(uid: expected, nodes: nodes, chatRegion: chatRegion) { return true }
        guard let nickname else { return false }
        let matches = nodes.filter { node in
            guard node.isEnabled, node.role == "AXStaticText", chatRegion.intersects(node.frame) else { return false }
            let relativeY = (node.frame.midY - chatRegion.minY) / max(chatRegion.height, 1)
            guard relativeY >= 0, relativeY <= 0.18 else { return false }
            return node.labels.contains { nicknameMatches(expected: nickname, actual: $0) }
        }
        return matches.count == 1
    }

    public static func routedConversationMatches(
        uid: String,
        nodes: [SenderAXNode],
        window: CGRect,
        chatRegion: CGRect
    ) -> Bool {
        routedConversationAssessment(uid: uid, nodes: nodes, window: window, chatRegion: chatRegion)
            == .confirmedCorrect
    }

    public static func routedConversationAssessment(
        uid: String,
        nodes: [SenderAXNode],
        window: CGRect,
        chatRegion: CGRect
    ) -> SendEvidenceAssessment {
        let expected = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return .confirmedWrong("目标客户身份为空") }
        if chatHeaderMatches(uid: expected, nodes: nodes, chatRegion: chatRegion) {
            return .confirmedCorrect
        }
        guard messageInput(nodes: nodes, chatRegion: chatRegion) != nil else {
            return .unknown("消息输入框不可用")
        }
        guard let rawSearch = searchField(nodes: nodes, window: window)?.value else {
            return .unknown("当前会话身份不可读")
        }
        let search = rawSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return .unknown("当前会话身份不可读") }
        return search == expected
            ? .confirmedCorrect
            : .confirmedWrong("联系人搜索框显示了其他客户")
    }

    public static func nicknameMatches(expected: String, actual: String, threshold: Double = 0.80) -> Bool {
        let lhs = normalizedNickname(expected), rhs = normalizedNickname(actual)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let denominator = max(lhs.count, rhs.count)
        return 1 - Double(editDistance(Array(lhs), Array(rhs))) / Double(denominator) >= threshold
    }

    private static func exactOrTruncatedPrefixMatches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedNickname(lhs), right = normalizedNickname(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        if let prefix = truncatedPrefix(lhs).map(normalizedNickname), usablePrefix(prefix), right.hasPrefix(prefix) { return true }
        if let prefix = truncatedPrefix(rhs).map(normalizedNickname), usablePrefix(prefix), left.hasPrefix(prefix) { return true }
        return false
    }

    private static func usablePrefix(_ prefix: String) -> Bool {
        let hanCount = prefix.unicodeScalars.filter {
            (0x3400...0x9FFF).contains(Int($0.value)) || (0xF900...0xFAFF).contains(Int($0.value))
        }.count
        return hanCount > 0 ? prefix.count >= 2 : prefix.count >= 4
    }

    private static func truncatedPrefix(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("...") { return String(value.dropLast(3)) }
        if value.hasSuffix("…") { return String(value.dropLast()) }
        return nil
    }

    private static func normalizedNickname(_ text: String) -> String {
        let mapped = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(mapped.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (0x3400...0x9FFF).contains(Int(scalar.value))
                || (0xF900...0xFAFF).contains(Int(scalar.value))
        })
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = Swift.min(Swift.min(current[j] + 1, previous[j + 1] + 1), previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    public static func messageInput(nodes: [SenderAXNode], chatRegion: CGRect) -> SenderAXNode? {
        rankedUnique(nodes.compactMap { node -> (SenderAXNode, Int)? in
            guard node.isEnabled, ["AXTextArea", "AXTextField"].contains(node.role),
                  chatRegion.intersects(node.frame) else { return nil }
            let relativeY = (node.frame.midY - chatRegion.minY) / max(chatRegion.height, 1)
            guard relativeY >= 0.62 else { return nil }
            let overlap = node.frame.intersection(chatRegion)
            guard !overlap.isNull, overlap.width >= chatRegion.width * 0.35 else { return nil }
            var score = 100
            if node.role == "AXTextArea" { score += 30 }
            if node.frame.height >= 70 { score += 20 }
            score += Int(min(30, overlap.width / max(chatRegion.width, 1) * 30))
            return (node, score)
        })
    }

    public static func messageInput(
        nodes: [SenderAXNode],
        chatRegion: CGRect,
        policy: ComposerSelectionPolicy
    ) -> SenderAXNode? {
        let allowedRegion = policy.absoluteRegion(in: chatRegion)
        let permitted = nodes.filter {
            policy.acceptedRoles.contains($0.role) && allowedRegion.contains($0.frame.center)
        }
        return messageInput(nodes: permitted, chatRegion: chatRegion)
    }

    public static func sendButton(nodes: [SenderAXNode], input: SenderAXNode) -> SenderAXNode? {
        rankedUnique(nodes.compactMap { node -> (SenderAXNode, Int)? in
            guard node.isEnabled, ["AXButton", "AXMenuButton"].contains(node.role), node.labels.contains("发送") else { return nil }
            let nearX = node.frame.midX >= input.frame.minX && node.frame.midX <= input.frame.maxX + 160
            let nearY = node.frame.midY >= input.frame.minY && node.frame.midY <= input.frame.maxY + 100
            guard nearX, nearY else { return nil }
            var score = 100
            score += max(0, 50 - Int(abs(node.frame.maxX - input.frame.maxX)))
            score += max(0, 50 - Int(abs(node.frame.midY - input.frame.maxY)))
            return (node, score)
        })
    }

    public static func sendTrigger(for button: SenderAXNode) -> QianniuSendTrigger? {
        guard button.isEnabled, button.labels.contains("发送") else { return nil }
        switch button.role {
        case "AXButton": return .accessibilityPress
        case "AXMenuButton": return .returnKeyOnce
        default: return nil
        }
    }

    public static func sendTrigger(
        for button: SenderAXNode,
        policy: ComposerSelectionPolicy
    ) -> QianniuSendTrigger? {
        guard button.isEnabled, button.labels.contains("发送") else { return nil }
        let assumedActions = button.role == "AXButton" ? ["AXPress"] : []
        return ComposerSelectionPolicy.resolveSendTrigger(
            role: button.role,
            actions: assumedActions
        )
    }

    private static func rankedUnique(_ values: [(SenderAXNode, Int)]) -> SenderAXNode? {
        let sorted = values.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.id < $1.0.id
        }
        guard let first = sorted.first else { return nil }
        if sorted.count > 1, sorted[1].1 == first.1 { return nil }
        return first.0
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
