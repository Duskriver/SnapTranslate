import AppKit
import Carbon.HIToolbox
import Testing
@testable import SnapTranslate

extension AppKitTests {
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowLifecycleTests {
        @Test(arguments: ["cancel", "titleBar", "capture"])
        func closingReleasesWindowAndControls(route: String) async throws {
            _ = NSApplication.shared
            let suite = "SnapTranslate.settings-lifecycle.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            let hotKey = GlobalHotKey()
            defer { hotKey.unregister() }
            let owner = WindowOwner()
            var closeCount = 0
            weak var releasedController: SettingsWindowController?
            weak var releasedWindow: NSWindow?
            weak var releasedField: NSSecureTextField?
            weak var releasedRecorder: ShortcutRecorder?

            try autoreleasepool {
                let controller = SettingsWindowController(store: store, hotKey: hotKey)
                let window = try #require(controller.window)
                let field: NSSecureTextField = try find(in: window.contentView)
                let recorder: ShortcutRecorder = try find(in: window.contentView)
                owner.controller = controller
                releasedController = controller
                releasedWindow = window
                releasedField = field
                releasedRecorder = recorder
                controller.onSave = { Issue.record("Closing without Save must not persist edits") }
                controller.onClose = { [weak owner] in
                    closeCount += 1
                    owner?.controller = nil
                }

                // Exercise real AppKit close paths without reading the user's Keychain.
                window.alphaValue = 0
                controller.showWindow(nil)
                field.stringValue = "synthetic-test-key"
                switch route {
                case "cancel":
                    let cancel: NSButton = try find(in: window.contentView) { $0.title == "取消" }
                    cancel.performClick(nil)
                case "titleBar": window.performClose(nil)
                default: controller.close()
                }
                #expect(owner.controller == nil)
                #expect(field.stringValue.isEmpty)
                #expect(controller.onClose == nil)
                #expect(controller.onSave == nil)
                controller.close()
                #expect(closeCount == 1)
            }
            // AppKit may defer window cleanup until the current event has returned.
            try await Task.sleep(for: .milliseconds(30))
            #expect(releasedController == nil)
            #expect(releasedWindow == nil)
            #expect(releasedField == nil)
            #expect(releasedRecorder == nil)
        }

        @Test func closingWhileRecordingRestoresSavedShortcutBeforeRelease() throws {
            _ = NSApplication.shared
            let suite = "SnapTranslate.settings-recording.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SettingsStore(defaults: defaults)
            store.captureShortcut = KeyboardShortcut(
                keyCode: UInt32(kVK_F17), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey)
            )
            let hotKey = GlobalHotKey()
            defer { hotKey.unregister() }
            try hotKey.register(store.captureShortcut)
            let controller = SettingsWindowController(store: store, hotKey: hotKey)
            let recorder: ShortcutRecorder = try find(in: controller.window?.contentView)
            recorder.performClick(nil)
            #expect(recorder.isRecording)
            #expect(hotKey.registeredShortcut == nil)
            var closed = false
            controller.onClose = {
                #expect(!recorder.isRecording)
                #expect(hotKey.registeredShortcut == store.captureShortcut)
                closed = true
            }
            controller.close()
            #expect(closed)
            #expect(recorder.onRecordingChanged == nil)
            #expect(recorder.onValidation == nil)
        }

        @Test(arguments: ["keep", "replace", "delete", "undoDelete", "cancelDelete"])
        func settingsNeverReadSavedSecretAndOnlyWriteExplicitEdits(action: String) throws {
            _ = NSApplication.shared
            let suite = "SnapTranslate.settings-key.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let storage = KeyStorageSpy()
            let store = SettingsStore(defaults: defaults, keyStorage: storage)
            store.captureShortcut = KeyboardShortcut(keyCode: UInt32(kVK_F16), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
            let hotKey = GlobalHotKey()
            defer { hotKey.unregister() }
            let controller = SettingsWindowController(store: store, hotKey: hotKey)
            defer { controller.close() }
            controller.window?.alphaValue = 0
            controller.prepareForPresentation()
            let field: NSSecureTextField = try find(in: controller.window?.contentView)
            let language: NSPopUpButton = try find(in: controller.window?.contentView)
            #expect(storage.metadataChecks == 1)
            #expect(storage.secretReads == 0)
            #expect(field.stringValue.isEmpty)
            #expect(controller.window?.initialFirstResponder === language)
            language.selectItem(withTitle: "English")
            if action == "replace" { field.stringValue = "  synthetic-replacement-key  " }
            if ["delete", "undoDelete", "cancelDelete"].contains(action) {
                let button: NSButton = try find(in: controller.window?.contentView) { $0.title == "删除密钥" }
                button.performClick(nil)
                #expect(storage.writes.isEmpty) // Deletion is staged until Save.
                if action == "undoDelete" { button.performClick(nil) }
            }
            let button: NSButton = try find(in: controller.window?.contentView) {
                $0.title == (action == "cancelDelete" ? "取消" : "保存")
            }
            button.performClick(nil)
            #expect(storage.secretReads == 0)
            #expect(storage.writes == (action == "replace" ? ["synthetic-replacement-key"] : action == "delete" ? [""] : []))
            #expect(store.targetLanguage == (action == "cancelDelete" ? "简体中文" : "English"))
            #expect(field.stringValue.isEmpty)
        }

        @Test func missingKeyFocusesEntryAndMetadataFailureCannotOverwriteKey() throws {
            _ = NSApplication.shared
            let storage = KeyStorageSpy()
            storage.exists = false
            let controller = SettingsWindowController(store: SettingsStore(keyStorage: storage), hotKey: GlobalHotKey())
            defer { controller.close() }
            controller.window?.alphaValue = 0
            controller.prepareForPresentation()
            let field: NSSecureTextField = try find(in: controller.window?.contentView)
            #expect(controller.window?.initialFirstResponder === field)
            storage.failMetadata = true
            controller.prepareForPresentation()
            let save: NSButton = try find(in: controller.window?.contentView) { $0.title == "保存" }
            #expect(!save.isEnabled)
            field.stringValue = "must-not-overwrite"
            save.performClick(nil)
            #expect(storage.writes.isEmpty)
            #expect(storage.secretReads == 0)
        }

        private func find<T: NSView>(in root: NSView?, matching: (T) -> Bool = { _ in true }) throws -> T {
            func search(_ view: NSView) -> T? {
                if let match = view as? T, matching(match) { return match }
                for child in view.subviews {
                    if let match = search(child) { return match }
                }
                return nil
            }
            let match = root.flatMap(search)
            return try #require(match)
        }
    }
}

@MainActor
private final class WindowOwner {
    var controller: SettingsWindowController?
}

@MainActor
private final class KeyStorageSpy: APIKeyStorage {
    var exists = true
    var failMetadata = false
    var metadataChecks = 0
    var secretReads = 0
    var writes: [String] = []

    func containsKey() throws -> Bool {
        metadataChecks += 1
        if failMetadata { throw CocoaError(.fileReadNoPermission) }
        return exists
    }
    func loadKey() throws -> String {
        secretReads += 1
        Issue.record("Opening settings must not read the saved secret")
        return "synthetic-saved-secret"
    }
    func saveKey(_ value: String) throws { writes.append(value) }
}
