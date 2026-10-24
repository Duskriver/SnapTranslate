import Foundation
import Testing
import TranslationCore
@testable import SnapTranslate

@Suite(.serialized)
struct TranslationWorkerTests {
    @Test func splitUTF8FramesAndTypedErrorsSurviveTransport() throws {
        for error in [TranslationError.unauthorized, .rejectedRequest(418), .incompleteStream] {
            let id = UUID()
            let data = try frames([.closed(id), .failure(id, .translation(error))])
            var decoder = WorkerEventDecoder()
            var events: [TranslationWorker.Event] = []
            for byte in data { events += try decoder.append(Data([byte])) }
            try decoder.finish()
            #expect(events.count == 2)
            guard case .closed(let restoredID) = events[0], case .failure(_, let failure) = events[1] else {
                Issue.record("Lost worker event"); return
            }
            #expect(restoredID == id)
            #expect((failure.error as? TranslationError) == error)
        }
        let failure = TranslationWorker.Failure(NSError(domain: "截图 👩‍💻", code: -3801,
                                                        userInfo: [NSLocalizedDescriptionKey: "denied\n你好"]))
        let data = try frames([.failure(nil, failure)])
        var decoder = WorkerEventDecoder()
        var restored: [TranslationWorker.Event] = []
        for byte in data { restored += try decoder.append(Data([byte])) }
        guard case .failure(_, let value) = restored.first else { Issue.record("Lost error"); return }
        #expect((value.error as NSError).domain == "截图 👩‍💻")
        #expect((value.error as NSError).localizedDescription == "denied\n你好")
    }

    @Test func rejectsTruncatedAndOversizedFramesButAllowsLongSessions() throws {
        var truncated = WorkerEventDecoder()
        _ = try truncated.append(Data(#"{"closed":"#.utf8))
        #expect(throws: TranslationError.incompleteStream) { try truncated.finish() }
        var oversized = WorkerEventDecoder()
        #expect(throws: TranslationError.outputTooLarge) {
            _ = try oversized.append(Data(repeating: 120, count: 256 * 1024 + 1))
        }
        var reusable = WorkerEventDecoder()
        let batch = try frames(Array(repeating: .failure(nil, .system(domain: "test", code: 1,
                                     message: String(repeating: "x", count: 8192))), count: 16))
        for _ in 0..<40 { #expect(try reusable.append(batch).count == 16) }
        try reusable.finish() // More than the old 4 MiB per-process cap.
    }

    @Test func duplexPipeAcceptsMoreFramesWithoutRestartingChild() async throws {
        let process = WorkerProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        let events = process.events()
        let ids = [UUID(), UUID(), UUID()]
        let task = Task { () throws -> [UUID] in
            var result: [UUID] = []
            for try await event in events {
                if case .closed(let id) = event { result.append(id) }
            }
            return result
        }
        for id in ids { try process.send(TranslationWorker.Event.closed(id)) }
        process.finishInput()
        #expect(try await task.value == ids)
        await process.waitForCompletion()
        #expect(!process.isRunning)
    }

    @Test func malformedOrTruncatedOutputStopsAndReapsChild() async throws {
        for value in ["not-json\n", "{\"idle\":{}"] {
            let process = WorkerProcess(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", value])
            do {
                for try await _ in process.events() { }
                Issue.record("Expected transport error")
            } catch { #expect(!(error is CancellationError)) }
            await process.waitForCompletion()
            #expect(!process.isRunning)
        }
    }

    @Test func launchFailureIsNotMisreportedAsCancellation() async throws {
        let process = WorkerProcess(executable: URL(fileURLWithPath: "/nonexistent/snaptranslate-worker"), arguments: [])
        do {
            for try await _ in process.events() { }
            Issue.record("Expected launch failure")
        } catch { #expect(!(error is CancellationError)) }
        await process.waitForCompletion()
    }

    @Test func cancellationTerminatesAndReapsChild() async throws {
        let process = WorkerProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let events = process.events()
        let task = Task { for try await _ in events { } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(process.isRunning)
        process.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await process.waitForCompletion()
        #expect(!process.isRunning)
    }

    @Test func cancelledQueuedJobDoesNotLaunch() async throws {
        let process = WorkerProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        process.cancel()
        await #expect(throws: CancellationError.self) { for try await _ in process.events() { } }
        await process.waitForCompletion()
        #expect(!process.isRunning)
    }

    private func frames(_ events: [TranslationWorker.Event]) throws -> Data {
        var data = Data()
        for event in events { data.append(try JSONEncoder().encode(event)); data.append(10) }
        return data
    }
}
