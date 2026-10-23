import AppKit
import Darwin

func sample(_ phase: String) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS, "Cannot sample physical footprint")
    print(String(format: "%@ footprint=%.2f MiB peak=%.2f MiB", phase, Double(info.phys_footprint)/1048576, Double(info.ledger_phys_footprint_peak)/1048576))
    fflush(nil)
}

@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let selector = RegionSelector()
    let drag = ProcessInfo.processInfo.arguments.contains("--drag")
    var selected: SelectedRegion?

    // Component-level events stay inside this test process. Nothing is posted
    // to the OS event queue, and no screen image or network request is created.
    func event(_ type: NSEvent.EventType, _ point: NSPoint, _ window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func dragSelection() async {
        let window = NSApp.windows.first { $0.title == "选择翻译区域" }!
        let view = window.contentView!
        precondition(view.bounds.width >= 920 && view.bounds.height >= 610, "Use a display at least 920x610 points")
        let start = NSPoint(x: 320, y: 360)
        var end = start
        view.mouseDown(with: event(.leftMouseDown, start, window))
        for step in 1...30 {
            end = NSPoint(x: start.x + 600 * CGFloat(step) / 30,
                          y: start.y + 250 * CGFloat(step) / 30)
            view.mouseDragged(with: event(.leftMouseDragged, end, window))
            // Only the event's window: other displays do not redraw during a drag.
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(80))
        }
        sample("OVERLAY_DRAGGED")
        view.mouseUp(with: event(.leftMouseUp, end, window))
        guard let selected else { fatalError("Selection callback missing") }
        let local = selected.rect.offsetBy(dx: -selected.screen.frame.minX, dy: -selected.screen.frame.minY)
        precondition(local == NSRect(x: start.x, y: start.y, width: 600, height: 250))
        print("SELECTION_VERIFIED 600x250")
        // Local window/view references end before measuring release below.
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("PID \(ProcessInfo.processInfo.processIdentifier)")
        for screen in NSScreen.screens {
            print("SCREEN \(screen.frame) backingScale=\(screen.backingScaleFactor)")
        }
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(1))
            sample("BASELINE")
            selector.begin { [weak self] in self?.selected = $0 }
            try? await Task.sleep(for: .seconds(1))
            sample("OVERLAY_VISIBLE")
            if drag {
                await dragSelection()
            } else {
                // This is the original 30-redraw workload, kept unchanged.
                for _ in 0..<30 {
                    for window in NSApp.windows {
                        window.contentView?.needsDisplay = true
                        window.displayIfNeeded()
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                sample("OVERLAY_REDRAWN")
                selector.cancel()
            }
            sample("CLOSED_IMMEDIATE")
            try? await Task.sleep(for: .seconds(2))
            sample("CLOSED_SETTLED")
            NSApp.terminate(nil)
        }
    }
}
@main struct Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = ProbeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
