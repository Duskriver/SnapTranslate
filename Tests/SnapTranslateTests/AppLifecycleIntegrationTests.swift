import AppKit
import Carbon.HIToolbox
import Testing
import TranslationCore
@testable import SnapTranslate

/// Real AppDelegate, selection events, result controls and close callbacks. Only
/// capture/network completion and permission/credential boundaries are synthetic.
extension AppKitTests {
    @MainActor
    @Suite(.serialized)
    struct AppLifecycleIntegrationTests {
        @Test(arguments: [false, true])
        func replacementRejectsOldDeltasAndCompletion(failingOldRequest: Bool) async throws {
            let fixture = try LifecycleFixture()
            defer { fixture.cleanUp() }
            try fixture.selectRegion()
            let oldTask = try #require(fixture.app?.translationTask)
            try await fixture.probe.waitForCaptures(1)
            fixture.probe.captures[0].resolve(.success(testImage))
            try await fixture.probe.waitForTranslations(1)
            let old = fixture.probe.translations[0]
            await old.onDelta("old result")
            #expect(try fixture.resultText() == "old result")
            let oldPanel = WeakReference(fixture.app?.resultController)

            try fixture.beginSelection()
            #expect(oldTask.isCancelled)
            #expect(old.completion.cancellation.observed)
            // AppKit may defer release until this event returns; the operation stays suspended.
            try await eventually { oldPanel.value == nil }
            await old.onDelta("late while selecting")
            #expect(fixture.app?.resultController == nil)
            try fixture.finishSelection()
            let latestTask = try #require(fixture.app?.translationTask)
            try await fixture.probe.waitForCaptures(2)
            fixture.probe.captures[1].resolve(.success(testImage))
            try await fixture.probe.waitForTranslations(2)
            let latest = fixture.probe.translations[1]
            await latest.onDelta("new result")

            // Run the retained callback from a non-cancelled task, just like a UI
            // delivery that was already queued when the old request was cancelled.
            await old.onDelta("late after replacement")
            #expect(try fixture.resultText() == "new result")
            old.completion.resolve(failingOldRequest ? .failure(TranslationError.serverUnavailable) : .success(()))
            await oldTask.value
            #expect(try fixture.resultText() == "new result")
            #expect(try fixture.resultIsLoading())
            #expect(fixture.app?.translationTask != nil)

            // An old task's defer must not discard the handle needed to cancel its successor.
            fixture.app?.resultController?.dismiss()
            #expect(latestTask.isCancelled)
            #expect(latest.completion.cancellation.observed)
            await latest.onDelta("late after close")
            #expect(fixture.app?.resultController == nil)
            latest.completion.resolve(.success(()))
            await latestTask.value
            #expect(fixture.app?.translationTask == nil)
        }

        @Test(arguments: [false, true])
        func replacementDuringCaptureCannotStartAnOldUpload(failingOldCapture: Bool) async throws {
            let fixture = try LifecycleFixture()
            defer { fixture.cleanUp() }
            try fixture.selectRegion()
            let oldTask = try #require(fixture.app?.translationTask)
            try await fixture.probe.waitForCaptures(1)
            let old = fixture.probe.captures[0]

            try fixture.selectRegion()
            let latestTask = try #require(fixture.app?.translationTask)
            try await fixture.probe.waitForCaptures(2)
            #expect(old.cancellation.observed)
            fixture.probe.captures[1].resolve(.success(testImage))
            try await fixture.probe.waitForTranslations(1)
            let latest = fixture.probe.translations[0]
            await latest.onDelta("current translation")
            old.resolve(failingOldCapture ? .failure(CaptureError.encodingFailed) : .success(testImage))
            await oldTask.value
            #expect(fixture.probe.translations.count == 1)
            #expect(fixture.app?.translationTask != nil)
            #expect(try fixture.resultText() == "current translation")
            #expect(try fixture.resultIsLoading())

            latest.completion.resolve(.success(()))
            await latestTask.value
            #expect(fixture.app?.translationTask == nil)
            #expect(try !fixture.resultIsLoading())
            #expect(try fixture.resultLabels().contains("翻译完成"))
            await latest.onDelta("late after successful completion")
            #expect(try fixture.resultText() == "current translation")
        }

