import Foundation
import Darwin

// Compile with TranslationCore's sources to construct and fully drain a request.
// Synthetic bytes stand in for an already encoded image; no PNG encoding,
// screen capture, credential lookup, URLSession, or network request is performed.
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

@main struct RequestEncodingProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let size = Int(CommandLine.arguments[1]), (1...10 * 1048576).contains(size) else {
            print("Usage: request-probe <input bytes: 1...10485760>")
            exit(2)
        }
        let baseline = memory()
        let input = Data(repeating: 0xA5, count: size)
        let clock = ContinuousClock()
        let start = clock.now
        let request = try DeepSeekClient.makeRequest(
            imageData: input, mimeType: "image/png", apiKey: "synthetic-probe-key", targetLanguage: "简体中文"
        )
        // Drain both representations into the same bounded sink. A lazy body
        // must include all Base64 work, not just cheap stream construction.
        let stream = request.httpBodyStream ?? InputStream(data: request.httpBody!)
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var bodyBytes = 0
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            precondition(count >= 0)
            if count == 0 { break }
            bodyBytes += count
        }
        stream.close()
        let elapsed = start.duration(to: clock.now)
        let sample = memory()
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        // Keep input and output alive at the sampling point for every run.
        withExtendedLifetime((input, request)) {
            print(String(format: "input_bytes=%d body_bytes=%d elapsed_ms=%.2f baseline_MiB=%.2f current_MiB=%.2f peak_MiB=%.2f",
                         size, bodyBytes, ms, baseline.current, sample.current, sample.peak))
        }
    }
}
