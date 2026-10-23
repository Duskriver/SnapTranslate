import AppKit
import Testing
@testable import SnapTranslate

@MainActor
@Suite(.serialized)
struct RegionSelectionTests {
    private static let application: NSApplication = {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        return application
    }()

    @Test func firstDragInNonKeyPanelSelectsRegion() throws {
        try verifyFirstDrag(initiallyKey: false)
    }

    @Test func firstDragInKeyPanelSelectsRegion() throws {
        try verifyFirstDrag(initiallyKey: true)
    }

    private func verifyFirstDrag(initiallyKey: Bool) throws {
        _ = Self.application
        // Two real panels reproduce the focus state of two display overlays,
        // even on a machine with only one display. They remain invisible.
        let firstPanel = makePanel(x: 0)
        let targetPanel = makePanel(x: 120)
        defer {
            for panel in [firstPanel, targetPanel] {
                panel.orderOut(nil)
                panel.close()
                panel.contentView = nil
            }
        }

        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        targetPanel.contentView = view
        var selections: [NSRect] = []
        view.onSelection = { selections.append($0) }
        firstPanel.orderFrontRegardless()
        targetPanel.orderFrontRegardless()
        (initiallyKey ? targetPanel : firstPanel).makeKey()
        try #require(targetPanel.isKeyWindow == initiallyKey)
        try #require(firstPanel.isKeyWindow != initiallyKey)

        // Dispatch through NSWindow so AppKit applies its first-click policy.
        // Calling view.mouseDown directly would hide the multi-display bug.
        // These events stay in this process; no OS event posting or capture occurs.
        targetPanel.sendEvent(try mouseEvent(.leftMouseDown, at: NSPoint(x: 10, y: 20), in: targetPanel))
        targetPanel.sendEvent(try mouseEvent(.leftMouseDragged, at: NSPoint(x: 80, y: 90), in: targetPanel))
        #expect(selections.isEmpty)
        targetPanel.sendEvent(try mouseEvent(.leftMouseUp, at: NSPoint(x: 80, y: 90), in: targetPanel))

        #expect(targetPanel.isKeyWindow)
        #expect(selections == [NSRect(x: 10, y: 20, width: 70, height: 70)])
    }

    private func makePanel(x: CGFloat) -> SelectionPanel {
        let panel = SelectionPanel(
            contentRect: NSRect(x: x, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.alphaValue = 0
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }
}
