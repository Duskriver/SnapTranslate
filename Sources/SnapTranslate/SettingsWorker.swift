import AppKit
import Darwin

enum SettingsWorker {
    static let argument = "--settings-worker"

    enum Command: Codable, Sendable {
        case present(SettingsState), saveResult(String?), error(String)
    }
    enum Event: Codable, Sendable {
        case recording(Bool), save(SettingsEdit), closed, capture, quit
    }

    @MainActor static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let parentExit = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .global())
        parentExit.setEventHandler { exit(0) }
        parentExit.resume()
        let server = SettingsWindowServer()
        application.delegate = server
        server.installMenu()
        Task { @MainActor in
            do {
                for try await command in commands() { server.handle(command) }
            } catch { }
            exit(0)
        }
        withExtendedLifetime((server, parentExit)) { application.run() }
        exit(0)
    }

    private static func commands() -> AsyncThrowingStream<Command, any Error> {
        AsyncThrowingStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var decoder = WorkerLineDecoder<Command>(limit: 16 * 1024)
                    while let data = try readWorkerChunk(.standardInput, capacity: 4096) {
                        for command in try decoder.append(data) { continuation.yield(command) }
                    }
                    try decoder.finish()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    @MainActor static func emit(_ event: Event) {
        do {
            var data = try JSONEncoder().encode(event)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch { exit(1) }
    }
}

/// This process owns only native controls, never the stored credential or hotkey.
@MainActor
final class SettingsWindowServer: NSObject, NSApplicationDelegate, SettingsBackend {
    private var state: SettingsState?
    private var controller: SettingsWindowController?
    private var saveCompletion: ((String?) -> Void)?
    private var captureMenuItem: NSMenuItem?

    func handle(_ command: SettingsWorker.Command) {
        switch command {
        case .present(let state):
            captureMenuItem?.keyEquivalent = state.shortcut.keyEquivalent
            captureMenuItem?.keyEquivalentModifierMask = state.shortcut.modifierFlags
            // An already-open window keeps its uncommitted edits.
            if let controller {
                NSApp.activate(ignoringOtherApps: true)
                controller.window?.makeKeyAndOrderFront(nil)
                return
            }
            self.state = state
            let controller = SettingsWindowController(backend: self)
            controller.onClose = {
                SettingsWorker.emit(.closed)
                exit(0)
            }
            self.controller = controller
            controller.present()
        case .saveResult(let error):
            let completion = saveCompletion
            saveCompletion = nil
            completion?(error)
        case .error(let error): controller?.showError(error)
        }
    }

    func load() -> SettingsState { state! }
    func setRecording(_ recording: Bool) throws { SettingsWorker.emit(.recording(recording)) }
    func save(_ edit: SettingsEdit, completion: @escaping (String?) -> Void) {
        guard saveCompletion == nil else { return }
        saveCompletion = completion
        SettingsWorker.emit(.save(edit))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.window?.makeKeyAndOrderFront(nil)
        return false
    }

    func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        let capture = NSMenuItem(title: "截屏翻译", action: #selector(captureAgain), keyEquivalent: "")
        capture.target = self
        captureMenuItem = capture
        appMenu.addItem(capture)
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 SnapTranslate", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        app.submenu = appMenu
        menu.addItem(app)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a"),
        ] { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    @objc private func quitApplication() { SettingsWorker.emit(.quit) }
    @objc private func captureAgain() { SettingsWorker.emit(.capture) }
    @objc private func showSettings() { controller?.window?.makeKeyAndOrderFront(nil) }
}

@MainActor
final class SettingsProcessController: SettingsPresenting {
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    var onQuit: (() -> Void)?
    var onCapture: (() -> Void)?
    private(set) var isClosing = false
    private let coordinator: SettingsCoordinator
    private let makeProcess: () throws -> WorkerProcess
    private var process: WorkerProcess?
    private var listener: Task<Void, Never>?
    private var keyStatusLoaded = false

    init(store: SettingsStore, hotKey: GlobalHotKey,
         makeProcess: @escaping () throws -> WorkerProcess = {
             guard let executable = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
             return WorkerProcess(executable: executable, arguments: [SettingsWorker.argument])
         }) {
        coordinator = SettingsCoordinator(store: store, hotKey: hotKey)
        self.makeProcess = makeProcess
    }

    func present() {
        guard !isClosing else { return }
        let state = coordinator.load()
        if process == nil {
            do {
                let process = try makeProcess()
                let events = process.events(of: SettingsWorker.Event.self)
                self.process = process
                keyStatusLoaded = state.hasSavedKey != nil
                listener = Task { [self] in
                    var failure: (any Error)?
                    do {
                        for try await event in events {
                            guard !isClosing else { continue }
                            handle(event)
                        }
                    } catch { failure = error }
                    await process.waitForCompletion()
                    do { try coordinator.restoreShortcut() }
                    catch { onError?(error.localizedDescription) }
                    if !isClosing {
                        onError?((failure ?? CocoaError(.xpcConnectionInterrupted)).localizedDescription)
                    }
                    isClosing = true
                    let callback = onClose
                    onClose = nil
                    onSave = nil
                    onQuit = nil
                    onCapture = nil
                    onError = nil
                    callback?()
                    listener = nil
                }
            } catch {
                onError?(error.localizedDescription)
                isClosing = true
                onClose?()
                return
            }
        }
        send(.present(state))
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        process?.cancel()
    }

    func waitForClose() async {
        if let listener { await listener.value }
    }

    private func send(_ command: SettingsWorker.Command) {
        do { try process?.send(command) }
        catch { onError?(error.localizedDescription); close() }
    }

    private func handle(_ event: SettingsWorker.Event) {
        switch event {
        case .recording(let recording):
            do { try coordinator.setRecording(recording) }
            catch { send(.error(error.localizedDescription)) }
        case .save(let edit):
            guard keyStatusLoaded else { send(.saveResult("无法确认已保存的密钥，请关闭设置后重试。")); return }
            coordinator.save(edit) { [weak self] error in
                guard let self else { return }
                if error == nil { onSave?() }
                send(.saveResult(error))
            }
        case .closed:
            isClosing = true
            process?.finishInput()
        case .quit: onQuit?()
        case .capture: onCapture?()
        }
    }
}
