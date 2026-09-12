import CoreGraphics
@testable import AutoReplyApp

extension CalibrationSnapshot {
    static func colleagueB40Controls(exactSendLabel: Bool) -> CalibrationSnapshot {
        let toolbarCount = exactSendLabel ? 39 : 38
        var nodes = (0..<toolbarCount).map { index in
            CalibrationAXNode(
                id: 100 + index,
                parentID: 1,
                role: "AXButton",
                actionNames: ["AXPress"],
                labelCategory: "press-control",
                relativeFrame: CGRect(
                    x: 0.70 + CGFloat(index % 5) * 0.045,
                    y: 0.05 + CGFloat(index / 5) * 0.045,
                    width: 0.035,
                    height: 0.025
                ),
                hasValue: true
            )
        }
        if !exactSendLabel {
            nodes.append(CalibrationAXNode(
                id: 199,
                parentID: 1,
                role: "AXButton",
                actionNames: ["AXPress"],
                labelCategory: "press-control",
                relativeFrame: CGRect(x: 0.60, y: 0.73, width: 0.06, height: 0.045),
                hasValue: true
            ))
        }
        nodes += [
            CalibrationAXNode(
                id: 1,
                parentID: nil,
                role: "AXGroup",
                actionNames: [],
                labelCategory: "chat-region",
                relativeFrame: CGRect(x: 0.24, y: 0.12, width: 0.43, height: 0.72),
                hasValue: false
            ),
            CalibrationAXNode(
                id: 2,
                parentID: 1,
                role: "AXTextArea",
                actionNames: ["AXConfirm"],
                labelCategory: "input-control",
                relativeFrame: CGRect(x: 0.25, y: 0.70, width: 0.34, height: 0.10),
                hasValue: true
            ),
            CalibrationAXNode(
                id: 200,
                parentID: 1,
                role: "AXButton",
                actionNames: ["AXPress"],
                labelCategory: exactSendLabel ? "send-control" : "press-control",
                relativeFrame: CGRect(x: 0.60, y: 0.73, width: 0.06, height: 0.045),
                hasValue: true
            )
        ]
        return CalibrationSnapshot(
            macOSBuild: "25G83",
            architecture: "arm64",
            qianniuVersion: "9.97.74",
            qianniuBuild: "20260812105806",
            qianniuRuntimeArchitecture: "arm64",
            displays: [CalibrationDisplay(
                relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                scale: 2
            )],
            windows: [CalibrationWindow(
                roleCategory: "reception",
                relativeFrame: CGRect(x: 0, y: 0, width: 1, height: 1),
                captureFrame: CGRect(x: 0, y: 0, width: 2, height: 2),
                minimized: false,
                focused: true,
                regionCategories: ["conversation-list", "chat", "composer"]
            )],
            nodes: nodes
        )
    }
}
