import AppKit
import TranslationCore

/// One disposable process owns all visible results. Inputs use anonymous pipes.
enum TranslationWorker {
    static let argument = "--translation-worker"

    struct Request: Codable, Sendable {
        var id = UUID()
        let rect: CGRect
        let displayID: UInt32
        let parentPID: Int32
        let apiKey: String
        let language: String
    }

    enum Command: Codable, Sendable {
        case translate(Request), cancel(UUID), shortcut(KeyboardShortcut), shutdown
    }

    enum Failure: Codable, Sendable {
        case translation(TranslationError)
        case system(domain: String, code: Int, message: String)

        init(_ error: any Error) {
            if let error = error as? TranslationError { self = .translation(error) }
            else {
                let error = error as NSError
                self = .system(domain: error.domain, code: error.code, message: error.localizedDescription)
            }
        }

        var error: any Error {
            switch self {
            case .translation(let error): error
            case .system(let domain, let code, let message):
                NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
    }

    enum Action: String, Codable, Sendable {
        case settings, screenRecordingSettings, capture, quit
    }

    enum Event: Codable, Sendable {
        case closed(UUID)
        case action(UUID?, Action)
        case idle
        case failure(UUID?, Failure)
    }

    @MainActor
    static func translate(_ region: SelectedRegion, apiKey: String, language: String,
                          delivery: TranslationDelivery) async throws {
        guard let display = region.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.missingDisplay
        }
        let request = Request(rect: region.rect, displayID: display.uint32Value,
                              parentPID: getpid(), apiKey: apiKey, language: language)
        try await WorkerClient.shared.translate(request, delivery: delivery)
    }

    @MainActor static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let parentPID = getppid()
        let parentExit = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .global())
        parentExit.setEventHandler { exit(0) }
        parentExit.resume()
        let writer = WorkerEventWriter()
        let server = WorkerWindowServer(emit: writer.send)
        server.installMenu()
        application.delegate = server
        Task { @MainActor in
            do {
                for try await command in commands() {
                    switch command {
                    case .translate(let request):
                        guard request.parentPID == parentPID, getppid() == parentPID else {
                            throw TranslationError.invalidResponse
                        }
                        server.open(request)
                    case .cancel(let id): server.close(id)
                    case .shortcut(let shortcut): server.updateShortcut(shortcut)
                    case .shutdown:
                        // The parent stops submitting to this session before sending
                        // shutdown. An already queued open always arrives first.
                        if server.presentations.isEmpty { exit(0) }
                    }
                }
            } catch { }
            // EOF also means the owner has gone away. No orphan windows remain.
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
}

/// Shared UI and request ownership inside the worker. Closing one result never
/// cancels a different result; only an empty server asks the owner to shut down.
@MainActor
final class WorkerWindowServer: NSObject, NSApplicationDelegate {
    typealias Operation = @MainActor @Sendable (
        TranslationWorker.Request, NSScreen, @escaping @Sendable (String) async -> Void
    ) async throws -> Void

    private(set) var presentations: [UUID: WorkerPresentation] = [:]
    private let emit: (TranslationWorker.Event) -> Void
    private let operation: Operation
    private var captureMenuItem: NSMenuItem?

    init(emit: @escaping (TranslationWorker.Event) -> Void,
         operation: @escaping Operation = WorkerWindowServer.performTranslation) {
        self.emit = emit
        self.operation = operation
    }

    func open(_ request: TranslationWorker.Request) {
        guard presentations[request.id] == nil else { return }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == request.displayID
        }) else {
            emit(.failure(request.id, .init(CaptureError.missingDisplay)))
            if presentations.isEmpty { emit(.idle) }
            return
        }
        let presentation = WorkerPresentation()
        let id = request.id
        presentation.panel.onClose = { [weak self] in self?.close(id) }
        presentation.panel.onOpenSettings = { [weak self] in self?.emit(.action(id, .settings)) }
        presentation.panel.onOpenScreenRecordingSettings = { [weak self] in
            self?.emit(.action(id, .screenRecordingSettings))
            self?.close(id)
        }
        let occupied = presentations.values.compactMap { $0.panel.window?.frame }
        presentations[request.id] = presentation
        presentation.panel.showLoading(near: request.rect, avoiding: occupied)
        presentation.start(request, screen: screen, operation: operation)
    }

    func close(_ id: UUID) {
        guard let presentation = presentations.removeValue(forKey: id) else { return }
        presentation.operation?.cancel()
        presentation.operation = nil
        presentation.panel.dismiss()
        emit(.closed(id))
        if presentations.isEmpty { emit(.idle) }
    }

    static func performTranslation(_ request: TranslationWorker.Request, screen: NSScreen,
                                   onDelta: @escaping @Sendable (String) async -> Void) async throws {
        let image = try await ScreenCapture.capture(
            SelectedRegion(rect: request.rect, screen: screen),
            excludingProcessIDs: [request.parentPID, getpid()]
        )
        // Capture before waiting on network admission. A slow API response must
        // not defer reading the user's selected page until its content changes.
        let admission = WorkerNetworkAdmission.shared
        try await admission.acquire()
        do {
            try Task.checkCancellation()
            _ = try await DeepSeekClient().translate(
                imageData: image.data, mimeType: image.mimeType, apiKey: request.apiKey,
                targetLanguage: request.language, onDelta: onDelta
            )
        } catch {
            await admission.release()
            throw error
        }
        await admission.release()
    }

    func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let capture = NSMenuItem(title: "截屏翻译", action: #selector(captureAgain), keyEquivalent: "")
        captureMenuItem = capture
        updateShortcut(SettingsStore().captureShortcut)
        capture.target = self
        appMenu.addItem(capture)
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 SnapTranslate", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        guard shortcut.validationMessage == nil else { return }
        captureMenuItem?.keyEquivalent = shortcut.keyEquivalent
        captureMenuItem?.keyEquivalentModifierMask = shortcut.modifierFlags
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        emit(.action(nil, .settings))
        return false
    }

    @objc private func captureAgain() { emit(.action(nil, .capture)) }
    @objc private func openSettings() { emit(.action(nil, .settings)) }
    @objc private func quitApplication() { emit(.action(nil, .quit)) }
}

@MainActor
final class WorkerPresentation {
    let panel = ResultPanelController()
    var operation: Task<Void, Never>?
    private(set) var completed = false

    func start(_ request: TranslationWorker.Request, screen: NSScreen,
               operation: @escaping WorkerWindowServer.Operation) {
        let panel = panel
        self.operation = Task { [weak self, panel] in
            defer { self?.operation = nil }
            do {
                try Task.checkCancellation()
                try await operation(request, screen) { [weak panel] delta in
                    await MainActor.run { panel?.append(delta: delta) }
                }
                try Task.checkCancellation()
                panel.finish()
                self?.completed = true
            } catch {
                if !Task.isCancelled { panel.showError(error) }
            }
        }
    }
}

private final class WorkerEventWriter: Sendable {
    private let queue = DispatchQueue(label: "com.local.SnapTranslate.worker-events")
    func send(_ event: TranslationWorker.Event) {
        queue.async {
            do {
                var data = try JSONEncoder().encode(event)
                data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch { exit(1) }
        }
    }
}
