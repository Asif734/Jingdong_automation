import AppKit
import ApplicationServices
import Foundation
import QianniuOCRCore

struct AXElementEntry {
    let element: AXUIElement
    let candidate: AXCandidate
    let isEnabled: Bool
    let isBusy: Bool
}

struct AXWindowSnapshot {
    let ownerPID: Int32
    let windowElement: AXUIElement
    let window: WindowCandidate
    let entries: [AXElementEntry]
    let nodes: [AXNodeCandidate]

    var candidates: [AXCandidate] { entries.map(\.candidate) }

    func entry(matching candidate: AXCandidate) -> AXElementEntry? {
        entries.first { $0.candidate == candidate }
    }
}

private struct AXTraversalItem {
    let element: AXUIElement
    let parentID: Int?
}

enum AXParentIDPropagation {
    static func childrenParentID(nodeID: Int?, inheritedParentID: Int?) -> Int? {
        nodeID ?? inheritedParentID
    }
}

@MainActor
final class AXWindowReader {
    private let maximumNodes = 20_000

    func read() throws -> AXWindowSnapshot {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            throw OCRAppError.accessibilityPermissionMissing
        }

        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.taobao.Aliworkbench"
        ).first else {
            throw OCRAppError.qianniuNotRunning
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 3.0)
        let windows: [AXUIElement] = attribute(kAXWindowsAttribute, from: appElement) ?? []
        let windowEntries = windows.compactMap { element -> (AXUIElement, WindowCandidate)? in
            guard let frame = frame(of: element), frame.width > 0, frame.height > 0 else { return nil }
            let title: String = attribute(kAXTitleAttribute, from: element) ?? ""
            return (
                element,
                WindowCandidate(
                    id: 0,
                    ownerPID: app.processIdentifier,
                    bundleID: app.bundleIdentifier,
                    title: title,
                    frame: frame,
                    isVisible: true
                )
            )
        }

        guard let chosen = TargetSelection.qianniuWindow(from: windowEntries.map(\.1)),
              let windowElement = windowEntries.first(where: { $0.1 == chosen })?.0 else {
            throw OCRAppError.receptionWindowNotFound
        }

        var queue = [AXTraversalItem(element: windowElement, parentID: nil)]
        var index = 0
        var entries: [AXElementEntry] = []
        var nodes: [AXNodeCandidate] = []
        var nextNodeID = 0

        while index < queue.count, index < maximumNodes {
            let item = queue[index]
            index += 1
            let element = item.element
            let nodeID: Int?
            if let candidate = candidate(from: element) {
                let currentNodeID = nextNodeID
                nodeID = currentNodeID
                nextNodeID += 1
                let isEnabled: Bool = attribute(kAXEnabledAttribute, from: element) ?? true
                let isBusy: Bool = attribute(kAXElementBusyAttribute, from: element) ?? false
                entries.append(
                    AXElementEntry(
                        element: element,
                        candidate: candidate,
                        isEnabled: isEnabled,
                        isBusy: isBusy
                    )
                )
                nodes.append(
                    AXNodeCandidate(
                        id: currentNodeID,
                        parentID: item.parentID,
                        candidate: candidate,
                        isSelected: attribute(kAXSelectedAttribute, from: element) ?? false
                    )
                )
            } else {
                nodeID = nil
            }
            let children: [AXUIElement] = attribute(kAXChildrenAttribute, from: element) ?? []
            let parentID = AXParentIDPropagation.childrenParentID(
                nodeID: nodeID,
                inheritedParentID: item.parentID
            )
            queue.append(contentsOf: children.map {
                AXTraversalItem(element: $0, parentID: parentID)
            })
        }

        return AXWindowSnapshot(
            ownerPID: app.processIdentifier,
            windowElement: windowElement,
            window: chosen,
            entries: entries,
            nodes: nodes
        )
    }

    private func candidate(from element: AXUIElement) -> AXCandidate? {
        guard let frame = frame(of: element), frame.width > 0, frame.height > 0 else { return nil }
        let role: String = attribute(kAXRoleAttribute, from: element) ?? ""
        let title: String? = attribute(kAXTitleAttribute, from: element)
        let description: String? = attribute(kAXDescriptionAttribute, from: element)
        let value: String? = attribute(kAXValueAttribute, from: element)
        return AXCandidate(role: role, title: title, description: description, value: value, frame: frame)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(kAXPositionAttribute, from: element),
              let sizeValue: AXValue = attribute(kAXSizeAttribute, from: element) else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            return nil
        }
        return raw as? T
    }
}
