import AppKit
import Carbon.HIToolbox

/// The system wakes us only when this registered combination is pressed.
@MainActor
final class GlobalHotKey {
    var onPress: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() throws {
        unregister()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                // Carbon dispatches application event handlers on the main thread.
                MainActor.assumeIsolated {
                    Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().onPress?()
                }
                return noErr
            },
            1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard handlerStatus == noErr else { throw RegistrationError(status: handlerStatus) }
        let identifier = EventHotKeyID(signature: 0x534E4150, id: 1) // SNAP
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_T), UInt32(optionKey | shiftKey), identifier,
            GetApplicationEventTarget(), 0, &hotKey
        )
        guard status == noErr else {
            unregister()
            throw RegistrationError(status: status)
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    private struct RegistrationError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "无法注册快捷键 ⌥⇧T（\(status)）。请检查其他应用是否占用了这个组合。仍可从菜单栏开始截图。"
        }
    }
}
