import Foundation
import UnreadCore

enum TransferMenuSelection {
    static func select(
        nodes: [AXNode],
        window: CGRect,
        actionNamesByNodeID: [Int: [String]]
    ) -> Int? {
        guard ConversationLocator.displayHeaderNode(nodes: nodes, window: window) != nil else {
            return nil
        }
        let matches = nodes.filter { node in
            node.role == "AXButton"
                && node.labels.contains("转发当前用户")
                && window.contains(node.frame)
                && (actionNamesByNodeID[node.id] ?? []).contains("AXPress")
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }
}
