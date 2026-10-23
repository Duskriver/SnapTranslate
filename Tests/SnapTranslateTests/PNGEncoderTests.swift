import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SnapTranslate

@Suite(.serialized)
struct PNGEncoderTests {
    @Test func pngPreservesDimensionsPixelsAndMIMEType() async throws {
        let image = makeImage(width: 17, height: 11)
        let result = try await PNGEncoder().encode(image)
        #expect(result.mimeType == "image/png")
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == image.width && decoded.height == image.height)
        var pixels = Data(count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo))
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        #expect(pixels == image.dataProvider?.data as Data?)
    }

    @Test func oversizedPNGStillReportsImageTooLarge() async {
        // Incompressible RGB exceeds 10 MiB even though the bitmap is below 8 MP.
        await #expect(throws: CaptureError.imageTooLarge) {
            try await PNGEncoder().encode(makeImage(width: 2048, height: 2048))
        }
    }

    @Test(arguments: [false, true])
    func finishedStoragePreservesAlphaColorProfileAndPaddedRows(wideGamut: Bool) async throws {
        let width = 17, height = 11, rowBytes = 17 * 4 + 16
        var bytes = Data(repeating: 0xCD, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                let alpha = UInt8((x % 4 + 1) * 63)
                bytes[offset] = alpha / 2
                bytes[offset + 1] = alpha / 3
                bytes[offset + 2] = alpha / 4
                bytes[offset + 3] = alpha
            }
        }
        let colorSpace = try #require(CGColorSpace(name: wideGamut ? CGColorSpace.displayP3 : CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: rowBytes, space: colorSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let reference = try autoreleasepool {
            let data = try #require(CFDataCreateMutable(nil, 0))
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let result = try await PNGEncoder().encode(image)
        // Identical PNG bytes also preserve metadata and ImageIO's exact alpha
        // conversion/rounding, rather than asserting a different rendering model.
        #expect(result.data == reference)
    }

    @Test func largePNGOutlivesBitmapAndSupportsDataCopyOnWrite() async throws {
        let lifetime = EncodingState()
        let result = try await PNGEncoder().captureAndEncode {
            makeImage(width: 1600, height: 1600, onRelease: { lifetime.released(1) })
        }
        await waitForRelease(lifetime, expected: [1])
        #expect(result.data.count > 8 * 1_024 * 1_024 && result.data.count <= 10 * 1_024 * 1_024)
        // Read after the worker's autorelease pool and source bitmap are gone.
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1600 && image.height == 1600)
        var copy = result.data
        let index = copy.count / 2
        let original = result.data[index]
        copy[index] ^= 0xFF
        #expect(result.data[index] == original)
        #expect(copy[index] != original)
        copy.append(0xA5)
        #expect(copy.count == result.data.count + 1)
        copy.removeAll(keepingCapacity: false)
        #expect(result.data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]))
    }

    @Test func alreadyCancelledRequestNeverEntersEncoder() async {
        let state = EncodingState()
        let encoder = PNGEncoder { image in state.encode(image) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await encoder.encode(makeImage(width: 1, onRelease: { state.released(1) }))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(state.snapshot.started.isEmpty)
        #expect(state.snapshot.released == [1])
    }

    @Test func cancellationReleasesQueuedImagesWhileRunningWorkKeepsItsSlot() async throws {
        let state = EncodingState()
        let (events, entered) = AsyncStream<Int>.makeStream()
        let unblock = DispatchSemaphore(value: 0)
        let encoder = PNGEncoder { image in
            state.begin(image.width)
            defer { state.end() }
            entered.yield(image.width)
            if image.width == 1 {
                // Timeout also makes a regression fail instead of deadlocking.
                #expect(unblock.wait(timeout: .now() + 5) == .success)
            }
            return CapturedImage(data: Data([UInt8(image.width)]), mimeType: "image/png")
        }
        defer { unblock.signal(); entered.finish() }
        var iterator = events.makeAsyncIterator()
        let first = Task { try await encoder.encode(makeImage(width: 1, onRelease: { state.released(1) })) }
        #expect(await iterator.next() == 1)
        first.cancel()
        #expect(state.snapshot.active == 1)
        #expect(!state.snapshot.released.contains(1))

        let (submitted, submission) = AsyncStream<Void>.makeStream()
        var submissions = submitted.makeAsyncIterator()
        let queued = Task {
            let image = makeImage(width: 2, onRelease: { state.released(2) })
            submission.yield(())
            return try await encoder.encode(image)
        }
        _ = await submissions.next()
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        submission.finish()
        #expect(state.snapshot.released.contains(2))
        #expect(state.snapshot.started == [1])

        let latest = Task { try await encoder.encode(makeImage(width: 3, onRelease: { state.released(3) })) }
        unblock.signal()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await latest.value.data == Data([3]))
        #expect(await iterator.next() == 3)
        #expect(state.snapshot.started == [1, 3])
        #expect(state.snapshot.maximumActive == 1)
        #expect(state.snapshot.active == 0)
        // Queue work may still be returning after the continuation is resumed.
        await waitForRelease(state, expected: [1, 2, 3])
    }

    @Test func cancelledWaitingCaptureNeverAllocatesABitmap() async throws {
        let state = EncodingState()
        let (events, entered) = AsyncStream<Void>.makeStream()
        let unblock = DispatchSemaphore(value: 0)
        let encoder = PNGEncoder { image in
            if image.width == 1 {
                entered.yield(())
                #expect(unblock.wait(timeout: .now() + 5) == .success)
            }
            return state.encode(image)
        }
        defer { unblock.signal(); entered.finish() }
        var iterator = events.makeAsyncIterator()
        let first = Task {
            try await encoder.captureAndEncode { makeImage(width: 1, onRelease: { state.released(1) }) }
        }
        _ = await iterator.next()
        first.cancel()
        let (submissions, submitted) = AsyncStream<Void>.makeStream()
        var submission = submissions.makeAsyncIterator()
        let queued = Task {
            submitted.yield(())
            return try await encoder.captureAndEncode {
                Issue.record("A cancelled waiting capture must not run")
                return makeImage(width: 2)
            }
        }
        _ = await submission.next()
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        submitted.finish()
        let latest = Task {
            try await encoder.captureAndEncode {
                // The previous bitmap must have been released before allocating another.
                #expect(state.snapshot.released.contains(1))
                return makeImage(width: 3, onRelease: { state.released(3) })
            }
        }
        unblock.signal()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await latest.value.data == Data([3]))
        #expect(state.snapshot.started == [1, 3])
        await waitForRelease(state, expected: [1, 3])
    }

    @Test func captureFailureReturnsSlotToNextRequest() async throws {
        let state = EncodingState()
        let encoder = PNGEncoder { image in state.encode(image) }
        await #expect(throws: CaptureError.missingDisplay) {
            try await encoder.captureAndEncode { throw CaptureError.missingDisplay }
        }
        #expect(state.snapshot.started.isEmpty)
        let result = try await encoder.captureAndEncode { makeImage(width: 1) }
        #expect(result.data == Data([1]))
        #expect(state.snapshot.started == [1])
    }

    @Test func concurrentRequestsAreSerialAndFailureDoesNotBlockLaterWork() async throws {
        let state = EncodingState()
        let encoder = PNGEncoder { image in
            state.begin(image.width)
            defer { state.end() }
            Thread.sleep(forTimeInterval: 0.002)
            if image.width == 7 { throw CaptureError.encodingFailed }
            return CapturedImage(data: Data([UInt8(image.width)]), mimeType: "image/png")
        }
        let tasks = (1...20).map { width in
            Task { try await encoder.encode(makeImage(width: width, onRelease: { state.released(width) })) }
        }
        for (index, task) in tasks.enumerated() {
            if index == 6 {
                await #expect(throws: CaptureError.encodingFailed) { try await task.value }
            } else {
                #expect(try await task.value.data == Data([UInt8(index + 1)]))
            }
        }
        #expect(state.snapshot.maximumActive == 1)
        #expect(state.snapshot.active == 0)
        #expect(Set(state.snapshot.started) == Set(1...20))
        await waitForRelease(state, expected: Set(1...20))
    }

    @Test func cancellationRacingCompletionResumesEachCallerOnce() async throws {
        let state = EncodingState()
        let encoder = PNGEncoder { image in state.encode(image) }
        for index in 1...200 {
            let task = Task { try await encoder.encode(makeImage(width: index, onRelease: { state.released(index) })) }
            DispatchQueue.global().async { task.cancel() }
            do { #expect(try await task.value.data == Data([UInt8(index)])) }
            catch is CancellationError { }
        }
        // A following encode is a barrier for previously cancelled queue entries.
        _ = try await encoder.encode(makeImage(width: 201, onRelease: { state.released(201) }))
        #expect(state.snapshot.maximumActive == 1)
        await waitForRelease(state, expected: Set(1...201))
    }

    @Test func cancellationRacingAdmissionDoesNotLoseOrDuplicateASlot() async throws {
        let state = EncodingState()
        let bitmaps = EncodingState()
        let encoder = PNGEncoder { image in state.encode(image) }
        let tasks = (1...200).map { index in
            let task = Task {
                try await encoder.captureAndEncode {
                    bitmaps.begin(index)
                    return makeImage(width: index, onRelease: { bitmaps.end() })
                }
            }
            if index % 2 == 0 { DispatchQueue.global().async { task.cancel() } }
            return task
        }
        for (index, task) in tasks.enumerated() {
            do { #expect(try await task.value.data == Data([UInt8(index + 1)])) }
            catch is CancellationError { #expect(index % 2 == 1) }
        }
        let result = try await encoder.captureAndEncode { makeImage(width: 201) }
        #expect(result.data == Data([201]))
        #expect(state.snapshot.maximumActive == 1)
        #expect(state.snapshot.active == 0)
        #expect(bitmaps.snapshot.maximumActive == 1)
        #expect(bitmaps.snapshot.active == 0)
    }

    private func waitForRelease(_ state: EncodingState, expected: Set<Int>) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while state.snapshot.released != expected && ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(state.snapshot.released == expected)
    }
}

private final class EncodingState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximumActive = 0
    private var started: [Int] = []
    private var releasedImages: Set<Int> = []
    var snapshot: (active: Int, maximumActive: Int, started: [Int], released: Set<Int>) {
        lock.withLock { (active, maximumActive, started, releasedImages) }
    }
    func begin(_ identifier: Int) {
        lock.withLock {
            active += 1
            maximumActive = max(maximumActive, active)
            started.append(identifier)
        }
    }
    func end() { lock.withLock { active -= 1 } }
    func released(_ identifier: Int) { _ = lock.withLock { releasedImages.insert(identifier) } }
    func encode(_ image: CGImage) -> CapturedImage {
        begin(image.width)
        defer { end() }
        return CapturedImage(data: Data([UInt8(image.width)]), mimeType: "image/png")
    }
}

private let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

private func makeImage(width: Int, height: Int = 1, onRelease: @escaping @Sendable () -> Void = {}) -> CGImage {
    final class Pixels {
        let bytes: UnsafeMutableRawPointer
        let onRelease: @Sendable () -> Void
        init(size: Int, onRelease: @escaping @Sendable () -> Void) {
            self.bytes = .allocate(byteCount: size, alignment: 4)
            self.onRelease = onRelease
            var random: UInt32 = 0x12345678
            let pixels = bytes.bindMemory(to: UInt8.self, capacity: size)
            for offset in stride(from: 0, to: size, by: 4) {
                for channel in 0..<3 {
                    random ^= random << 13
                    random ^= random >> 17
                    random ^= random << 5
                    pixels[offset + channel] = UInt8(truncatingIfNeeded: random)
                }
                pixels[offset + 3] = 255
            }
        }
        deinit { bytes.deallocate(); onRelease() }
    }
    let size = width * height * 4
    let pixels = Pixels(size: size, onRelease: onRelease)
    let provider = CGDataProvider(dataInfo: Unmanaged.passRetained(pixels).toOpaque(), data: pixels.bytes, size: size) { info, _, _ in
        Unmanaged<Pixels>.fromOpaque(info!).release()
    }!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}
