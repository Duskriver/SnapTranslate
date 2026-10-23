import AppKit
import Carbon.HIToolbox
import Testing
@testable import SnapTranslate

@MainActor
@Suite(.serialized)
struct KeyboardShortcutTests {
    @Test func preferencesSurviveNewStoreAndInvalidDataFallsBack() throws {
        let suite = "SnapTranslate.shortcut-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        #expect(store.captureShortcut == .default)
        let custom = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(controlKey | cmdKey))
        store.captureShortcut = custom
        #expect(SettingsStore(defaults: defaults).captureShortcut == custom)
        defaults.set(Data("invalid json".utf8), forKey: "captureShortcut")
        #expect(store.captureShortcut == .default)
        let invalid = KeyboardShortcut(keyCode: UInt32.max, modifiers: UInt32(cmdKey))
        defaults.set(try JSONEncoder().encode(invalid), forKey: "captureShortcut")
        #expect(store.captureShortcut == .default)
        store.captureShortcut = custom
        store.captureShortcut = .default
        #expect(SettingsStore(defaults: defaults).captureShortcut == .default)
    }

    @Test func unsafeAndUnsupportedCombinationsAreRejected() {
        for modifiers in [UInt32(0), UInt32(shiftKey), UInt32(cmdKey | alphaLock)] {
            #expect(KeyboardShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: modifiers).validationMessage != nil)
        }
        for key in [kVK_Command, kVK_Shift, kVK_Escape, kVK_ANSI_Q, kVK_ANSI_Comma, kVK_ANSI_V] {
            #expect(KeyboardShortcut(keyCode: UInt32(key), modifiers: UInt32(cmdKey)).validationMessage != nil)
        }
        #expect(KeyboardShortcut.default.validationMessage == nil)
        #expect(KeyboardShortcut(keyCode: UInt32(kVK_F6), modifiers: UInt32(controlKey)).validationMessage == nil)
    }

    @Test func eventNormalizesIncidentalFlagsAndSpecialKeysHaveMenuEquivalents() throws {
        let event = try keyEvent(kVK_F6, flags: [.control, .option, .shift, .command, .capsLock, .function])
        let shortcut = KeyboardShortcut(event: event)
        #expect(shortcut.modifiers == UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(shortcut.displayName == "⌃⌥⇧⌘F6")
        #expect(shortcut.keyEquivalent == "\u{f709}")
        #expect(shortcut.modifierFlags == [.control, .option, .shift, .command])
    }

    @Test func conflictingRegistrationKeepsPreviousAndReplacementReleasesIt() throws {
        _ = NSApplication.shared
        let active = GlobalHotKey()
        let other = GlobalHotKey()
        defer { active.unregister(); other.unregister() }
        let first = KeyboardShortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
        let second = KeyboardShortcut(keyCode: UInt32(kVK_F19), modifiers: first.modifiers)
        try active.register(first)
        try active.register(first) // Re-saving an unchanged combination is harmless.
        try other.register(second)
        #expect(throws: (any Error).self) { try active.register(second) }
        #expect(active.registeredShortcut == first)
        // The old OS registration must still be held, not just its cached value.
        #expect(throws: (any Error).self) { try other.register(first) }
        other.unregister()
        try active.register(second)
        try other.register(first)
        #expect(active.registeredShortcut == second)
        active.unregister()
        try other.register(second)
    }

    @Test func recorderConsumesNewShortcutAndEscKeepsPreviousValue() throws {
        let (window, recorder) = makeRecorder()
        defer { recorder.stopRecording(); window.close() }
        var transitions: [Bool] = []
        var message: String?
        recorder.onRecordingChanged = { transitions.append($0) }
        recorder.onValidation = { message = $0 }
        recorder.performClick(nil)
        #expect(recorder.isRecording)
        #expect(recorder.handle(try keyEvent(kVK_ANSI_Y, flags: [], window: window)) == nil)
        #expect(message != nil)
        #expect(recorder.isRecording)
        #expect(recorder.shortcut == .default)
        #expect(recorder.handle(try keyEvent(kVK_ANSI_Y, flags: [.control, .option], window: window)) == nil)
        let recorded = recorder.shortcut
        #expect(recorded == KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(controlKey | optionKey)))
        #expect(!recorder.isRecording)
        #expect(message == nil)
        recorder.performClick(nil)
        #expect(recorder.handle(try keyEvent(kVK_Escape, flags: [], window: window)) == nil)
        #expect(!recorder.isRecording)
        #expect(recorder.shortcut == recorded)
        recorder.stopRecording()
        #expect(transitions == [true, false, true, false])
    }

    @Test func destroyingHotKeyReleasesSystemRegistration() throws {
        _ = NSApplication.shared
        let shortcut = KeyboardShortcut(keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
        weak var released: GlobalHotKey?
        try autoreleasepool {
            let hotKey = GlobalHotKey()
            released = hotKey
            try hotKey.register(shortcut)
            let competing = GlobalHotKey()
            defer { competing.unregister() }
            #expect(throws: (any Error).self) { try competing.register(shortcut) }
        }
        #expect(released == nil)
        let replacement = GlobalHotKey()
        defer { replacement.unregister() }
        try replacement.register(shortcut)
        #expect(replacement.registeredShortcut == shortcut)
    }

    @Test func detachingRecorderStopsRecording() throws {
        let (window, recorder) = makeRecorder()
        defer { recorder.stopRecording(); window.close() }
        var transitions: [Bool] = []
        recorder.onRecordingChanged = { transitions.append($0) }
        recorder.performClick(nil)
        #expect(recorder.isRecording)
        recorder.removeFromSuperview()
        #expect(!recorder.isRecording)
        #expect(transitions == [true, false])
        let event = try keyEvent(kVK_ANSI_Y, flags: [.control, .option], window: window)
        #expect(recorder.handle(event) === event)
        #expect(recorder.shortcut == .default)
    }

    @Test func droppingHotKeyOffMainReleasesRegistrationOnMain() async throws {
        _ = NSApplication.shared
        let shortcut = KeyboardShortcut(keyCode: UInt32(kVK_F15), modifiers: UInt32(controlKey | optionKey | cmdKey | shiftKey))
        try await Task.detached {
            var hotKey: GlobalHotKey? = try await MainActor.run {
                let hotKey = GlobalHotKey()
                try hotKey.register(shortcut)
                return hotKey
            }
            withExtendedLifetime(hotKey) {}
            hotKey = nil
        }.value
        // Drain the cleanup enqueued by the background last-reference release.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let replacement = GlobalHotKey()
        defer { replacement.unregister() }
        try replacement.register(shortcut)
        #expect(replacement.registeredShortcut == shortcut)
    }

    @Test func recorderStopsOnOutsideClickAndIgnoresKeyRepeats() throws {
        let (window, recorder) = makeRecorder()
        defer { recorder.stopRecording(); window.close() }
        recorder.performClick(nil)
        let repeated = try keyEvent(kVK_ANSI_Y, flags: [.option], window: window, isRepeat: true)
        #expect(recorder.handle(repeated) == nil)
        #expect(recorder.isRecording)
        #expect(recorder.shortcut == .default)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 250, y: 80),
                                                  modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(recorder.handle(click) === click)
        #expect(!recorder.isRecording)
        #expect(recorder.shortcut == .default)
    }

    private func makeRecorder() -> (NSWindow, ShortcutRecorder) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = ShortcutRecorder()
        recorder.frame = NSRect(x: 10, y: 10, width: 150, height: 32)
        window.contentView?.addSubview(recorder)
        return (window, recorder)
    }

    private func keyEvent(_ code: Int, flags: NSEvent.ModifierFlags, window: NSWindow? = nil,
                          isRepeat: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window?.windowNumber ?? 0, context: nil, characters: "",
                                     charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: UInt16(code)))
    }
}
