import AppKit
import Carbon.HIToolbox

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | shiftKey))
    private static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags
        modifiers = (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
            | (flags.contains(.command) ? UInt32(cmdKey) : 0)
    }

    var validationMessage: String? {
        guard modifiers & ~Self.supportedModifiers == 0,
              modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            return "请至少按住 ⌘、⌥ 或 ⌃ 中的一个，再按其他键。"
        }
        guard Self.keyNames[keyCode] != nil else { return "请选择字母、数字、标点、方向键或功能键；Esc 用于取消录制。" }
        if modifiers == UInt32(cmdKey), [kVK_ANSI_Q, kVK_ANSI_Comma, kVK_ANSI_Z, kVK_ANSI_X,
                                        kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_A].contains(Int(keyCode)) {
            return "这个组合用于应用菜单或文本编辑，请增加修饰键或换一个组合。"
        }
        return nil
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    var displayName: String {
        let prefix = (modifierFlags.contains(.control) ? "⌃" : "")
            + (modifierFlags.contains(.option) ? "⌥" : "")
            + (modifierFlags.contains(.shift) ? "⇧" : "")
            + (modifierFlags.contains(.command) ? "⌘" : "")
        return prefix + (Self.specialKeys[keyCode]?.name ?? printableCharacter?.uppercased() ?? Self.keyNames[keyCode] ?? "?")
    }

    var keyEquivalent: String {
        Self.specialKeys[keyCode]?.equivalent ?? printableCharacter?.lowercased() ?? Self.keyNames[keyCode]?.lowercased() ?? ""
    }

    // Use the keyboard layout rather than assuming that every keyboard is QWERTY.
    private var printableCharacter: String? {
        guard Self.keyNames[keyCode] != nil, Self.specialKeys[keyCode] == nil else { return nil }
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }

    private static let specialKeys: [UInt32: (name: String, equivalent: String)] = {
        var keys: [UInt32: (String, String)] = [
            UInt32(kVK_Space): ("Space", " "), UInt32(kVK_Return): ("↩", "\r"),
            UInt32(kVK_Tab): ("⇥", "\t"), UInt32(kVK_Delete): ("⌫", "\u{8}"),
            UInt32(kVK_ForwardDelete): ("⌦", "\u{f728}"),
            UInt32(kVK_LeftArrow): ("←", "\u{f702}"), UInt32(kVK_RightArrow): ("→", "\u{f703}"),
            UInt32(kVK_UpArrow): ("↑", "\u{f700}"), UInt32(kVK_DownArrow): ("↓", "\u{f701}"),
            UInt32(kVK_Home): ("↖", "\u{f729}"), UInt32(kVK_End): ("↘", "\u{f72b}"),
            UInt32(kVK_PageUp): ("⇞", "\u{f72c}"), UInt32(kVK_PageDown): ("⇟", "\u{f72d}"),
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functionKeys.enumerated() {
            keys[UInt32(code)] = ("F\(index + 1)", String(UnicodeScalar(0xf704 + index)!))
        }
        return keys
    }()

    private static let keyNames: [UInt32: String] = {
        var keys: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
            27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
            46: "M", 47: ".", 50: "`",
        ]
        for (code, key) in specialKeys { keys[code] = key.name }
        return keys
    }()
}
