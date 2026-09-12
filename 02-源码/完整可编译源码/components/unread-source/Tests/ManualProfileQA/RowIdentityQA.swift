import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    AXUIElementSetMessagingTimeout(element, 0.2)
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let rawPosition = attribute(element, kAXPositionAttribute),
          let rawSize = attribute(element, kAXSizeAttribute),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(),
          CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &position),
          AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size) else { return nil }
    return CGRect(origin: position, size: size)
}

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.taobao.Aliworkbench"
}) else {
    fatalError("千牛未运行")
}

let root = AXUIElementCreateApplication(app.processIdentifier)
let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
for (windowIndex, window) in windows.enumerated() {
    let title = string(window, kAXTitleAttribute)
    guard title.contains("接待"), let windowFrame = frame(window) else { continue }
    print("WINDOW[\(windowIndex)] \(title) \(windowFrame)")
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var cursor = 0
    while cursor < queue.count, cursor < 2500 {
        let (element, depth) = queue[cursor]
        cursor += 1
        let role = string(element, kAXRoleAttribute)
        let elementFrame = frame(element) ?? .zero
        if ["AXGroup", "AXRow"].contains(role),
           elementFrame.width >= 100, elementFrame.width < windowFrame.width * 0.4,
           elementFrame.height >= 30, elementFrame.height <= 100,
           elementFrame.minX < windowFrame.minX + windowFrame.width * 0.28 {
            let rowTitle = string(element, kAXTitleAttribute)
            let rowValue = string(element, kAXValueAttribute)
            let rowDescription = string(element, kAXDescriptionAttribute)
            print("  ROW frame=\(elementFrame) title=\(rowTitle.debugDescription) value=\(rowValue.debugDescription) description=\(rowDescription.debugDescription)")
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children where string(child, kAXRoleAttribute) == "AXStaticText" {
                let childFrame = frame(child) ?? .zero
                guard childFrame.midY <= elementFrame.midY + 2 else { continue }
                print("    TOP_TEXT frame=\(childFrame) title=\(string(child, kAXTitleAttribute).debugDescription) value=\(string(child, kAXValueAttribute).debugDescription) description=\(string(child, kAXDescriptionAttribute).debugDescription)")
            }
        }
        if depth < 35 {
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                queue.append((child, depth + 1))
            }
        }
    }
}
