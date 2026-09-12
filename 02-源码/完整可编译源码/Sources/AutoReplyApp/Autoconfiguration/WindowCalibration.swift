import CoreGraphics
import Foundation
import QianniuOCRCore

enum WindowCalibrationError: Error, Equatable {
    case noQualifiedReceptionWindow
    case invalidCoordinatePair
}

enum WindowCalibration {
    private static let expectedRegions: Set<String> = ["conversation-list", "chat", "composer"]

    static func calibrate(snapshot: CalibrationSnapshot) throws -> WindowSelectionPolicy {
        let candidates = snapshot.windows.filter { window in
            guard !window.minimized,
                  window.relativeFrame.width > 0,
                  window.relativeFrame.height > 0,
                  window.captureFrame.width > 0,
                  window.captureFrame.height > 0 else { return false }
            return independentSignalCount(for: window) >= 2
        }
        guard let selected = candidates.max(by: { score($0) < score($1) }) else {
            throw WindowCalibrationError.noQualifiedReceptionWindow
        }

        let scaleX = selected.captureFrame.width / selected.relativeFrame.width
        let scaleY = selected.captureFrame.height / selected.relativeFrame.height
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else {
            throw WindowCalibrationError.invalidCoordinatePair
        }
        let offsetX = selected.captureFrame.minX - selected.relativeFrame.minX * scaleX
        let offsetY = selected.captureFrame.minY - selected.relativeFrame.minY * scaleY
        let mapped = CGRect(
            x: selected.relativeFrame.minX * scaleX + offsetX,
            y: selected.relativeFrame.minY * scaleY + offsetY,
            width: selected.relativeFrame.width * scaleX,
            height: selected.relativeFrame.height * scaleY
        )
        let measuredResidual = [
            abs(mapped.minX - selected.captureFrame.minX),
            abs(mapped.minY - selected.captureFrame.minY),
            abs(mapped.width - selected.captureFrame.width),
            abs(mapped.height - selected.captureFrame.height),
        ].max() ?? 0

        return WindowSelectionPolicy(
            selectedWindowRole: selected.roleCategory,
            requiredTitleTokens: selected.roleCategory == "reception" ? ["接待中心"] : [],
            minimumRelativeSize: CGSize(
                width: max(320, selected.relativeFrame.width * 0.4),
                height: max(240, selected.relativeFrame.height * 0.4)
            ),
            requiredRegions: selected.regionCategories.intersection(expectedRegions),
            coordinateMapping: CoordinateMapping(
                pointsToPixelsX: scaleX,
                pointsToPixelsY: scaleY,
                originOffsetX: offsetX,
                originOffsetY: offsetY,
                maximumResidual: max(3, measuredResidual + 1)
            )
        )
    }

    private static func independentSignalCount(for window: CalibrationWindow) -> Int {
        (window.roleCategory == "reception" ? 1 : 0)
            + window.regionCategories.intersection(expectedRegions).count
    }

    private static func score(_ window: CalibrationWindow) -> Int {
        independentSignalCount(for: window) * 100
            + (window.roleCategory == "reception" ? 50 : 0)
            + (window.focused ? 10 : 0)
    }
}
