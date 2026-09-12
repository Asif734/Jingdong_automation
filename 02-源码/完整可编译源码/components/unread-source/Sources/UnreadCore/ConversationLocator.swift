import Foundation
import CoreGraphics

private enum ConversationListNodeKind {
    case groupHeader
    case customer
    case unknown
}

public enum ConversationLocator {
    public static func isPotentialNicknameNode(_ node: AXNode, in row: AXNode) -> Bool {
        node.role == "AXStaticText" && row.frame.intersects(node.frame)
            && node.frame.midY <= row.frame.midY + 2
            && node.frame.minX < row.frame.minX + row.frame.width * 0.75
    }
    public static func nicknameCandidate(_ node: AXNode, in row: AXNode) -> String? {
        guard isPotentialNicknameNode(node, in: row),
              let label = displayTitle(node), isNicknameLabel(label) else { return nil }
        return label
    }
    public static func chineseNickname(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isTruncated(value), containsHan(value), !value.contains("\n") else { return nil }
        return value
    }

    public static func customerNickname(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isTruncated(value), isNicknameLabel(value) else { return nil }
        return value
    }

    public static func nicknameMatches(expected: String, actual: String, threshold: Double = 0.80) -> Bool {
        let lhs = normalizedNickname(expected), rhs = normalizedNickname(actual)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let denominator = max(lhs.count, rhs.count)
        return 1 - Double(editDistance(Array(lhs), Array(rhs))) / Double(denominator) >= threshold
    }

    public static func identityMatches(expectedUID: String, expectedNickname: String?, actualHeader: String) -> Bool {
        if verified(expected: expectedUID, actual: actualHeader) { return true }
        guard let expectedNickname else { return false }
        return nicknameMatches(expected: expectedNickname, actual: actualHeader)
    }

    public static func routedIdentity(expectedUID: String, openedUID: String?) -> String? {
        let expected = expectedUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty,
              openedUID?.trimmingCharacters(in: .whitespacesAndNewlines) == expected else { return nil }
        return expected
    }

