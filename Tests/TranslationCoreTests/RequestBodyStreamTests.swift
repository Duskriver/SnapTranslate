import Foundation
import Testing
@testable import TranslationCore

@Suite(.serialized)
struct RequestBodyStreamTests {
    @Test(arguments: [1, 7, 65_536])
    func shortReadsPreserveEnvelopeAndPadding(bufferSize: Int) throws {
        let storage = Data((0..<49_160).map { UInt8(truncatingIfNeeded: $0) })
        let body = try CompletionRequestBody(imageData: storage[7...], mimeType: "image/png", language: "中文")
        let stream = RequestBodyStream(body: body)
        #expect(stream.streamStatus == .notOpen)
        stream.open()
        var byte: UInt8 = 0
        #expect(stream.read(&byte, maxLength: 0) == 0)
        let data = drain(stream, bufferSize: bufferSize)
        #expect(data == body.prefix + body.imageData.base64EncodedData() + body.suffix)
        #expect(data.count == body.count)
        #expect(stream.streamStatus == .atEnd)
        #expect(!stream.hasBytesAvailable)
        #expect(stream.read(&byte, maxLength: 1) == 0)
        stream.close()
        stream.open()
        #expect(stream.streamStatus == .closed)
        #expect(stream.read(&byte, maxLength: 1) == -1)
    }

    @Test func replayStartsAtZeroAfterPartialAndCompleteReads() async throws {
        let body = try CompletionRequestBody(imageData: Data(repeating: 0xA5, count: 98_305),
                                             mimeType: "image/png", language: "中文")
        let first = RequestBodyStream(body: body)
        first.open()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        #expect(first.read(&buffer, maxLength: buffer.count) > 0)
        let delegate = RequestBodyDelegate(body: body)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://example.invalid")!)
        let expected = body.prefix + body.imageData.base64EncodedData() + body.suffix
        for _ in 0..<2 {
            let data: Data = await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: task) { replacement in
                    let replacement = replacement!
                    replacement.open()
                    let data = drain(replacement, bufferSize: 8_192)
                    replacement.close()
                    continuation.resume(returning: data)
                }
            }
            #expect(data == expected)
        }
        first.close()
    }

    @Test func scheduledConsumerCanReadReentrantlyAndUnschedule() throws {
        let body = try CompletionRequestBody(imageData: Data([1, 2, 3, 4]), mimeType: "image/png", language: "中文")
        let stream = RequestBodyStream(body: body)
        let consumer = Consumer()
        stream.delegate = consumer
        let runLoop = RunLoop.current
        stream.schedule(in: runLoop, forMode: .default)
        stream.open()
        stream.remove(from: runLoop, forMode: .default)
        _ = runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        #expect(consumer.events.isEmpty)
        stream.schedule(in: runLoop, forMode: .default)
        let deadline = Date(timeIntervalSinceNow: 2)
        while stream.streamStatus != .closed && Date() < deadline {
            _ = runLoop.run(mode: .default, before: deadline)
        }
        #expect(consumer.events.first == .openCompleted)
        #expect(consumer.events.last == .endEncountered)
        #expect(consumer.data == body.prefix + body.imageData.base64EncodedData() + body.suffix)
        #expect(stream.streamStatus == .closed)
        stream.delegate = nil
        #expect(stream.delegate === stream)
    }

    @Test func closingDuringReadTerminatesAndReleasesImage() async throws {
        let lifetime = Lifetime()
        weak var releasedStream: RequestBodyStream?
        do {
            let size = 2 * 1_024 * 1_024
            let pointer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            pointer.initializeMemory(as: UInt8.self, repeating: 0xA5, count: size)
            let image = Data(bytesNoCopy: pointer, count: size, deallocator: .custom { pointer, _ in
                pointer.deallocate()
                lifetime.markReleased()
            })
            let body = try CompletionRequestBody(imageData: image, mimeType: "image/png", language: "中文")
            let stream = RequestBodyStream(body: body)
            releasedStream = stream
            stream.open()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @Sendable [stream] in
                    var buffer = [UInt8](repeating: 0, count: 17)
                    while stream.read(&buffer, maxLength: buffer.count) > 0 {}
                }
                group.addTask { @Sendable [stream] in stream.close() }
            }
            #expect(stream.streamStatus == .closed)
        }
        #expect(releasedStream == nil)
        #expect(lifetime.wasReleased)
    }
}

private func drain(_ stream: InputStream, bufferSize: Int) -> Data {
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var data = Data()
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        #expect(count >= 0)
        if count <= 0 { return data }
        data.append(contentsOf: buffer.prefix(count))
    }
}

private final class Consumer: NSObject, StreamDelegate {
    var events: [Stream.Event] = []
    var data = Data()
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        events.append(eventCode)
        if eventCode == .hasBytesAvailable {
            var buffer = [UInt8](repeating: 0, count: 7)
            let count = (aStream as! InputStream).read(&buffer, maxLength: buffer.count)
            #expect(count >= 0)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
        } else if eventCode == .endEncountered {
            aStream.close()
        }
    }
}

private final class Lifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    var wasReleased: Bool { lock.withLock { released } }
    func markReleased() { lock.withLock { released = true } }
}
