import AppKit

@MainActor final class FloatingProgressPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 530),
                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "AI 客服 · 实时进度"
        level = .floating
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        minSize = NSSize(width: 380, height: 150)
        setFrameAutosaveName("CustomerServiceProgressFloat")
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func setAutomationActive(_ active: Bool) {
        // While UI automation runs, the overlay must not intercept its clicks.
        ignoresMouseEvents = active
    }
}
