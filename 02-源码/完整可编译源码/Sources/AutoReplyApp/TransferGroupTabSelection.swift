import CoreGraphics
import Foundation
import QianniuOCRCore

struct TransferWindowCandidate: Equatable {
    let id: UInt32
    let frame: CGRect
}

struct TransferMenuAnchor {
    let ownerPID: pid_t
    let receptionWindowID: UInt32
    let receptionFrame: CGRect
    let buttonFrame: CGRect
}

enum TransferPopupSelection {
    static func select(
        windows: [TransferWindowCandidate],
        visibleBefore: Set<UInt32>,
        receptionWindowID: UInt32,
        receptionFrame: CGRect,
        transferButtonFrame: CGRect
    ) -> TransferWindowCandidate? {
        let nearby = receptionFrame.insetBy(dx: -receptionFrame.width * 0.25,
                                             dy: -receptionFrame.height * 0.25)
        let matches = windows.filter { candidate in
            guard candidate.id != receptionWindowID,
                  !visibleBefore.contains(candidate.id),
                  candidate.frame.width >= 240,
                  candidate.frame.width <= 640,
                  candidate.frame.height >= 220,
                  candidate.frame.height <= 760,
                  candidate.frame.intersects(nearby) else { return false }
            let horizontalDistance = abs(candidate.frame.maxX - transferButtonFrame.midX)
            let verticalDistance = abs(candidate.frame.minY - transferButtonFrame.maxY)
            return horizontalDistance <= 480 && verticalDistance <= 360
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}

enum TransferGroupTabSelection {
    static func clickPoint(lines: [OCRLine], imageSize: CGSize) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let matches = lines.filter { line in
            normalized(line.text) == "转交到组"
                && (line.confidence ?? 1) >= 0.65
                && imageBounds.contains(line.box)
        }
        guard matches.count == 1 else { return nil }
        return CGPoint(x: matches[0].box.midX, y: matches[0].box.midY)
    }

    private static func normalized(_ text: String) -> String {
        text.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
    }
}

enum TransferGroupClickResult: Equatable {
    case continueTrying
    case selectionAccepted
}

enum TransferGroupCandidateSelection {
    static func clickPoints(lines: [OCRLine], imageSize: CGSize) -> [CGPoint] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let minimumY = imageSize.height * 0.35
        var accepted: [OCRLine] = []
        for line in lines.sorted(by: { $0.box.minY < $1.box.minY }) {
            let text = normalized(line.text)
            guard (line.confidence ?? 1) >= 0.55,
                  imageBounds.contains(line.box),
                  line.box.minY >= minimumY,
                  text.contains("组"),
                  text != "转交到组",
                  !text.contains("批量转交") else { continue }
            if accepted.contains(where: { abs($0.box.midY - line.box.midY) < 12 }) { continue }
            accepted.append(line)
        }
        return accepted.map { CGPoint(x: $0.box.midX, y: $0.box.midY) }
    }

    static func resultAfterClick(
        popupStillVisible: Bool,
        recognizedTextsBefore: [String],
        recognizedTextsAfter: [String]
    ) -> TransferGroupClickResult {
        guard popupStillVisible else { return .selectionAccepted }
        let before = normalizedSet(recognizedTextsBefore)
        let after = normalizedSet(recognizedTextsAfter)
        guard before != after else { return .continueTrying }
        let union = before.union(after)
        guard !union.isEmpty else { return .continueTrying }
        let similarity = Double(before.intersection(after).count) / Double(union.count)
        // A disabled row may only change hover/focus rendering, and OCR can
        // fluctuate by one glyph between adjacent captures. Only a wholesale
        // content change counts as a new confirmation step.
        return similarity < 0.4 ? .selectionAccepted : .continueTrying
    }

    static func normalizedTexts(_ lines: [OCRLine]) -> [String] {
        lines.map(\.text)
    }

    private static func normalizedSet(_ texts: [String]) -> Set<String> {
        Set(texts.map(normalized).filter { !$0.isEmpty })
    }

    private static func normalized(_ text: String) -> String {
        text.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
    }
}

enum TransferPopupFallback {
    static func region(
        displayFrame: CGRect,
        receptionFrame: CGRect,
        transferButtonFrame: CGRect
    ) -> CGRect? {
        guard displayFrame.intersects(receptionFrame),
              displayFrame.contains(transferButtonFrame) else { return nil }
        let x = max(displayFrame.minX, transferButtonFrame.midX - 520)
        let y = max(displayFrame.minY, transferButtonFrame.maxY - 20)
        let maxX = min(displayFrame.maxX, transferButtonFrame.maxX)
        let maxY = min(displayFrame.maxY, y + 190)
        let region = CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
        return region.width >= 240 && region.height >= 110 ? region : nil
    }

    static func fullRegion(
        displayFrame: CGRect,
        receptionFrame: CGRect,
        transferButtonFrame: CGRect
    ) -> CGRect? {
        guard displayFrame.intersects(receptionFrame),
              displayFrame.contains(transferButtonFrame) else { return nil }
        let x = max(displayFrame.minX, transferButtonFrame.midX - 520)
        let y = max(displayFrame.minY, transferButtonFrame.maxY - 20)
        let maxX = min(displayFrame.maxX, transferButtonFrame.maxX)
        let maxY = min(displayFrame.maxY, y + 760)
        let region = CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
        return region.width >= 240 && region.height >= 220 ? region : nil
    }
}
