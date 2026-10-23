import AppKit
import QuartzCore

struct SelectedRegion {
    let rect: NSRect
    let screen: NSScreen
}

/// Transparent overlays contain no screenshot textures and exist only during selection.
@MainActor
final class RegionSelector {
    private let notificationCenter: NotificationCenter
    private var panels: [SelectionPanel] = []
    private var completion: ((SelectedRegion?) -> Void)?
    private var eventMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    var isSelecting: Bool { completion != nil }

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

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
        screenObserver = notificationCenter.addObserver(
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
        if let screenObserver { notificationCenter.removeObserver(screenObserver) }
        self.screenObserver = nil
        for panel in panels {
            (panel.contentView as? SelectionView)?.onSelection = nil
            (panel.contentView as? SelectionView)?.onCancel = nil
            panel.orderOut(nil)
            panel.close()
            panel.contentView = nil
        }
        panels.removeAll()
        completion(region)
    }
}

@MainActor
final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SelectionView: NSView {
    var onSelection: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    private var start: NSPoint?
    private var selection: NSRect = .zero
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let hintBackground = CALayer()
    private let hintText = CATextLayer()
    private let hintSize: NSSize
    override var acceptsFirstResponder: Bool { true }

    // A drag must start on any display, even when another overlay is key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        let title = NSAttributedString(
            string: "拖动选择翻译区域 · Esc 取消",
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
        )
        hintSize = title.size()
        super.init(frame: frameRect)

        // Host our own layers: AppKit must not repaint a screen-sized bitmap on
        // every mouse movement. The compositor can reuse these vector layers.
        let root = CALayer()
        root.frame = bounds
        root.isGeometryFlipped = false
        layer = root
        wantsLayer = true
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.22).cgColor
        dimLayer.fillRule = .evenOdd
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1
        hintBackground.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        hintBackground.cornerRadius = 12
        hintText.string = title
        hintText.alignmentMode = .center
        root.addSublayer(dimLayer)
        root.addSublayer(borderLayer)
        root.addSublayer(hintBackground)
        hintBackground.addSublayer(hintText)
        updateLayers()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateLayers()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        let end = NSPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        let next = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard next != selection else { return }
        selection = next
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard selection.width >= 8, selection.height >= 8 else {
            start = nil
            selection = .zero
            updateLayers()
            return
        }
        onSelection?(selection)
    }

    private func updateLayers() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let scale = window?.backingScaleFactor ?? 1
        for current in [root, dimLayer, borderLayer, hintBackground, hintText] {
            current.contentsScale = scale
        }
        dimLayer.frame = bounds
        borderLayer.frame = bounds
        let dim = CGMutablePath()
        dim.addRect(bounds)
        if !selection.isEmpty { dim.addRect(selection) }
        dimLayer.path = dim
        borderLayer.path = selection.isEmpty ? nil : CGPath(rect: selection.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        hintBackground.frame = NSRect(x: (bounds.width - hintSize.width) / 2 - 16, y: bounds.height - 92, width: hintSize.width + 32, height: 38)
        hintText.frame = NSRect(x: 16, y: (38 - hintSize.height) / 2, width: hintSize.width, height: hintSize.height)
    }
}
