import Foundation
import QianniuOCRCore

@MainActor
final class AXMainChatLocator: PanelLocating {
    private let reader: AXWindowReader

    init(reader: AXWindowReader) {
        self.reader = reader
    }

    func locate() throws -> LocatedPanel {
        let snapshot = try reader.read()
        guard let frame = MainChatSelection.cropFrame(
            from: snapshot.nodes,
            inside: snapshot.window.frame
        ) else {
            throw OCRAppError.mainChatRegionNotFound
        }
        return LocatedPanel(
            ownerPID: snapshot.ownerPID,
            windowTitle: snapshot.window.title,
            windowFrame: snapshot.window.frame,
            panelFrame: frame,
            identityCandidates: AXCustomerIdentity.candidates(
                nodes: snapshot.nodes,
                chatFrame: frame
            )
        )
    }
}
