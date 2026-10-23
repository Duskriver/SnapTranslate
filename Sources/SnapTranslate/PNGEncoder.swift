import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One ImageIO encode at a time, off both the main actor and cooperative executor.
/// The shared encoder retains no images after its jobs complete or are cancelled.
struct PNGEncoder: Sendable {
    static let shared = PNGEncoder()

    private let queue = DispatchQueue(label: "com.local.SnapTranslate.png-encoding", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    private let admission = CaptureAdmission()
    private let encodeImage: @Sendable (CGImage) throws -> CapturedImage

    init(encodeImage: @escaping @Sendable (CGImage) throws -> CapturedImage = encodePNG) {
        self.encodeImage = encodeImage
    }

    /// Wait before allocating a screenshot bitmap, rather than queuing full images.
    /// The slot covers capture through the end of the synchronous ImageIO call.
    func captureAndEncode(_ capture: @Sendable () async throws -> CGImage) async throws -> CapturedImage {
        try await admission.acquire()
        let result: CapturedImage
        do {
            try Task.checkCancellation()
            let image = try await capture()
            result = try await encode(image)
        } catch {
            await admission.release()
            throw error
        }
        await admission.release()
        try Task.checkCancellation()
        return result
    }

    func encode(_ image: CGImage) async throws -> CapturedImage {
        try Task.checkCancellation()
        let job = Job(image: image)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard job.install(continuation) else { return }
                queue.async { [encodeImage] in
                    // A cancelled queued job has already released its image.
                    let result: Result<CapturedImage, any Error>? = autoreleasepool {
                        guard let image = job.takeImage() else { return nil }
                        return Result { try encodeImage(image) }
                    }
                    if let result { job.complete(result) }
                }
            }
        } onCancel: {
            job.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    static func encodePNG(_ image: CGImage) throws -> CapturedImage {
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodingFailed }
        guard CFDataGetLength(data) <= 10 * 1024 * 1024 else { throw CaptureError.imageTooLarge }
        return CapturedImage(data: data as Data, mimeType: "image/png")
    }

    // All mutable state is protected by lock; continuations resume outside it.
    // ImageIO is synchronous and cannot be interrupted. A running job keeps its
    // admission slot until ImageIO returns; cancellation discards that result.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        private var continuation: CheckedContinuation<CapturedImage, any Error>?
        private var isCancelled = false
        private var isRunning = false

        init(image: CGImage) { self.image = image }

        func install(_ continuation: CheckedContinuation<CapturedImage, any Error>) -> Bool {
            let installed = lock.withLock {
                guard !isCancelled else { return false }
                self.continuation = continuation
                return true
            }
            if !installed { continuation.resume(throwing: CancellationError()) }
            return installed
        }

        func takeImage() -> CGImage? {
            lock.withLock {
                guard let image else { return nil }
                isRunning = true
                self.image = nil
                return image
            }
        }

        func cancel() {
            let pending = lock.withLock {
                isCancelled = true
                image = nil
                guard !isRunning else { return nil as CheckedContinuation<CapturedImage, any Error>? }
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(throwing: CancellationError())
        }

        func complete(_ result: Result<CapturedImage, any Error>) {
            let (pending, cancelled) = lock.withLock {
                defer { continuation = nil }
                return (continuation, isCancelled)
            }
            pending?.resume(with: cancelled ? .failure(CancellationError()) : result)
        }
    }

    private actor CaptureAdmission {
        private var occupied = false
        private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

        func acquire() async throws {
            try Task.checkCancellation()
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if occupied {
                        waiters.append((id, continuation))
                    } else {
                        occupied = true
                        continuation.resume()
                    }
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
            // A grant can race cancellation; return the granted slot in that case.
            if Task.isCancelled {
                release()
                throw CancellationError()
            }
        }

        func release() {
            if waiters.isEmpty {
                occupied = false
            } else {
                waiters.removeFirst().continuation.resume()
            }
        }

        private func cancel(_ id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
}
