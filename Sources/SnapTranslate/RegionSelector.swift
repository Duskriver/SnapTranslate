import AppKit

struct SelectedRegion {
    let rect: NSRect
    let screen: NSScreen
}

/// Transparent overlays contain no screenshot textures and exist only during selection.
@MainActor
final class RegionSelector {
    private var panels: [SelectionPanel] = []
    private var completion: ((SelectedRegion?) -> Void)?
    private var eventMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    var isSelecting: Bool { completion != nil }

    func begin(completion: @escaping (SelectedRegion?) -> Void) {
        cancel()
        self.completion = completion
        for screen in NSScreen.screens {
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "选择翻译区域"
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.setAccessibilityElement(true)
            view.setAccessibilityLabel("拖动选择翻译区域，按 Esc 取消")
            view.onSelection = { [weak self, weak screen] rect in
                guard let screen else { self?.cancel(); return }
                let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                self?.finish(SelectedRegion(rect: global, screen: screen))
            }
            view.onCancel = { [weak self] in self?.cancel() }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        let cursor = NSEvent.mouseLocation
        (panels.first { $0.frame.contains(cursor) } ?? panels.first)?.makeKey()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func cancel() { finish(nil) }

    private func finish(_ region: SelectedRegion?) {
        guard let completion else { return }
        self.completion = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        self.eventMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        self.screenObserver = nil
        for panel in panels {
            (panel.contentView as? SelectionView)?.onSelection = nil
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        completion(region)
    }
}

@MainActor
private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SelectionView: NSView {
    var onSelection: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var selection: NSRect = .zero
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        let end = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        selection = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 8, selection.height >= 8 else {
            start = nil
            selection = .zero
            needsDisplay = true
            return
        }
        onSelection?(selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if !selection.isEmpty { dim.appendRect(selection) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.22).setFill()
        dim.fill()
        if !selection.isEmpty {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
        let title = "拖动选择翻译区域 · Esc 取消" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = title.size(withAttributes: attributes)
        let box = NSRect(x: (bounds.width - size.width) / 2 - 16, y: bounds.height - 92, width: size.width + 32, height: 38)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        title.draw(at: NSPoint(x: box.minX + 16, y: box.midY - size.height / 2), withAttributes: attributes)
    }
}
