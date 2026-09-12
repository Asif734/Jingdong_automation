import CoreGraphics
import Foundation

public struct ConversationListPolicy: Codable, Equatable, Sendable {
    public let medianCustomerHeight: CGFloat
    public let medianRowSpacing: CGFloat
    public let minimumWidthRatio: CGFloat
    public let sectionHeaderMaximumHeightRatio: CGFloat
    public let anchorLabelCategory: String

    public init(
        medianCustomerHeight: CGFloat,
        medianRowSpacing: CGFloat,
        minimumWidthRatio: CGFloat,
        sectionHeaderMaximumHeightRatio: CGFloat,
        anchorLabelCategory: String
    ) {
        self.medianCustomerHeight = medianCustomerHeight
        self.medianRowSpacing = medianRowSpacing
        self.minimumWidthRatio = minimumWidthRatio
        self.sectionHeaderMaximumHeightRatio = sectionHeaderMaximumHeightRatio
        self.anchorLabelCategory = anchorLabelCategory
    }

    public static let legacy = ConversationListPolicy(
        medianCustomerHeight: 0,
        medianRowSpacing: 0,
        minimumWidthRatio: 0.75,
        sectionHeaderMaximumHeightRatio: 0.80,
        anchorLabelCategory: "正在接待买家列表"
    )

    public static func calibrate(
        nodes: [AXNode],
        window: CGRect
    ) throws -> ConversationListPolicy {
        let anchors = nodes.filter {
            $0.labels.contains(legacy.anchorLabelCategory) && window.contains($0.frame)
        }
        guard anchors.count == 1, let anchor = anchors.first else {
            throw AssistantError.unsafe("无法确认左侧正在接待列表；请显示正在接待列表后重试。")
        }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
        let containers = nodes.filter { node in
            ["AXGroup", "AXList", "AXOutline", "AXScrollArea"].contains(node.role)
                && node.frame.width.isFinite && node.frame.height.isFinite
                && node.frame.width >= 100 && node.frame.width < window.width * 0.4
                && node.frame.minY >= anchor.frame.maxY - 3
                && window.contains(node.frame)
                && node.frame.minX <= anchor.frame.midX && node.frame.maxX >= anchor.frame.midX
                && belowAnchorParent(node)
        }
        let containerIDs = Set(containers.map(\.id))
        let plausibleRows = nodes.filter { node in
            guard let parent = node.parent, containerIDs.contains(parent),
                  ["AXGroup", "AXRow"].contains(node.role),
                  node.frame.minX.isFinite, node.frame.minY.isFinite,
                  node.frame.width.isFinite, node.frame.height.isFinite,
                  node.frame.width > 0, node.frame.height >= 30, node.frame.height <= 100,
                  window.contains(node.frame), let container = byID[parent],
                  container.frame.contains(node.frame),
                  node.frame.width >= container.frame.width * 0.5 else { return false }
            return true
        }
        func hasIdentityEvidence(_ row: AXNode) -> Bool {
            if let title = ConversationLocator.displayTitle(row),
               ConversationLocator.customerNickname(from: title) != nil { return true }
            return nodes.contains { child in
                guard child.id != row.id, isDescendant(child, of: row.id),
                      child.role == "AXStaticText",
                      let title = ConversationLocator.displayTitle(child) else { return false }
                return ConversationLocator.customerNickname(from: title) != nil
            }
        }
        let identityRows = plausibleRows.filter(hasIdentityEvidence).sorted { $0.frame.minY < $1.frame.minY }
        let heights = identityRows.map(\.frame.height).sorted()
        let medianHeight = median(heights)
        let spacings = zip(identityRows, identityRows.dropFirst()).map {
            max(0, $1.frame.minY - $0.frame.maxY)
        }.sorted()
        let widthRatios = identityRows.compactMap { row -> CGFloat? in
            guard let parent = row.parent, let container = byID[parent], container.frame.width > 0 else { return nil }
            return row.frame.width / container.frame.width
        }
        let blankRatios = plausibleRows.compactMap { row -> CGFloat? in
            guard medianHeight > 0,
                  row.labels.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return nil
            }
            return row.frame.height / medianHeight
        }
        let learnedHeaderRatio = min(0.90, max(0.80, (blankRatios.max() ?? 0.75) + 0.05))

        return ConversationListPolicy(
            medianCustomerHeight: medianHeight,
            medianRowSpacing: median(spacings),
            minimumWidthRatio: min(0.90, max(0.60, widthRatios.min() ?? legacy.minimumWidthRatio)),
            sectionHeaderMaximumHeightRatio: learnedHeaderRatio,
            anchorLabelCategory: legacy.anchorLabelCategory
        )
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}