        @Test(arguments: ShutdownPhase.allCases)
        func terminationCancelsWorkAndRejectsLateDelivery(phase: ShutdownPhase) async throws {
            let fixture = try LifecycleFixture()
            defer { fixture.cleanUp() }
            try fixture.hotKey.register(fixture.store.captureShortcut)
            fixture.hotKey.onPress = { Issue.record("A terminated app must not handle hotkeys") }
            try fixture.beginSelection()
            if phase != .selecting { try fixture.finishSelection() }
            let task = fixture.app?.translationTask
            if phase == .capturing || phase == .streaming {
                try await fixture.probe.waitForCaptures(1)
            }
            if phase == .streaming {
                fixture.probe.captures[0].resolve(.success(testImage))
                try await fixture.probe.waitForTranslations(1)
                await fixture.probe.translations[0].onDelta("partial translation")
            }
            let panel = WeakReference(fixture.app?.resultController)
            let window = WeakReference(panel.value?.window)
            let content = WeakReference(window.value?.contentView)
            let app = WeakReference(fixture.app)

            // Invoke the real termination callback, without terminating the test process.
            fixture.terminate()
            fixture.terminate() // Teardown is idempotent.
            #expect(task == nil || task?.isCancelled == true)
            #expect(fixture.app?.translationTask == nil)
            #expect(fixture.app?.resultController == nil)
            #expect(window.value?.isVisible != true)
            #expect(!fixture.selector.isSelecting)
            #expect(fixture.hotKey.registeredShortcut == nil)
            #expect(fixture.hotKey.onPress == nil)
            if phase == .capturing { #expect(fixture.probe.captures[0].cancellation.observed) }
            if phase == .streaming { #expect(fixture.probe.translations[0].completion.cancellation.observed) }

            let keyReads = fixture.keys.reads
            fixture.app?.beginCapture()
            fixture.app?.showSettings()
            _ = fixture.app?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            #expect(fixture.keys.reads == keyReads)
            #expect(!fixture.selector.isSelecting)
            #expect(fixture.app?.settingsController == nil)
            if phase == .streaming {
                await fixture.probe.translations[0].onDelta("late after termination")
                #expect(fixture.app?.resultController == nil)
            }

            // UI ownership must end even if capture/encoding/network ignores cancellation.
            fixture.app = nil
            #expect(app.value == nil)
            try await eventually {
                panel.value == nil && window.value == nil && content.value == nil
                    && fixture.selectionWindows.allSatisfy { $0.value == nil }
            }
            fixture.probe.finishAll()
            await task?.value
            #expect(fixture.probe.translations.count == (phase == .streaming ? 1 : 0))
            if phase == .beforeTaskStarts { #expect(fixture.probe.captures.isEmpty) }

            // Prove that the OS registration, not just the Swift property, was removed.
            let replacement = GlobalHotKey()
            defer { replacement.unregister() }
            try replacement.register(fixture.store.captureShortcut)
        }
    }
}

enum ShutdownPhase: CaseIterable, Sendable {
    case selecting, beforeTaskStarts, capturing, streaming
}

private let testImage = CapturedImage(data: Data([1, 2, 3]), mimeType: "image/png")

@MainActor
private final class LifecycleFixture {
    let suite = "SnapTranslate.app-lifecycle.\(UUID().uuidString)"
    let defaults: UserDefaults
    let keys = LifecycleKeys()
    let store: SettingsStore
    // Other suites synthesize display changes on the default center. They must
    // not cancel a selection while this test deliberately delays an old callback.
    let selector = RegionSelector(notificationCenter: NotificationCenter())
    let hotKey = GlobalHotKey()
    let probe = PipelineProbe()
    var app: AppDelegate?
    var selectionWindows: [WeakReference<NSWindow>] = []

    init() throws {
        _ = NSApplication.shared
        defaults = try #require(UserDefaults(suiteName: suite))
        store = SettingsStore(defaults: defaults, keyStorage: keys)
        store.captureShortcut = KeyboardShortcut(
            keyCode: UInt32(kVK_F13), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey)
        )
        let probe = probe
        app = AppDelegate(
            settings: store, hotKey: hotKey, selector: selector,
            pipeline: TranslationPipeline(
                capture: { _ in try await probe.capture() },
                translate: { _, _, _, onDelta in try await probe.translate(onDelta: onDelta) }
            ),
            capturePermission: { true },
            makeResultPanel: {
                let panel = ResultPanelController()
                panel.window?.alphaValue = 0
                return panel
            }
        )
    }

    func beginSelection() throws {
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        app?.beginCapture()
        let windows = NSApp.windows.compactMap { $0 as? SelectionPanel }.filter { !previous.contains(ObjectIdentifier($0)) }
        for window in windows { window.alphaValue = 0 }
        selectionWindows = windows.map { WeakReference<NSWindow>($0) }
        try #require(selector.isSelecting && !windows.isEmpty)
    }

    func finishSelection() throws {
        let panel = try #require(selectionWindows.first?.value)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, NSPoint(x: 20, y: 20)),
                              (.leftMouseDragged, NSPoint(x: 100, y: 80)),
                              (.leftMouseUp, NSPoint(x: 100, y: 80))] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            panel.sendEvent(event)
        }
        try #require(!selector.isSelecting && app?.translationTask != nil)
    }

