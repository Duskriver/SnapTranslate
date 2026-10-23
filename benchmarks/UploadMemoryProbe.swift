import Foundation
import Darwin

private struct Sample: Sendable {
    let current: Double
    let peak: Double
    static func take() -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return Self(current: Double(info.phys_footprint) / 1_048_576,
                    peak: Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}

private final class Metrics: @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: Sample?
    private var uploaded: Sample?
    private var firstDelta: ContinuousClock.Instant?
    func preparedRequest() { lock.withLock { prepared = .take() } }
    func receivedDelta() {
        lock.withLock {
            guard firstDelta == nil else { return }
            firstDelta = .now
            uploaded = .take()
        }
    }
    var values: (Sample, Sample, ContinuousClock.Instant) {
        lock.withLock { (prepared!, uploaded!, firstDelta!) }
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

private func cpuMilliseconds() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
}

@main struct UploadMemoryProbe {
    static func main() async throws {
        let size = Int(CommandLine.arguments[1])!
        precondition((1...10 * 1_024 * 1_024).contains(size))
        let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "normal"
        let baseline = Sample.take()
        let input = Data(repeating: 0xA5, count: size)
        let metrics = Metrics()
        let client = DeepSeekClient(updateInterval: .zero) {
            metrics.preparedRequest()
            return URLSession(configuration: DeepSeekClient.sessionConfiguration())
        }
        let cpuStart = cpuMilliseconds()
        let start = ContinuousClock.now
        let task = Task {
            try await client.translate(imageData: input, mimeType: "image/png", apiKey: "synthetic-probe-key",
                                       targetLanguage: "简体中文") { _ in
                metrics.receivedDelta()
                if mode == "cancel-response" { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        if mode == "cancel-upload" {
            // The local server signals once it has received the request headers.
            let ready = ProcessInfo.processInfo.environment["PROBE_READY_PATH"]!
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !FileManager.default.fileExists(atPath: ready) {
                precondition(ContinuousClock.now < deadline, "Upload did not reach local server")
                try await Task.sleep(for: .milliseconds(1))
            }
            task.cancel()
        }
        if mode.hasPrefix("cancel-") {
            do {
                _ = try await task.value
                preconditionFailure("Cancellation unexpectedly succeeded")
            } catch is CancellationError {
                print("cancelled")
                return
            }
        }
        if mode == "reject" {
            do {
                _ = try await task.value
                preconditionFailure("HTTP rejection unexpectedly succeeded")
            } catch TranslationError.unauthorized {
                print("rejected")
                return
            }
        }
        let result = try await task.value
        let end = ContinuousClock.now
        let cpu = cpuMilliseconds() - cpuStart
        let sample = Sample.take()
        let (prepared, uploaded, firstDelta) = metrics.values
        precondition(result == "译文OK")
        withExtendedLifetime(input) {
            print(String(format: "input_bytes=%d upload_ms=%.2f elapsed_ms=%.2f cpu_ms=%.2f baseline_MiB=%.2f prepared_MiB=%.2f waiting_MiB=%.2f current_MiB=%.2f peak_MiB=%.2f",
                         size, milliseconds(start.duration(to: firstDelta)), milliseconds(start.duration(to: end)),
                         cpu, baseline.current, prepared.current, uploaded.current, sample.current, sample.peak))
        }
    }
}
