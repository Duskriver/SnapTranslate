import Foundation

struct SettingsState: Codable, Sendable {
    let shortcut: KeyboardShortcut
    let language: String
    let hasSavedKey: Bool?
    let error: String?
}

struct SettingsEdit: Codable, Sendable {
    let shortcut: KeyboardShortcut
    let language: String
    // nil preserves the existing secret; an empty string explicitly deletes it.
    let replacementKey: String?
}

@MainActor
protocol SettingsBackend: AnyObject {
    func load() -> SettingsState
    func setRecording(_ recording: Bool) throws
    func save(_ edit: SettingsEdit, completion: @escaping (String?) -> Void)
}

/// Credentials and the global shortcut stay owned by the menu-bar process.
@MainActor
final class SettingsCoordinator: SettingsBackend {
    private let store: SettingsStore
    private let hotKey: GlobalHotKey
    private(set) var isRecording = false

    init(store: SettingsStore, hotKey: GlobalHotKey) {
        self.store = store
        self.hotKey = hotKey
    }

    func load() -> SettingsState {
        do {
            return SettingsState(shortcut: store.captureShortcut, language: store.targetLanguage,
                                 hasSavedKey: try store.hasAPIKey(), error: nil)
        } catch {
            return SettingsState(shortcut: store.captureShortcut, language: store.targetLanguage,
                                 hasSavedKey: nil, error: error.localizedDescription)
        }
    }

    func setRecording(_ recording: Bool) throws {
        if recording {
            isRecording = true
            hotKey.unregister()
        } else {
            try hotKey.register(store.captureShortcut)
            isRecording = false
        }
    }

    func restoreShortcut() throws {
        if isRecording { try setRecording(false) }
    }

    func save(_ edit: SettingsEdit, completion: @escaping (String?) -> Void) {
        let previousShortcut = store.captureShortcut
        do {
            try hotKey.register(edit.shortcut)
            do {
                if let replacement = edit.replacementKey { try store.saveAPIKey(replacement) }
            } catch {
                let keychainError = error.localizedDescription
                do { try hotKey.register(previousShortcut) }
                catch { completion("\(keychainError)\n\(error.localizedDescription)"); return }
                completion(keychainError)
                return
            }
            store.captureShortcut = edit.shortcut
            store.targetLanguage = edit.language
            completion(nil)
        } catch { completion(error.localizedDescription) }
    }
}

@MainActor
protocol SettingsPresenting: AnyObject {
    var onSave: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var isClosing: Bool { get }
    func present()
    func close()
    func waitForClose() async
}

extension SettingsPresenting {
    var isClosing: Bool { false }
}
