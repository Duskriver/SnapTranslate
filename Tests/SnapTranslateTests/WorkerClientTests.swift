import Foundation
import Testing
import TranslationCore
@testable import SnapTranslate

extension AppKitTests {
    @MainActor @Suite(.serialized)
    struct WorkerClientTests {
        @Test func twoRequestsShareChildAndCancellingOneDoesNotCancelTheOther() async throws {
            let first = request(), second = request()
            let script = try """
            IFS= read -r line
            printf '%s\\n' \(quoted(.action(first.id, .settings)))
            IFS= read -r line
            printf '%s\\n' \(quoted(.action(first.id, .capture)))
            IFS= read -r line
            printf '%s\\n' \(quoted(.closed(second.id))) \(quoted(.action(first.id, .settings)))
            IFS= read -r line
            printf '%s\\n' \(quoted(.closed(first.id))) \(quoted(.idle))
            IFS= read -r line
            case "$line" in *shutdown*) exit 0;; *) exit 7;; esac
            """
            let process = WorkerProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
            defer { process.cancel() }
            var launches = 0
            var actions: [TranslationWorker.Action] = []
            let client = WorkerClient { launches += 1; return process }
            let delivery = TranslationDelivery(onDelta: { _ in }, onAction: { action in
                await MainActor.run { actions.append(action) }
            })
            let task1 = Task { try await client.translate(first, delivery: delivery) }
            try await workerEventually { actions.count == 1 }
            let task2 = Task { try await client.translate(second, delivery: delivery) }
            try await workerEventually { actions.count == 2 }
            #expect(launches == 1)
            task2.cancel()
            await #expect(throws: CancellationError.self) { try await task2.value }
            try await workerEventually { actions.count == 3 }
            #expect(!task1.isCancelled && process.isRunning)
            task1.cancel()
            await #expect(throws: CancellationError.self) { try await task1.value }
            await process.waitForCompletion()
            #expect(!process.isRunning)
        }

        @Test func requestDuringLastWindowShutdownWaitsForOldChildToBeReaped() async throws {
            let first = request(), second = request()
            let script1 = try closingScript(first.id, delay: "0.2")
            let script2 = try closingScript(second.id, delay: "0")
            let process1 = WorkerProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script1])
            let process2 = WorkerProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script2])
            defer { process1.cancel(); process2.cancel() }
            var launches = 0
            let client = WorkerClient {
                launches += 1
                if launches == 2 { #expect(!process1.isRunning) }
                return launches == 1 ? process1 : process2
            }
            let delivery = TranslationDelivery(onDelta: { _ in }, onAction: { _ in })
            try await client.translate(first, delivery: delivery)
            try await workerEventually { client.isRetiring }
            #expect(process1.isRunning)
            try await client.translate(second, delivery: delivery)
            await process2.waitForCompletion()
            #expect(launches == 2)
            #expect(!process1.isRunning && !process2.isRunning)
        }

        @Test func failedLaunchResumesEveryPendingRequest() async throws {
            let client = WorkerClient {
                WorkerProcess(executable: URL(fileURLWithPath: "/nonexistent/snaptranslate-worker"), arguments: [])
            }
            let delivery = TranslationDelivery(onDelta: { _ in }, onAction: { _ in })
            let first = Task { try await client.translate(request(), delivery: delivery) }
            let second = Task { try await client.translate(request(), delivery: delivery) }
            for task in [first, second] {
                do { try await task.value; Issue.record("Expected launch failure") }
                catch { #expect(!(error is CancellationError)) }
            }
        }

        @Test func captureAndRecoveryCallbacksArriveBeforeTheirRequestFinishes() async throws {
            let item = request()
            let script = try """
            IFS= read -r line
            printf '%s\\n' \(quoted(.captured(item.id))) \(quoted(.action(item.id, .screenRecordingSettings))) \(quoted(.closed(item.id))) \(quoted(.idle))
            IFS= read -r line
            case "$line" in *shutdown*) exit 0;; *) exit 7;; esac
            """
            let process = WorkerProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
            defer { process.cancel() }
            let client = WorkerClient { process }
            var actions: [TranslationWorker.Action] = []
            var captures = 0
            let delivery = TranslationDelivery(onDelta: { _ in }, onAction: { action in
                try? await Task.sleep(for: .milliseconds(10))
                await MainActor.run { #expect(captures == 1); actions.append(action) }
            }, onCaptureComplete: {
                await MainActor.run { captures += 1 }
            })
            try await client.translate(item, delivery: delivery)
            #expect(actions == [.screenRecordingSettings])
            await process.waitForCompletion()
        }

        private func request() -> TranslationWorker.Request {
            .init(rect: .zero, displayID: 0, parentPID: getpid(), apiKey: "public-test-placeholder", language: "中文")
        }
        private func quoted(_ event: TranslationWorker.Event) throws -> String {
            "'" + String(decoding: try JSONEncoder().encode(event), as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        private func closingScript(_ id: UUID, delay: String) throws -> String {
            try """
            IFS= read -r line
            printf '%s\\n' \(quoted(.closed(id))) \(quoted(.idle))
            IFS= read -r line
            case "$line" in *shutdown*) sleep \(delay); exit 0;; *) exit 7;; esac
            """
        }
    }
}
