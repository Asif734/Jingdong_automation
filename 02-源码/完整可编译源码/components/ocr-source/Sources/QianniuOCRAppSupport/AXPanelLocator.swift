import Foundation
import QianniuOCRCore

@MainActor
protocol PanelLocating {
    func locate() throws -> LocatedPanel
}

@MainActor
final class AXPanelLocator: PanelLocating {
    private let reader: AXWindowReader

    init(reader: AXWindowReader) {
        self.reader = reader
    }

    func locate() throws -> LocatedPanel {
        let snapshot = try reader.read()
        guard let panel = TargetSelection.messagePanel(
            from: snapshot.candidates,
            inside: snapshot.window.frame
        ) else {
            throw OCRAppError.messagePanelNotFound
        }
        guard let expandedPanelFrame = TargetSelection.expandedMessagePanelFrame(
            anchor: panel.frame,
            window: snapshot.window.frame
        ) else {
            throw OCRAppError.messagePanelNotFound
        }
        return LocatedPanel(
            ownerPID: snapshot.ownerPID,
            windowTitle: snapshot.window.title,
            windowFrame: snapshot.window.frame,
            panelFrame: expandedPanelFrame
        )
    }
}
