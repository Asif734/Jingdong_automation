import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
    return raw as? T
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let position: AXValue = attribute(kAXPositionAttribute, from: element),
          let size: AXValue = attribute(kAXSizeAttribute, from: element) else { return nil }
    var origin = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &origin),
          AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: origin, size: dimensions)
}

let uid = CommandLine.arguments.dropFirst().first ?? "stoneshishininger"
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.taobao.Aliworkbench").first else {
    fatalError("千牛未运行")
}
let application = AXUIElementCreateApplication(app.processIdentifier)
let windows: [AXUIElement] = attribute(kAXWindowsAttribute, from: application) ?? []
guard let window = windows.first(where: {
    let title: String = attribute(kAXTitleAttribute, from: $0) ?? ""
    return title.contains("接待中心")
}), let windowFrame = frame(of: window) else {
    fatalError("接待中心窗口不存在")
}

var queue: [AXUIElement] = [window]
var nodes: [SenderAXNode] = []
var index = 0
while index < queue.count, index < 20_000 {
    let element = queue[index]
    index += 1
    if let elementFrame = frame(of: element), elementFrame.width > 0, elementFrame.height > 0 {
        nodes.append(SenderAXNode(
            id: nodes.count,
            parentID: nil,
            role: attribute(kAXRoleAttribute, from: element) ?? "",
            title: attribute(kAXTitleAttribute, from: element),
            description: attribute(kAXDescriptionAttribute, from: element),
            value: attribute(kAXValueAttribute, from: element),
            frame: elementFrame,
            isEnabled: attribute(kAXEnabledAttribute, from: element) ?? true
        ))
    }
    let children: [AXUIElement] = attribute(kAXChildrenAttribute, from: element) ?? []
    queue.append(contentsOf: children)
}

print("window=\(windowFrame)")
for node in nodes where node.labels.contains(uid) {
    print("candidate id=\(node.id) role=\(node.role) enabled=\(node.isEnabled) frame=\(node.frame) labels=\(node.labels)")
}
if let selected = QianniuElementSelection.searchResult(uid: uid, nodes: nodes, window: windowFrame) {
    print("selected id=\(selected.id) role=\(selected.role) frame=\(selected.frame) point=\(String(describing: QianniuElementSelection.interactionPoint(for: selected, inside: windowFrame)))")
} else {
    print("selected=nil")
}
