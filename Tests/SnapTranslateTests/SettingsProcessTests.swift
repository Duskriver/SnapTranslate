import AppKit
import Carbon.HIToolbox
import Testing
@testable import SnapTranslate

extension AppKitTests {
    @MainActor @Suite(.serialized)
    struct SettingsProcessTests {
        @Test(arguments: [false, true])
        func saveUsesParentStorageAndReportsFailureWithoutLosingShortcut(failSave: Bool) async throws {
            let fixture = try SettingsProcessFixture()
            defer { fixture.cleanup() }
            fixture.keys.failSave = failSave
            let candidate = KeyboardShortcut(keyCode: UInt32(kVK_F18), modifiers: fixture.store.captureShortcut.modifiers)
            let edit = SettingsEdit(shortcut: candidate, language: "English", replacementKey: "synthetic-key")
            let script = try """
            IFS= read -r line
            printf '%s\\n' \(quote(.recording(true))) \(quote(.recording(false))) \(quote(.save(edit)))
            IFS= read -r line
            case "$line" in *saveResult*) ;; *) exit 7;; esac
            printf '%s\\n' \(quote(.closed))
            """
            let process = WorkerProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
            let controller = SettingsProcessController(store: fixture.store, hotKey: fixture.hotKey) { process }
            var saved = 0, closed = 0
            controller.onSave = { saved += 1 }
            controller.onClose = { closed += 1 }
            controller.onError = { Issue.record(Comment(rawValue: $0)) }
            controller.present()
            await controller.waitForClose()
            #expect(saved == (failSave ? 0 : 1))
            #expect(closed == 1 && !process.isRunning)
            #expect(fixture.keys.reads == 0)
            #expect(fixture.keys.writes == ["synthetic-key"])
            #expect(fixture.store.targetLanguage == (failSave ? "简体中文" : "English"))
            #expect(fixture.hotKey.registeredShortcut == (failSave ? fixture.originalShortcut : candidate))
        }

        @Test(arguments: [false, true])
        func interruptedRecordingRestoresShortcutAndReapsChild(explicitClose: Bool) async throws {
            let fixture = try SettingsProcessFixture()
            defer { fixture.cleanup() }
            let script = try """
            IFS= read -r line
            printf '%s\\n' \(quote(.recording(true)))
            IFS= read -r line
            exit 9
            """
            let process = WorkerProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
            let controller = SettingsProcessController(store: fixture.store, hotKey: fixture.hotKey) { process }
            var closed = 0, failures = 0
            controller.onClose = { closed += 1 }
            controller.onError = { _ in failures += 1 }
            controller.present()
            try await workerEventually { fixture.hotKey.registeredShortcut == nil }
            if explicitClose { controller.close(); controller.close() }
            else { process.finishInput() }
            await controller.waitForClose()
            #expect(fixture.hotKey.registeredShortcut == fixture.originalShortcut)
            #expect(closed == 1 && !process.isRunning)
            #expect(failures == (explicitClose ? 0 : 1))
            #expect(fixture.keys.writes.isEmpty && fixture.keys.reads == 0)
        }

        @Test func launchFailureNotifiesAndClosesOwner() async throws {
            let fixture = try SettingsProcessFixture()
            defer { fixture.cleanup() }
            let controller = SettingsProcessController(store: fixture.store, hotKey: fixture.hotKey) {
                WorkerProcess(executable: URL(fileURLWithPath: "/nonexistent/settings-worker"), arguments: [])
            }
            var closed = 0, failures = 0
            controller.onClose = { closed += 1 }
            controller.onError = { _ in failures += 1 }
            controller.present()
            await controller.waitForClose()
            #expect(closed == 1 && failures == 1)
            #expect(fixture.hotKey.registeredShortcut == fixture.originalShortcut)
        }

        @Test func metadataFailureRejectsWorkerSave() async throws {
            let fixture = try SettingsProcessFixture()
            defer { fixture.cleanup() }
            fixture.keys.failMetadata = true
            let edit = SettingsEdit(shortcut: fixture.originalShortcut, language: "English", replacementKey: "")
            let script = try """
            IFS= read -r line
            printf '%s\\n' \(quote(.save(edit)))
            IFS= read -r line
            case "$line" in *saveResult*) ;; *) exit 7;; esac
            printf '%s\\n' \(quote(.closed))
            """
            let process = WorkerProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
            let controller = SettingsProcessController(store: fixture.store, hotKey: fixture.hotKey) { process }
            controller.onSave = { Issue.record("Failed metadata lookup must not permit Save") }
            controller.onError = { Issue.record(Comment(rawValue: $0)) }
            controller.present()
            await controller.waitForClose()
            #expect(fixture.keys.writes.isEmpty && fixture.keys.reads == 0)
            #expect(fixture.store.targetLanguage == "简体中文")
        }

        private func quote(_ event: SettingsWorker.Event) throws -> String {
            "'" + String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
                .replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
}

@MainActor private final class SettingsProcessFixture {
    let suite = "SnapTranslate.settings-process.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: SettingsStore
    let keys = SettingsProcessKeys()
    let hotKey = GlobalHotKey()
    let originalShortcut = KeyboardShortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        store = SettingsStore(defaults: defaults, keyStorage: keys)
        store.captureShortcut = originalShortcut
        try hotKey.register(originalShortcut)
    }
    func cleanup() { hotKey.unregister(); defaults.removePersistentDomain(forName: suite) }
}

@MainActor private final class SettingsProcessKeys: APIKeyStorage {
    var failSave = false, failMetadata = false
    var reads = 0
    var writes: [String] = []
    func containsKey() throws -> Bool {
        if failMetadata { throw CocoaError(.fileReadNoPermission) }
        return true
    }
    func loadKey() throws -> String { reads += 1; return "never-read" }
    func saveKey(_ value: String) throws {
        writes.append(value)
        if failSave { throw CocoaError(.fileWriteNoPermission) }
    }
}