    public static func requiresProfileIdentity(displayTitle: String) -> Bool {
        isTruncated(displayTitle.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func profileUID(profileTitle: String, receptionTitle: String, displayTitle: String, rows: [ConversationRow]) -> String? {
        guard receptionTitle.hasSuffix("-接待中心") else { return nil }
        let owner = String(receptionTitle.dropLast("接待中心".count))
        guard profileTitle.hasPrefix(owner), profileTitle.hasSuffix("的资料") else { return nil }
        let uid = String(profileTitle.dropFirst(owner.count).dropLast("的资料".count))
        guard !uid.isEmpty, uid.count <= 256, !isTruncated(uid), !uid.contains("\n"),
              fresh(uid: uid, rows: rows) != nil else { return nil }
        let prefix: String
        if displayTitle.hasSuffix("...") { prefix = String(displayTitle.dropLast(3)) }
        else if displayTitle.hasSuffix("…") { prefix = String(displayTitle.dropLast()) }
        else {
            return nil
        }
        // A full UID must come from the freshly opened profile, never from this prefix.
        // Reject ambiguity because closing the profile briefly yields to the UI.
        return !prefix.isEmpty && uid.hasPrefix(prefix) && rows.filter({ $0.uid.hasPrefix(prefix) }).count == 1 ? uid : nil
    }
    public static func candidates(
        nodes: [AXNode],
        window: CGRect,
        preferStructuralUID: Bool = true,
        identityPolicy: ConversationIdentityPolicy = .default
    ) throws -> [ConversationCandidate] {
        let policy = try ConversationListPolicy.calibrate(nodes: nodes, window: window)
        return try candidates(
            nodes: nodes,
            window: window,
            policy: policy,
            preferStructuralUID: preferStructuralUID,
            identityPolicy: identityPolicy
        )
    }

    public static func candidates(
        nodes: [AXNode],
        window: CGRect,
        policy: ConversationListPolicy,
        preferStructuralUID: Bool = true,
        identityPolicy: ConversationIdentityPolicy = .default
    ) throws -> [ConversationCandidate] {
        let anchors = nodes.filter { $0.labels.contains(policy.anchorLabelCategory) && window.contains($0.frame) }
        guard anchors.count == 1, let anchor = anchors.first else {
            throw AssistantError.unsafe("无法确认左侧正在接待列表；请显示正在接待列表后重试。")
        }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func belowAnchorParent(_ node: AXNode) -> Bool {
            var parent = node.parent
            for _ in 0..<40 {
                guard let id = parent else { return false }
                if id == anchor.parent { return true }
                parent = byID[id]?.parent
            }
            return false
        }
        func isDescendant(_ candidate: AXNode, of ancestorID: Int) -> Bool {
            var parent = candidate.parent
            for _ in 0..<40 {
                guard let id = parent else { return false }
                if id == ancestorID { return true }
                parent = byID[id]?.parent
            }
            return false
        }
        func hasExactImagePreview(_ row: AXNode) -> Bool {
            nodes.contains { candidate in
                candidate.id != row.id && isDescendant(candidate, of: row.id)
                    && candidate.labels.contains {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[图片]"
                    }
            }
        }
        func visibleNickname(_ row: AXNode) -> String? {
            let candidates = nodes.compactMap { candidate -> String? in
                guard candidate.id != row.id, isDescendant(candidate, of: row.id),
                      let label = nicknameCandidate(candidate, in: row) else { return nil }
                return label
            }
            let distinct = Set(candidates)
            return distinct.count == 1 ? distinct.first : nil
        }
        let containers = nodes.filter { node in
            ["AXGroup", "AXList", "AXOutline", "AXScrollArea"].contains(node.role)
            && node.frame.width >= 100 && node.frame.width < window.width * 0.4
            && node.frame.minY >= anchor.frame.maxY - 3
            && window.contains(node.frame)
            && node.frame.minX <= anchor.frame.midX && node.frame.maxX >= anchor.frame.midX
            && belowAnchorParent(node)
        }
        let containerIDs = Set(containers.map(\.id))
        // Qianniu exposes either dedicated nickname children for the visible list,
        // or (on some builds) only one label on each row container. Never mix the
        // two modes: explicit nickname children win for the entire snapshot.
        let hasExplicitNicknameChildren = !preferStructuralUID && nodes.contains { row in
            guard let parent = row.parent, containerIDs.contains(parent),
                  ["AXGroup", "AXRow"].contains(row.role) else { return false }
            return visibleNickname(row) != nil
        }
        var result: [ConversationCandidate] = []
        let visibleFullIdentities = nodes.compactMap { node -> String? in
            guard let title = displayTitle(node), !isTruncated(title), isNicknameLabel(title) else { return nil }
            return title
        }
        for container in containers {
            let plausibleRows = nodes.filter { node in
                node.parent == container.id
                    && ["AXGroup", "AXRow"].contains(node.role)
                    && window.contains(node.frame) && container.frame.contains(node.frame)
                    && node.frame.height >= 30 && node.frame.height <= 100
                    && node.frame.width >= container.frame.width * policy.minimumWidthRatio
                    && node.frame.minY >= anchor.frame.maxY - 3
            }
            func hasIdentityEvidence(_ node: AXNode) -> Bool {
                if preferStructuralUID && identity(node) != nil { return true }
                if visibleNickname(node) != nil { return true }
                if !preferStructuralUID && !hasExplicitNicknameChildren,
                   let title = displayTitle(node), isNicknameLabel(title) { return true }
                return preferStructuralUID
                    && displayTitle(node).map { usableTruncatedIdentity($0) } == true
            }
            let referenceHeights = plausibleRows.filter(hasIdentityEvidence).map(\.frame.height).sorted()
            let referenceHeight: CGFloat? = policy.medianCustomerHeight > 0
                ? policy.medianCustomerHeight
                : (referenceHeights.isEmpty ? nil : referenceHeights[referenceHeights.count / 2])
            func kind(of node: AXNode) -> ConversationListNodeKind {
                let labelsAreBlank = node.labels.allSatisfy {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if labelsAreBlank, let referenceHeight,
                   node.frame.height <= referenceHeight * policy.sectionHeaderMaximumHeightRatio {
                    return .groupHeader
                }
                return hasIdentityEvidence(node) ? .customer : .unknown
            }
            for node in plausibleRows {
                guard kind(of: node) != .groupHeader else { continue }
                let structuralUID = preferStructuralUID && identityPolicy.contains(.containerTitle) ? identity(node) : nil
                let rowLabelNickname = preferStructuralUID || hasExplicitNicknameChildren ? nil : displayTitle(node).flatMap {
                    isNicknameLabel($0) ? $0 : nil
                }
                let childNickname = identityPolicy.contains(.childNickname) ? visibleNickname(node) : nil
                let nickname = childNickname
                    ?? rowLabelNickname
                    ?? structuralUID.flatMap { containsHan($0) ? $0 : nil }
                let truncatedRoute = preferStructuralUID && identityPolicy.contains(.uniquePrefix)
                    ? displayTitle(node).flatMap {
                        usableTruncatedIdentity($0)
                            ? identityPolicy.resolvePrefix($0, visibleIdentities: visibleFullIdentities)
                            : nil
                    }
                    : nil
                let evidence: ConversationIdentityEvidence
                if let structuralUID {
                    evidence = .full(uid: structuralUID, nickname: nickname, source: .containerTitle)
                } else if let nickname {
                    evidence = .full(
                        uid: nickname,
                        nickname: nickname,
                        source: childNickname == nil ? .containerTitle : .childNickname
                    )
                } else if let truncatedRoute {
                    let original = displayTitle(node) ?? truncatedRoute
                    if truncatedRoute != original {
                        evidence = .full(uid: truncatedRoute, nickname: nil, source: .uniquePrefix)
                    } else {
                        evidence = .uniquePrefix(truncatedRoute)
                    }
                } else {
                    let labels = Array(Set(node.labels.map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty })).sorted()
                    evidence = .unresolved(labels: labels)
                }
                result.append(ConversationCandidate(nodeID: node.id, frame: node.frame, identity: evidence,
                                                    latestPreviewIsImage: hasExactImagePreview(node)))
            }
        }
        let counts = Dictionary(grouping: result.compactMap { $0.identity.resolved }, by: { $0 })
        let duplicates = Set(counts.compactMap { $0.value.count > 1 ? $0.key : nil })
        if !duplicates.isEmpty {
            result = result.map { candidate in
                guard let identity = candidate.identity.resolved, duplicates.contains(identity) else { return candidate }
                return ConversationCandidate(
                    nodeID: candidate.nodeID,
                    frame: candidate.frame,
                    identity: .unresolved(labels: Array(Set(candidate.identity.diagnosticLabels)).sorted()),
                    latestPreviewIsImage: candidate.latestPreviewIsImage
                )
            }
        }
        return result.sorted { $0.frame.minY < $1.frame.minY }
    }

    public static func rows(
        nodes: [AXNode],
        window: CGRect,
        preferStructuralUID: Bool = true,
        identityPolicy: ConversationIdentityPolicy = .default
    ) throws -> [ConversationRow] {
        let result = try candidates(
            nodes: nodes,
            window: window,
            preferStructuralUID: preferStructuralUID,
            identityPolicy: identityPolicy
        )
            .compactMap(\.row)
        guard !result.isEmpty else {
            throw AssistantError.unsafe("未找到可可靠识别的可见会话行（不是无未读结论）。")
        }
        return result
    }
    public static func fresh(uid: String, rows: [ConversationRow]) -> ConversationRow? {
        let matches = rows.filter { $0.uid == uid }
        return matches.count == 1 ? matches[0] : nil
    }
    public static func verified(expected: String, actual: String?) -> Bool {
        guard let actual else { return false }
        return exactOrTruncatedPrefixMatches(expected, actual)
    }
    public static func header(nodes: [AXNode], window: CGRect) -> String? {
        guard let title = displayHeaderNode(nodes: nodes, window: window).flatMap(displayTitle) else { return nil }
        return identityText(title) != nil || usableTruncatedIdentity(title) ? title : nil
    }
    public static func displayHeaderNode(nodes: [AXNode], window: CGRect) -> AXNode? {
        let controls = nodes.filter { $0.labels.contains("转发当前用户") && window.contains($0.frame) }
        guard controls.count == 1, let control = controls.first,
              nodes.contains(where: { $0.labels.contains("新建任务") && abs($0.frame.midY - control.frame.midY) < 20 }) else { return nil }
        let candidates = nodes.filter {
            $0.role == "AXStaticText" && $0.frame.width > 20 && $0.frame.height > 8
            && $0.frame.maxX < control.frame.minX && $0.frame.minX > window.minX + window.width * 0.18
            && abs($0.frame.midY - control.frame.midY) < max(12, control.frame.height * 0.5)
            && $0.frame.minY < window.minY + window.height * 0.3
            && displayTitle($0) != nil
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
    private static func isTruncated(_ text: String) -> Bool { truncatedPrefix(text) != nil }
    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) || (0xF900...0xFAFF).contains(Int($0.value)) }
    }
    private static func isNicknameLabel(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256, !value.contains("\n") else { return false }
        let rejected = ["[图片]", "已读", "未读", "对方输入中", "对方输入中...", "正在输入", "转人工"]
        guard !rejected.contains(value) else { return false }
        return (!isTruncated(value) || usableTruncatedIdentity(value))
            && value.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) == nil
            && value.range(of: #"^\d+\s*(秒|分|分钟|小时|天)$"#, options: .regularExpression) == nil
    }

    private static func exactOrTruncatedPrefixMatches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedNickname(lhs), right = normalizedNickname(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        if let prefix = truncatedPrefix(lhs).map(normalizedNickname), usablePrefix(prefix), right.hasPrefix(prefix) { return true }
        if let prefix = truncatedPrefix(rhs).map(normalizedNickname), usablePrefix(prefix), left.hasPrefix(prefix) { return true }
        return false
    }
    private static func usableTruncatedIdentity(_ text: String) -> Bool {
        guard let prefix = truncatedPrefix(text).map(normalizedNickname) else { return false }
        return usablePrefix(prefix)
    }
    private static func usablePrefix(_ prefix: String) -> Bool {
        let hanCount = prefix.unicodeScalars.filter { (0x3400...0x9FFF).contains(Int($0.value)) || (0xF900...0xFAFF).contains(Int($0.value)) }.count
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
        return String(mapped.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || containsHan(String($0)) })
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
    public static func displayTitle(_ node: AXNode) -> String? {
        let labels = Set(node.labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !["group", "text", "容器", "文本"].contains($0) })
        guard labels.count == 1, let uid = labels.first, !uid.isEmpty,
              !uid.contains("\n"), uid.count <= 256 else { return nil }
        return uid
    }
    private static func identity(_ node: AXNode) -> String? {
        displayTitle(node).flatMap(identityText)
    }
    private static func identityText(_ value: String) -> String? {
        guard !isTruncated(value) else { return nil }
        return value
    }
}
