import CoreGraphics
import Foundation

public enum MainChatSelection {
    public static func cropFrame(
        from nodes: [AXNodeCandidate],
        inside window: CGRect
    ) -> CGRect? {
        var byID: [Int: AXNodeCandidate] = [:]
        for node in nodes {
            guard byID.updateValue(node, forKey: node.id) == nil else { return nil }
        }
        let composers = nodes.filter {
            $0.candidate.role == "AXTextArea" && window.contains($0.candidate.frame)
        }
        guard let composer = composers.max(by: {
            $0.candidate.frame.width * $0.candidate.frame.height
                < $1.candidate.frame.width * $1.candidate.frame.height
        }) else { return nil }

        let stableLabels = ["转发当前用户", "新建任务", "更多"]
        let headers = nodes.filter { node in
            let text = [node.candidate.title, node.candidate.description, node.candidate.value]
                .compactMap { $0 }
                .joined(separator: " ")
            return stableLabels.contains { text.contains($0) }
        }
        let composerAncestors = Set(ancestorIDs(of: composer.id, byID: byID))
        let containerRoles = Set(["AXGroup", "AXSplitGroup", "AXScrollArea", "AXWebArea"])

        let containers = nodes.filter { node in
            let frame = node.candidate.frame
            let visible = frame.intersection(window)
            let containedHeaderLabels = Set(headers.flatMap { header -> [String] in
                guard ancestorIDs(of: header.id, byID: byID).contains(node.id) else { return [] }
                let text = [header.candidate.title, header.candidate.description, header.candidate.value]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return stableLabels.filter { text.contains($0) }
            })
            return composerAncestors.contains(node.id)
                && containerRoles.contains(node.candidate.role)
                && node.candidate.role != "AXWindow"
                && frame != window
                && !visible.isNull
                && visible.width > 0
                && visible.height > 0
                && frame.minY < composer.candidate.frame.minY
                && frame.minX <= composer.candidate.frame.midX
                && frame.maxX >= composer.candidate.frame.midX
                && containedHeaderLabels.count >= 2
        }

        if let container = containers.min(by: {
            $0.candidate.frame.width * $0.candidate.frame.height
                < $1.candidate.frame.width * $1.candidate.frame.height
        }) {
            let visible = container.candidate.frame.intersection(window)
            let crop = CGRect(
                x: visible.minX,
                y: visible.minY,
                width: visible.width,
                height: composer.candidate.frame.minY - visible.minY
            )
            return crop.width > 0 && crop.height > 0 ? crop : nil
        }

        let shells = nodes.filter { node in
            let frame = node.candidate.frame
            let visible = frame.intersection(window)
            let headerLabels = Set(headers.flatMap { header -> [String] in
                guard header.candidate.frame.maxY <= composer.candidate.frame.minY,
                      frame.minX <= header.candidate.frame.midX,
                      frame.maxX >= header.candidate.frame.midX else {
                    return []
                }
                let text = [header.candidate.title, header.candidate.description, header.candidate.value]
                    .compactMap { $0 }
                    .joined(separator: " ")
                return stableLabels.filter { text.contains($0) }
            })
            return composerAncestors.contains(node.id)
                && containerRoles.contains(node.candidate.role)
                && node.candidate.role != "AXWindow"
                && frame != window
                && !visible.isNull
                && visible.width > 0
                && visible.height > 0
                && headerLabels.count >= 2
        }

        guard let shell = shells.min(by: {
            $0.candidate.frame.width * $0.candidate.frame.height
                < $1.candidate.frame.width * $1.candidate.frame.height
        }) else { return nil }
        let shellVisible = shell.candidate.frame.intersection(window)

        let conversations = nodes.filter { node in
            let frame = node.candidate.frame
            let visible = frame.intersection(window)
            return containerRoles.contains(node.candidate.role)
                && node.id != shell.id
                && ancestorIDs(of: node.id, byID: byID).contains(shell.id)
                && visible.minY == shellVisible.minY
                && frame.maxY <= composer.candidate.frame.minY
                && frame.minX <= composer.candidate.frame.minX
                && frame.maxX >= composer.candidate.frame.maxX
                && !visible.isNull
                && visible.width > 0
                && visible.height > 0
        }

        guard let conversation = conversations.max(by: {
            $0.candidate.frame.width * $0.candidate.frame.height
                < $1.candidate.frame.width * $1.candidate.frame.height
        }) else { return nil }
        let visible = conversation.candidate.frame.intersection(window)
        return visible.width > 0 && visible.height > 0 ? visible : nil
    }

    private static func ancestorIDs(
        of id: Int,
        byID: [Int: AXNodeCandidate]
    ) -> [Int] {
        var result: [Int] = []
        var current: Int? = id
        var visited = Set<Int>()
        while let id = current, let node = byID[id], visited.insert(id).inserted {
            result.append(id)
            current = node.parentID
        }
        return result
    }
}
