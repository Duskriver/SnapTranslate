import AppKit
import Carbon.HIToolbox

/// The system wakes us only when this registered combination is pressed.
@MainActor
final class GlobalHotKey {
    var onPress: (() -> Void)?
    private let resources = HotKeyResources()
    private var identifier = EventHotKeyID(signature: 0x534E4150, id: UInt32.random(in: 1...UInt32.max))
    private(set) var registeredShortcut: KeyboardShortcut?

    func register(_ shortcut: KeyboardShortcut) throws {
        if let message = shortcut.validationMessage { throw ValidationError(message: message) }
        if resources.hotKey != nil, registeredShortcut == shortcut { return }
        if resources.handler == nil { try installHandler(for: shortcut) }
        var replacement: EventHotKeyRef?
        let nextID = EventHotKeyID(signature: identifier.signature, id: identifier.id &+ 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, nextID,
            GetApplicationEventTarget(), 0, &replacement
        )
        guard status == noErr else {
            if resources.hotKey == nil { unregister() }
            throw RegistrationError(shortcut: shortcut, status: status)
        }
        // Keep the previous registration alive until its replacement succeeds.
        if let hotKey = resources.hotKey { UnregisterEventHotKey(hotKey) }
        resources.hotKey = replacement
        identifier = nextID
        registeredShortcut = shortcut
    }

    private func installHandler(for shortcut: KeyboardShortcut) throws {
        resources.context.owner = self
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var eventID = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &eventID) == noErr else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon dispatches application event handlers on the main thread.
                return MainActor.assumeIsolated {
                    let context = Unmanaged<HotKeyContext>.fromOpaque(context).takeUnretainedValue()
                    guard let owner = context.owner, owner.resources.hotKey != nil,
                          eventID.signature == owner.identifier.signature,
                          eventID.id == owner.identifier.id else { return OSStatus(eventNotHandledErr) }
                    owner.onPress?()
                    return noErr
                }
            },
            1, &event, Unmanaged.passUnretained(resources.context).toOpaque(), &resources.handler
        )
        guard handlerStatus == noErr else {
            throw RegistrationError(shortcut: shortcut, status: handlerStatus)
        }
    }

    func unregister() {
        resources.invalidate()
        registeredShortcut = nil
    }

    private struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct RegistrationError: LocalizedError {
        let shortcut: KeyboardShortcut
        let status: OSStatus
        var errorDescription: String? {
            "无法注册快捷键 \(shortcut.displayName)（\(status)），可能已被占用。请换一个组合；仍可从菜单栏开始截图。"
        }
    }
}

@MainActor
private final class HotKeyContext {
    weak var owner: GlobalHotKey?
}

/// Only GlobalHotKey accesses these handles, on the main actor. The last owner
/// may be released on another thread, so deinit transfers cleanup to main.
private final class HotKeyResources {
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    let context: HotKeyContext

    @MainActor init() { context = HotKeyContext() }

    @MainActor func invalidate() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        context.owner = nil
    }

    deinit {
        guard hotKey != nil || handler != nil else { return }
        // Transfer opaque handle identities rather than non-Sendable pointers.
        let hotKeyAddress = hotKey.map { UInt(bitPattern: $0) }
        let handlerAddress = handler.map { UInt(bitPattern: $0) }
        let context = context
        let cleanup: @Sendable () -> Void = {
            if let address = hotKeyAddress { UnregisterEventHotKey(EventHotKeyRef(bitPattern: address)) }
            if let address = handlerAddress { RemoveEventHandler(EventHandlerRef(bitPattern: address)) }
            // Carbon can still call the weak context until handler removal.
            withExtendedLifetime(context) {}
        }
        if Thread.isMainThread { cleanup() }
        else { DispatchQueue.main.async(execute: cleanup) }
    }
}
