import CoreGraphics
import Foundation

public enum AXCustomerIdentity {
    public static func candidates(
        nodes: [AXNodeCandidate],
        chatFrame: CGRect
    ) -> CustomerIdentityCandidates {
        let headerBand = nodes
            .filter { item in
                let frame = item.candidate.frame
                return Set(["AXStaticText", "AXTextField"]).contains(item.candidate.role)
                    && textValue(item) != nil
                    && frame.midX >= chatFrame.minX
                    && frame.midX <= chatFrame.maxX
                    && frame.midY >= chatFrame.minY - max(120, chatFrame.height * 0.2)
                    && frame.midY <= chatFrame.minY + max(80, chatFrame.height * 0.16)
            }

        // 千牛的会话标题位于消息裁剪区正上方；旧版布局则会把标题包含在
        // 裁剪区顶部。优先使用“正上方”这一结构关系，避免把第一条消息
        // （例如 nihao）误当作 userId。
        let aboveChat = headerBand.filter { $0.candidate.frame.maxY <= chatFrame.minY + 4 }
        let headerAnchor = (aboveChat.isEmpty ? headerBand : aboveChat)
            .min { lhs, rhs in
                if !aboveChat.isEmpty,
                   lhs.candidate.frame.maxY != rhs.candidate.frame.maxY {
                    return lhs.candidate.frame.maxY > rhs.candidate.frame.maxY
                }
                if lhs.candidate.frame.midY != rhs.candidate.frame.midY {
                    return lhs.candidate.frame.midY < rhs.candidate.frame.midY
                }
                return lhs.candidate.frame.minX < rhs.candidate.frame.minX
            }
            .flatMap(textValue)

        let sessionRoles = Set(["AXGroup", "AXRow", "AXCell"])
        let leftSessions = nodes.compactMap { node -> (AXNodeCandidate, String)? in
            guard sessionRoles.contains(node.candidate.role),
                  node.candidate.frame.maxX <= chatFrame.minX,
                  let value = textValue(node),
                  CustomerIdentityExtractor.structuralAXValue(value) != nil else {
                return nil
            }
            return (node, value)
        }

        let selectedSession = leftSessions
            .filter { item in
                item.0.isSelected
            }
            .min { $0.0.candidate.frame.midY < $1.0.candidate.frame.midY }?.1

        let header = headerAnchor.flatMap { anchor in
            resolvedHeader(anchor, leftSessions: leftSessions, selectedSession: selectedSession)
        }
        let matchedSession = header.flatMap { header in
            leftSessions.first { $0.1 == header }?.1
        }

        return CustomerIdentityCandidates(
            axHeader: header,
            axSessionList: selectedSession ?? matchedSession,
            ocr: nil
        )
    }

    private static func textValue(_ node: AXNodeCandidate) -> String? {
        for text in [node.candidate.value, node.candidate.title, node.candidate.description] {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func resolvedHeader(
        _ anchor: String,
        leftSessions: [(AXNodeCandidate, String)],
        selectedSession: String?
    ) -> String? {
        let prefix: String?
        if anchor.hasSuffix("...") {
            prefix = String(anchor.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if anchor.hasSuffix("…") {
            prefix = String(anchor.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            prefix = nil
        }

        guard let prefix else {
            return CustomerIdentityExtractor.structuralAXValue(anchor)
        }
        guard !prefix.isEmpty else { return nil }

        if let selectedSession, selectedSession.hasPrefix(prefix) {
            return selectedSession
        }
        let matches = Array(Set(leftSessions.map(\.1).filter { $0.hasPrefix(prefix) }))
        return matches.count == 1 ? matches[0] : nil
    }
}
