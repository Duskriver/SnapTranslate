import Foundation
import Security

@MainActor
final class SettingsStore {
    private let defaults: UserDefaults
    private let keyStorage: any APIKeyStorage

    init(defaults: UserDefaults = .standard, keyStorage: (any APIKeyStorage)? = nil) {
        self.defaults = defaults
        self.keyStorage = keyStorage ?? SystemAPIKeyStorage()
    }

    var captureShortcut: KeyboardShortcut {
        get {
            guard let data = defaults.data(forKey: "captureShortcut"),
                  let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data),
                  shortcut.validationMessage == nil else { return .default }
            return shortcut
        }
        set {
            guard newValue.validationMessage == nil,
                  let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "captureShortcut")
        }
    }

    var targetLanguage: String {
        get { defaults.string(forKey: "targetLanguage") ?? "简体中文" }
        set { defaults.set(newValue, forKey: "targetLanguage") }
    }

    func hasAPIKey() throws -> Bool { try keyStorage.containsKey() }
    func loadAPIKey() throws -> String { try keyStorage.loadKey() }
    func saveAPIKey(_ value: String) throws { try keyStorage.saveKey(value) }
}

@MainActor
protocol APIKeyStorage {
    func containsKey() throws -> Bool
    func loadKey() throws -> String
    func saveKey(_ value: String) throws
}

@MainActor
private final class SystemAPIKeyStorage: APIKeyStorage {
    /// Inspect item metadata only. Launching the app or opening settings must
    /// not decrypt the saved credential or display an authorization dialog.
    func containsKey() throws -> Bool {
        var query = keyQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
    }

    func loadKey() throws -> String {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return value
    }

    func saveKey(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(keyQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let updateStatus = SecItemUpdate(keyQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = keyQuery
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrLabel as String] = "SnapTranslate · DeepSeek API Key"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            item[kSecAttrSynchronizable as String] = false
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    private var keyQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.local.SnapTranslate",
            kSecAttrAccount as String: "deepseek-api-key",
        ]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "错误代码 \(status)"
        return "无法访问钥匙串：\(detail)"
    }
}
