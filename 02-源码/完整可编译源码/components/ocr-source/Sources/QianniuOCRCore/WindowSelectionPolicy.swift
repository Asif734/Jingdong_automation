import CoreGraphics
import Foundation

public struct CoordinateMapping: Codable, Equatable, Sendable {
    public let pointsToPixelsX: Double
    public let pointsToPixelsY: Double
    public let originOffsetX: Double
    public let originOffsetY: Double
    public let maximumResidual: Double

    public init(
        pointsToPixelsX: Double,
        pointsToPixelsY: Double,
        originOffsetX: Double,
        originOffsetY: Double,
        maximumResidual: Double
    ) {
        self.pointsToPixelsX = pointsToPixelsX
        self.pointsToPixelsY = pointsToPixelsY
        self.originOffsetX = originOffsetX
        self.originOffsetY = originOffsetY
        self.maximumResidual = maximumResidual
    }

    public func matches(accessibility: CGRect, capture: CGRect) -> Bool {
        let expected = CGRect(
            x: accessibility.minX * pointsToPixelsX + originOffsetX,
            y: accessibility.minY * pointsToPixelsY + originOffsetY,
            width: accessibility.width * pointsToPixelsX,
            height: accessibility.height * pointsToPixelsY
        )
        return [
            abs(expected.minX - capture.minX),
            abs(expected.minY - capture.minY),
            abs(expected.width - capture.width),
            abs(expected.height - capture.height),
        ].allSatisfy { $0 <= maximumResidual }
    }
}

public struct WindowSelectionPolicy: Codable, Equatable, Sendable {
    public let selectedWindowRole: String
    public let requiredTitleTokens: [String]
    public let minimumRelativeSize: CGSize
    public let requiredRegions: Set<String>
    public let coordinateMapping: CoordinateMapping

    public init(
        selectedWindowRole: String,
        requiredTitleTokens: [String],
        minimumRelativeSize: CGSize,
        requiredRegions: Set<String>,
        coordinateMapping: CoordinateMapping
    ) {
        self.selectedWindowRole = selectedWindowRole
        self.requiredTitleTokens = requiredTitleTokens
        self.minimumRelativeSize = minimumRelativeSize
        self.requiredRegions = requiredRegions
        self.coordinateMapping = coordinateMapping
    }
}
