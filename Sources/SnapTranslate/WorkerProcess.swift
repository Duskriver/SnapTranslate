import Foundation
import Darwin
import TranslationCore

/// Blocking reads and writes use separate queues so stdin stays open for new
/// requests while stdout delivers window events. Every child is reaped at EOF.
final class WorkerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writer = DispatchQueue(label: "com.local.SnapTranslate.worker-input", qos: .userInitiated,
                                       autoreleaseFrequency: .workItem)
    private var cancelled = false
    private var started = false
    private var completed = false
    private var failure: (any Error)?
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(executable: URL, arguments: [String]) {
        // A child exiting during a write must become a transport error, not
        // terminate the menu-bar app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    var isRunning: Bool { lock.withLock { started && process.isRunning } }

    func cancel() {
        lock.withLock {
            cancelled = true
            if started, process.isRunning { process.terminate() }
        }
    }

    func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if completed { return true }
                completionWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func send<Value: Encodable>(_ value: Value) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count <= 16 * 1024 else { throw TranslationError.invalidResponse }
        data.append(10)
        let frame = data
        writer.async { [self] in
            guard lock.withLock({ started && !completed && !cancelled && failure == nil }) else { return }
            do { try input.fileHandleForWriting.write(contentsOf: frame) }
            catch {
                lock.withLock {
                    failure = error
                    if process.isRunning { process.terminate() }
                }
            }
        }
    }

    /// Also used by transport tests; production closes stdin when retiring.
    func finishInput() {
        writer.async { [self] in try? input.fileHandleForWriting.close() }
    }

    func events() -> AsyncThrowingStream<TranslationWorker.Event, any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.cancel() }
            }
            writer.async { [self] in
                do {
                    try lock.withLock {
                        guard !cancelled else { throw CancellationError() }
                        try process.run()
                        started = true
                    }
                    try output.fileHandleForWriting.close()
                    try input.fileHandleForReading.close()
                    DispatchQueue.global(qos: .userInitiated).async { [self] in readOutput(continuation) }
                } catch { finish(continuation, error: error) }
            }
        }
    }

    private func readOutput(_ continuation: AsyncThrowingStream<TranslationWorker.Event, any Error>.Continuation) {
        var error: (any Error)?
        do {
            var decoder = WorkerEventDecoder()
            while let data = try readWorkerChunk(output.fileHandleForReading, capacity: 16 * 1024) {
                for event in try decoder.append(data) { continuation.yield(event) }
            }
            try decoder.finish()
        } catch let readError { error = readError }
        if error != nil { lock.withLock { if process.isRunning { process.terminate() } } }
        process.waitUntilExit()
        let readError = error
        writer.async { [self] in
            let finalError = lock.withLock { () -> (any Error)? in
                if cancelled { return CancellationError() }
                return failure ?? readError ?? (process.terminationStatus == 0 ? nil : TranslationError.incompleteStream)
            }
            finish(continuation, error: finalError)
        }
    }

    private func finish(_ continuation: AsyncThrowingStream<TranslationWorker.Event, any Error>.Continuation,
                        error: (any Error)?) {
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let waiters = lock.withLock {
            completed = true
            defer { completionWaiters.removeAll() }
            return completionWaiters
        }
        for waiter in waiters { waiter.resume() }
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
}

/// FileHandle.read(upToCount:) can wait to fill the buffer on a pipe. Duplex
/// sessions need one POSIX read so small messages are delivered before EOF.
func readWorkerChunk(_ handle: FileHandle, capacity: Int) throws -> Data? {
    var data = Data(count: capacity)
    while true {
        let count = data.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, capacity) }
        if count == 0 { return nil }
        if count > 0 { data.removeSubrange(count...); return data }
        if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

typealias WorkerEventDecoder = WorkerLineDecoder<TranslationWorker.Event>

/// Limits apply per message, never over the lifetime of a reusable session.
struct WorkerLineDecoder<Value: Decodable> {
    private var pending = Data()
    private let limit: Int
    init(limit: Int = 256 * 1024) { self.limit = limit }
    mutating func append(_ data: Data) throws -> [Value] {
        pending.append(data)
        var values: [Value] = []
        while let newline = pending.firstIndex(of: 10) {
            guard newline - pending.startIndex <= limit else { throw TranslationError.outputTooLarge }
            values.append(try JSONDecoder().decode(Value.self, from: pending[..<newline]))
            pending.removeSubrange(...newline)
        }
        guard pending.count <= limit else { throw TranslationError.outputTooLarge }
        return values
    }
    func finish() throws {
        guard pending.isEmpty else { throw TranslationError.incompleteStream }
    }
}