    func selectRegion() throws {
        try beginSelection()
        try finishSelection()
    }

    func resultText() throws -> String {
        let views = descendants(of: app?.resultController?.window?.contentView).compactMap { $0 as? NSTextView }
        return try #require(views.first).string
    }

    func resultIsLoading() throws -> Bool {
        let indicators = descendants(of: app?.resultController?.window?.contentView).compactMap { $0 as? NSProgressIndicator }
        return try !#require(indicators.first).isHidden
    }

    func resultLabels() throws -> [String] {
        descendants(of: try #require(app?.resultController?.window?.contentView)).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    func terminate() {
        app?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: NSApp))
    }

    func cleanUp() {
        terminate()
        probe.finishAll()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class PipelineProbe {
    private(set) var captures: [SuspendedOperation<CapturedImage>] = []
    private(set) var translations: [TranslationCall] = []

    func capture() async throws -> CapturedImage {
        let operation = SuspendedOperation<CapturedImage>()
        captures.append(operation)
        return try await operation.run()
    }

    func translate(onDelta: @escaping @Sendable (String) async -> Void) async throws {
        let call = TranslationCall(onDelta: onDelta)
        translations.append(call)
        try await call.completion.run()
    }

    func waitForCaptures(_ count: Int) async throws { try await eventually { self.captures.count == count } }
    func waitForTranslations(_ count: Int) async throws { try await eventually { self.translations.count == count } }

    func finishAll() {
        for operation in captures { operation.resolve(.success(testImage)) }
        for call in translations { call.completion.resolve(.failure(TranslationError.serverUnavailable)) }
    }
}

@MainActor
private struct TranslationCall {
    let onDelta: @Sendable (String) async -> Void
    let completion = SuspendedOperation<Void>()
}

/// Intentionally keeps working after cancellation until the test releases it.
@MainActor
private final class SuspendedOperation<Value: Sendable> {
    let cancellation = CancellationObservation()
    private var continuation: CheckedContinuation<Value, any Error>?

    func run() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: { [cancellation] in
            cancellation.record()
        }
    }

    func resolve(_ result: Result<Value, any Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

private final class CancellationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var observed: Bool { lock.withLock { cancelled } }
    func record() { lock.withLock { cancelled = true } }
}

@MainActor
private final class LifecycleKeys: APIKeyStorage {
    private(set) var reads = 0
    func containsKey() throws -> Bool { true }
    func loadKey() throws -> String { reads += 1; return "synthetic-lifecycle-key" }
    func saveKey(_ value: String) throws { Issue.record("Lifecycle tests must not change credentials") }
}

@MainActor
private final class WeakReference<Object: AnyObject> {
    weak var value: Object?
    init(_ object: Object?) { value = object }
}

@MainActor
private func descendants(of view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return view.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor
private func eventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
    try #require(predicate(), "Lifecycle transition did not complete before the deadline")
}
