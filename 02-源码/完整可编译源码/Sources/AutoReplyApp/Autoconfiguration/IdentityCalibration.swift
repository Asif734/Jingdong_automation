import Foundation
import UnreadCore

enum IdentityCalibration {
    static func calibrate(
        snapshot: CalibrationSnapshot,
        ocrAvailable: Bool
    ) -> ConversationIdentityPolicy {
        let containerTitle = snapshot.nodes.contains {
            ["AXGroup", "AXRow"].contains($0.role)
                && $0.labelCategory == "identity-like"
        }
        let childNickname = snapshot.nodes.contains {
            $0.role == "AXStaticText"
                && $0.labelCategory == "identity-like"
                && $0.parentID != nil
        }
        let header = snapshot.nodes.contains {
            $0.role == "AXStaticText"
                && $0.labelCategory == "reception-title"
        }
        return .availableSources(
            containerTitle: containerTitle,
            childNickname: childNickname,
            header: header,
            ocr: ocrAvailable
        )
    }
}
