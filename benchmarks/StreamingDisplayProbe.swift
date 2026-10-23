import AppKit
import Darwin
@testable import TranslationCore

private func memory() -> (current: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return (Double(info.phys_footprint) / 1048576, Double(info.ledger_phys_footprint_peak) / 1048576)
}

@main struct StreamingDisplayProbe {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2,
              let updates = Int(CommandLine.arguments[1]), (1...2_048).contains(updates) else {
            print("Usage: streaming-probe <updates: 1...2048>")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let controller = ResultPanelController()
        controller.window?.alphaValue = 0
        controller.showLoading()
        defer { controller.dismiss() }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let views = descendants(controller.window!.contentView!)
        let textView = views.compactMap { $0 as? NSTextView }.first!
        let container = textView.textContainer!
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        textView.layoutManager?.ensureLayout(for: container)

        // Four model fragments per UI batch, with combining characters and ZWJ
        // split across fragments. No wall-clock/network delay is simulated.
        let fragments = ["截图翻译：保留段落、列表和代码。", "let count = 42; cafe", "\u{301} 👩", "\u{200D}💻\n"]
        let payloads = try fragments.map {
            try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": $0]]]])
        }
        let expected = String(repeating: fragments.joined(), count: updates)
        let finish = Data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#.utf8)
        var stream = TranslationStream()
        let baseline = memory()
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<updates {
            // Match the autorelease boundary of separate UI events, rather than
            // accumulating every event's temporaries in one synthetic loop.
            try autoreleasepool {
                for payload in payloads { try stream.consume(payload) }
                #if INCREMENTAL_STREAMING
                controller.append(delta: stream.takePendingText())
                #else
                controller.update(text: stream.text)
                #endif
                textView.layoutManager?.ensureLayout(for: container)
            }
        }
        try stream.consume(finish)
        try stream.consume(Data("[DONE]".utf8))
        let completed = try stream.completedText()
        #if !INCREMENTAL_STREAMING
        // The original app redundantly applied the complete result at the end.
        controller.update(text: completed)
        #endif
        controller.finish()
        textView.layoutManager?.ensureLayout(for: container)
        let elapsed = start.duration(to: clock.now)
        let sample = memory()
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        precondition(Array(completed.utf8) == Array(expected.utf8))
        precondition(Array(textView.string.utf8) == Array(expected.utf8))
        withExtendedLifetime((controller, stream, expected)) {
            print(String(format: "updates=%d output_bytes=%d elapsed_ms=%.2f baseline_MiB=%.2f current_MiB=%.2f peak_MiB=%.2f",
                         updates, expected.utf8.count, ms, baseline.current, sample.current, sample.peak))
        }
    }
}
