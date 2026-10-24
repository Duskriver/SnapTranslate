import AppKit
import Testing
import TranslationCore
@testable import SnapTranslate

extension AppKitTests {
    @MainActor @Suite(.serialized)
    struct WorkerWindowServerTests {
        init() { _ = NSApplication.shared }

        @Test func retainedWorkerMenuReceivesUpdatedShortcut() throws {
            let original = NSApp.mainMenu
            defer { NSApp.mainMenu = original }
            let server = WorkerWindowServer(emit: { _ in })
            server.installMenu()
            let item = try #require(NSApp.mainMenu?.items.first?.submenu?.items.first)
            let shortcut = KeyboardShortcut(keyCode: 16, modifiers: 256 | 2048)
            server.updateShortcut(shortcut)
            #expect(item.keyEquivalent == shortcut.keyEquivalent)
            #expect(item.keyEquivalentModifierMask == shortcut.modifierFlags)
            server.updateShortcut(KeyboardShortcut(keyCode: 16, modifiers: 0))
            #expect(item.keyEquivalentModifierMask == shortcut.modifierFlags)
        }

        @Test func windowsKeepSeparateTextAndClosingOnlyOnePreservesTheOthers() async throws {
            var events: [TranslationWorker.Event] = []
            let server = WorkerWindowServer(emit: { events.append($0) }) { request, _, onDelta in
                await onDelta(request.language)
            }
            defer { for id in Array(server.presentations.keys) { server.close(id) } }
            let requests = try (1...3).map { try request("result \($0)") }
            for item in requests { server.open(item); server.presentations[item.id]?.panel.window?.alphaValue = 0 }
            try await workerEventually { server.presentations.values.allSatisfy(\.completed) }
            #expect(server.presentations.count == 3)
            let origins = server.presentations.values.compactMap { $0.panel.window?.frame.origin }
            #expect(Set(origins.map { "\($0.x),\($0.y)" }).count == 3)
            for item in requests {
                let presentation = try #require(server.presentations[item.id])
                #expect(text(presentation.panel) == item.language)
                #expect(presentation.panel.window?.isVisible == true)
            }
            weak var released = server.presentations[requests[1].id]
            weak var releasedWindow = released?.panel.window
            releasedWindow?.performClose(nil) // The native title-bar close path.
            try await workerEventually { released == nil && releasedWindow == nil }
            #expect(server.presentations.count == 2)
            #expect(!events.contains { if case .idle = $0 { true } else { false } })
            #expect(text(try #require(server.presentations[requests[0].id]).panel) == "result 1")
            server.presentations[requests[0].id]?.panel.dismiss() // Esc uses this path.
            #expect(server.presentations.count == 1)
            server.close(requests[2].id)
            #expect(server.presentations.isEmpty)
            #expect(events.filter { if case .closed = $0 { true } else { false } }.count == 3)
            #expect(events.filter { if case .idle = $0 { true } else { false } }.count == 1)
        }

        @Test func queuedAndRunningCancellationStayIndependentAndBoundConcurrency() async throws {
            let probe = WorkerOperations()
            let admission = WorkerNetworkAdmission()
            let server = WorkerWindowServer(emit: { _ in }) { request, _, onDelta in
                probe.captured.append(request.id)
                try await admission.acquire()
                do { try await probe.run(request.id, onDelta: onDelta) }
                catch { await admission.release(); throw error }
                await admission.release()
            }
            let requests = try (1...4).map { try request("result \($0)") }
            defer { for item in requests { server.close(item.id) }; probe.finishAll() }
            for item in requests { server.open(item); server.presentations[item.id]?.panel.window?.alphaValue = 0 }
            try await workerEventually { probe.started.count == 2 && probe.captured.count == 4 }
            let first = try #require(server.presentations[requests[0].id])
            weak var removed = server.presentations[requests[2].id]
            weak var removedPanel = removed?.panel
            let queuedTask = removed?.operation
            server.close(requests[2].id) // Already captured, but queued upload never starts.
            #expect(removed == nil)
            await queuedTask?.value
            try await workerEventually { removedPanel == nil }
            let task = try #require(first.operation)
            server.close(requests[0].id)
            #expect(task.isCancelled)
            #expect(probe.started.count == 2) // A cancellation-ignoring operation still owns its slot.
            probe.finish(requests[0].id)
            await task.value
            try await workerEventually { probe.started.count == 3 }
            #expect(!probe.started.contains(requests[2].id))
            #expect(probe.started.contains(requests[3].id))
            #expect(probe.maximumActive == 2)
            probe.finish(requests[1].id)
            probe.finish(requests[3].id)
            try await workerEventually { server.presentations.values.allSatisfy(\.completed) }
            #expect(server.presentations.count == 2)
            #expect(text(try #require(server.presentations[requests[1].id]).panel) == requests[1].id.uuidString)
        }

        @Test func failedWindowDoesNotStopAnotherRequestAndReleasesItsQueueSlot() async throws {
            let bad = try request("bad")
            let good = try request("good")
            let server = WorkerWindowServer(emit: { _ in }) { request, _, onDelta in
                if request.id == bad.id { throw TranslationError.unauthorized }
                await onDelta("success")
            }
            defer { for id in Array(server.presentations.keys) { server.close(id) } }
            server.open(bad); server.open(good)
            for value in server.presentations.values { value.panel.window?.alphaValue = 0 }
            try await workerEventually { server.presentations[good.id]?.completed == true }
            #expect(text(try #require(server.presentations[good.id]).panel) == "success")
            #expect(text(try #require(server.presentations[bad.id]).panel) == TranslationError.unauthorized.localizedDescription)
        }

        private func request(_ language: String) throws -> TranslationWorker.Request {
            let screen = try #require(NSScreen.screens.first)
            let number = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            return .init(rect: CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 300, width: 200, height: 100),
                         displayID: number.uint32Value, parentPID: getpid(), apiKey: "public-test-placeholder", language: language)
        }
        private func text(_ panel: ResultPanelController) -> String {
            func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
            return panel.window?.contentView.flatMap { descendants($0).compactMap { $0 as? NSTextView }.first?.string } ?? ""
        }
    }
}

@MainActor
private final class WorkerOperations {
    var captured: [UUID] = []
    var started: [UUID] = []
    var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var maximumActive = 0
    func run(_ id: UUID, onDelta: @escaping @Sendable (String) async -> Void) async throws {
        started.append(id)
        try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            maximumActive = max(maximumActive, continuations.count)
        }
        await onDelta(id.uuidString)
    }
    func finish(_ id: UUID) { continuations.removeValue(forKey: id)?.resume() }
    func finishAll() { let values = continuations; continuations.removeAll(); for value in values.values { value.resume() } }
}

@MainActor
func workerEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition())
}
