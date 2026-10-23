import AppKit
import Darwin
import ImageIO

// Synthetic bitmaps only. The comparison script exposes the original encoding
// block through the same adapter and instruments synchronous ImageIO entry/exit.
enum PNGProbeMetrics {
    private static let state = State()
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var active = 0
        var maximumActive = 0
        var started = 0
    }
    static func begin() {
        state.lock.withLock {
            state.active += 1
            state.started += 1
            state.maximumActive = max(state.maximumActive, state.active)
        }
    }
    static func end() { state.lock.withLock { state.active -= 1 } }
    static var counts: (started: Int, active: Int, maximumActive: Int) {
        state.lock.withLock { (state.started, state.active, state.maximumActive) }
    }
}

private func memory() -> (current: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

private func cpuMilliseconds() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

private func pixels(width: Int, height: Int, identifier: Int) -> Data {
    var data = Data(count: width * height * 4)
    data.withUnsafeMutableBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let ink = y % 24 < 12 && x % 12 < 7 && (x / 12 + y / 24) % 5 != 0
                bytes[offset] = ink ? 32 : UInt8(truncatingIfNeeded: x + identifier * 7)
                bytes[offset + 1] = ink ? 32 : UInt8(truncatingIfNeeded: y)
                bytes[offset + 2] = ink ? 32 : UInt8(truncatingIfNeeded: x / 32 + y / 32)
                bytes[offset + 3] = 255
            }
        }
    }
    return data
}

private func makeImage(width: Int, height: Int, identifier: Int) -> CGImage {
    let provider = CGDataProvider(data: pixels(width: width, height: height, identifier: identifier) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

@main struct PNGEncodingProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let megapixels = Int(CommandLine.arguments[1]), [1, 8].contains(megapixels),
              let requests = Int(CommandLine.arguments[2]), [1, 3, 8].contains(requests) else {
            print("Usage: png-encoding-probe <megapixels: 1|8> <requests: 1|3|8>")
            exit(2)
        }
        let width = megapixels == 1 ? 1000 : 3200
        let height = megapixels == 1 ? 1000 : 2500
        let baseline = memory()
        let clock = ContinuousClock()
        var tasks: [Task<CapturedImage, any Error>] = []
        // Generate images inside the capture callback, so queued requests need
        // not allocate bitmaps. Timing includes synthetic bitmap generation.
        let cpuStart = cpuMilliseconds()
        let start = clock.now
        var latestStart = start
        for index in 0..<requests {
            if index > 0 {
                try await Task.sleep(for: .milliseconds(20))
                tasks.last?.cancel()
            }
            latestStart = clock.now
            tasks.append(Task.detached(priority: .userInitiated) {
                try await ScreenCapture.encodeForBenchmark {
                    autoreleasepool { makeImage(width: width, height: height, identifier: index) }
                }
            })
        }
        let result = try await tasks.last!.value
        let latestEnd = clock.now
        var cancelled = 0
        for task in tasks.dropLast() {
            do { _ = try await task.value }
            catch is CancellationError { cancelled += 1 }
        }
        let end = clock.now
        let cpuElapsed = cpuMilliseconds() - cpuStart
        let sample = memory()
        let counts = PNGProbeMetrics.counts
        precondition(counts.active == 0)

        // Validate lossless pixels after taking measurements; decoded buffers
        // must not contribute to the reported encoding peak or time.
        try validate(result, width: width, height: height, identifier: requests - 1)
        print(String(format: "pixels=%d requests=%d encoded=%d max_concurrent=%d cancelled=%d png_bytes=%d elapsed_ms=%.2f latest_ms=%.2f cpu_ms=%.2f baseline_MiB=%.2f current_MiB=%.2f peak_MiB=%.2f",
                     width * height, requests, counts.started, counts.maximumActive, cancelled,
                     result.data.count, milliseconds(start.duration(to: end)),
                     milliseconds(latestStart.duration(to: latestEnd)), cpuElapsed,
                     baseline.current, sample.current, sample.peak))
    }

    private static func validate(_ result: CapturedImage, width: Int, height: Int, identifier: Int) throws {
        precondition(result.mimeType == "image/png" && result.data.count <= 10 * 1_024 * 1_024)
        let source = CGImageSourceCreateWithData(result.data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width == width && image.height == height)
        var decoded = Data(count: width * height * 4)
        decoded.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        precondition(decoded == pixels(width: width, height: height, identifier: identifier))
    }
}
