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
    print(String(format: "%@ footprint=%.2f MiB peak=%.2f MiB status=%d", phase, Double(info.phys_footprint)/1048576, Double(info.ledger_phys_footprint_peak)/1048576, result))
    fflush(nil)
}

@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let selector = RegionSelector()
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("PID \(ProcessInfo.processInfo.processIdentifier)")
        for screen in NSScreen.screens {
            print("SCREEN \(screen.frame) backingScale=\(screen.backingScaleFactor)")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            sample("BASELINE")
            selector.begin { _ in }
            try? await Task.sleep(for: .seconds(1))
            sample("OVERLAY_VISIBLE")
            for _ in 0..<30 {
                for window in NSApp.windows {
                    window.contentView?.needsDisplay = true
                    window.displayIfNeeded()
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            sample("OVERLAY_REDRAWN")
            selector.cancel()
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
