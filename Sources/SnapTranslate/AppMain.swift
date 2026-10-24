import AppKit

@main
struct SnapTranslateMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains(TranslationWorker.argument) { TranslationWorker.run() }
        if CommandLine.arguments.contains(SettingsWorker.argument) { SettingsWorker.run() }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings: SettingsStore
    private let hotKey: GlobalHotKey
    private let selector: RegionSelector
    private let pipeline: TranslationPipeline
    private let capturePermission: () -> Bool
    private let makeResultPanel: () -> ResultPanelController
    private let makeSettings: (SettingsStore, GlobalHotKey) -> any SettingsPresenting
    private var statusItem: NSStatusItem?
    private var captureMenuItems: [NSMenuItem] = []
    private(set) var settingsController: (any SettingsPresenting)?
    private var settingsTransition: Task<Void, Never>?
    private var capturingRequests: Set<UUID> = []
    private var wantsSettingsAfterCapture = false
    private(set) var resultController: ResultPanelController?
    private(set) var translationTasks: [UUID: Task<Void, Never>] = [:]
    var translationTask: Task<Void, Never>? { activeRequestID.flatMap { translationTasks[$0] } }
    private var activeRequestID: UUID?
    private var isTerminating = false

    init(
        settings: SettingsStore = SettingsStore(),
        hotKey: GlobalHotKey = GlobalHotKey(),
        selector: RegionSelector = RegionSelector(),
        pipeline: TranslationPipeline = .live,
        capturePermission: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        },
        makeResultPanel: @escaping () -> ResultPanelController = { ResultPanelController() },
        makeSettings: @escaping (SettingsStore, GlobalHotKey) -> any SettingsPresenting = {
            SettingsProcessController(store: $0, hotKey: $1)
        }
    ) {
        self.settings = settings
        self.hotKey = hotKey
        self.selector = selector
        self.pipeline = pipeline
        self.capturePermission = capturePermission
        self.makeResultPanel = makeResultPanel
        self.makeSettings = makeSettings
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installStatusItem()
        hotKey.onPress = { [weak self] in self?.beginCapture() }
        updateShortcutPresentation()
        do { try hotKey.register(settings.captureShortcut) }
        catch { showAlert(title: "快捷键暂不可用", message: error.localizedDescription) }
        do {
            if try !settings.hasAPIKey() { showSettings() }
        } catch {
            showSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isTerminating else { return }
        isTerminating = true
        wantsSettingsAfterCapture = false
        settingsTransition?.cancel()
        settingsTransition = nil
        hotKey.onPress = nil
        cancelTranslation()
        selector.cancel()
        resultController?.dismiss()
        settingsController?.close()
        hotKey.unregister()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "character.viewfinder", accessibilityDescription: "SnapTranslate 截屏翻译")
            ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "SnapTranslate")
        icon?.isTemplate = true
        item.button?.image = icon
        let menu = NSMenu()
        let title = NSMenuItem(title: "SnapTranslate · 轻译", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(.separator())
        let capture = NSMenuItem(title: "截屏翻译", action: #selector(beginCapture), keyEquivalent: "")
        captureMenuItems.append(capture)
        capture.target = self
        menu.addItem(capture)
        let preferences = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 SnapTranslate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let capture = NSMenuItem(title: "截屏翻译", action: #selector(beginCapture), keyEquivalent: "")
        captureMenuItems.append(capture)
        capture.target = self
        appMenu.addItem(capture)
        let preferences = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(preferences)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 SnapTranslate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc func showSettings() {
        guard !isTerminating else { return }
        settingsTransition?.cancel()
        selector.cancel()
        // A settings child launched after a capture's window snapshot would not
        // be in that snapshot's process exclusions. Wait until pixels are read.
        if !capturingRequests.isEmpty {
            wantsSettingsAfterCapture = true
            return
        }
        wantsSettingsAfterCapture = false
        if let controller = settingsController, controller.isClosing {
            afterSettingsClose(controller) { $0.showSettings() }
            return
        }
        if settingsController == nil {
            let controller = makeSettings(settings, hotKey)
            controller.onSave = { [weak self] in self?.updateShortcutPresentation() }
            controller.onClose = { [weak self] in
                guard let self else { return }
                self.settingsController = nil
                if self.isTerminating { self.hotKey.unregister() }
            }
            if let process = controller as? SettingsProcessController {
                process.onError = { [weak self] message in
                    guard let self, !self.isTerminating else { return }
                    self.showAlert(title: "设置暂不可用", message: message)
                }
                process.onQuit = { NSApplication.shared.terminate(nil) }
                process.onCapture = { [weak self] in self?.beginCapture() }
            }
            settingsController = controller
        }
        settingsController?.present()
    }

    private func updateShortcutPresentation() {
        let shortcut = settings.captureShortcut
        for item in captureMenuItems {
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        statusItem?.button?.toolTip = "SnapTranslate · \(shortcut.displayName) 截屏翻译"
        if pipeline.presentsResult { WorkerClient.shared.updateShortcut(shortcut) }
    }

    @objc func beginCapture() {
        guard !isTerminating else { return }
        wantsSettingsAfterCapture = false
        settingsTransition?.cancel()
        if let controller = settingsController {
            // Reap the settings process before selection can capture a secure field.
            controller.close()
            afterSettingsClose(controller) { $0.beginCapture() }
            return
        }
        if selector.isSelecting { selector.cancel(); return }
        let key: String
        do { key = try settings.loadAPIKey() }
        catch {
            showAlert(title: "无法读取 API Key", message: error.localizedDescription)
            showSettings()
            return
        }
        guard !key.isEmpty else { showSettings(); return }
        if !pipeline.presentsResult { cancelTranslation() }
        resultController?.dismiss()
        guard ensureCapturePermission() else { return }
        let language = settings.targetLanguage
        selector.begin { [weak self] region in
            guard let self, let region else { return }
            self.translate(region, apiKey: key, language: language)
        }
    }

    private func afterSettingsClose(_ controller: any SettingsPresenting,
                                    action: @escaping @MainActor (AppDelegate) -> Void) {
        settingsTransition = Task { [weak self] in
            await controller.waitForClose()
            guard !Task.isCancelled, let self, !self.isTerminating else { return }
            self.settingsTransition = nil
            action(self)
        }
    }

    private func translate(_ region: SelectedRegion, apiKey: String, language: String) {
        guard !isTerminating else { return }
        let identifier = UUID()
        capturingRequests.insert(identifier)
        activeRequestID = identifier
        if !pipeline.presentsResult { resultPanel().showLoading(near: region.rect) }
        let pipeline = pipeline
        translationTasks[identifier] = Task { [weak self] in
            // A cancelled system operation may take time to return. It must not
            // keep the app delegate or a dismissed result window alive meanwhile.
            defer {
                if let self {
                    self.translationTasks.removeValue(forKey: identifier)
                    if self.activeRequestID == identifier { self.activeRequestID = nil }
                    self.captureCompleted(identifier)
                }
            }
            do {
                try Task.checkCancellation()
                let delivery = TranslationDelivery(onDelta: { [weak self] delta in
                    await MainActor.run {
                        guard let self, self.translationTasks[identifier] != nil else { return }
                        self.resultController?.append(delta: delta)
                    }
                }, onAction: { [weak self] action in
                    await MainActor.run {
                        guard let self, self.translationTasks[identifier] != nil else { return }
                        switch action {
                        case .settings: self.showSettings()
                        case .screenRecordingSettings: self.showScreenRecordingSettings()
                        case .capture: self.beginCapture()
                        case .quit: NSApplication.shared.terminate(nil)
                        }
                    }
                }, onCaptureComplete: { [weak self] in
                    await MainActor.run { self?.captureCompleted(identifier) }
                })
                try await pipeline.run(region, apiKey, language, delivery)
                try Task.checkCancellation()
                guard !pipeline.presentsResult, let self, self.translationTasks[identifier] != nil else { return }
                self.resultController?.finish()
            } catch {
                guard !Task.isCancelled, let self, self.translationTasks[identifier] != nil else { return }
                if self.resultController == nil { self.resultPanel().showLoading(near: region.rect) }
                self.resultController?.showError(error)
            }
        }
    }

    private func captureCompleted(_ id: UUID) {
        capturingRequests.remove(id)
        if capturingRequests.isEmpty, wantsSettingsAfterCapture { showSettings() }
    }

    private func resultPanel() -> ResultPanelController {
        if let resultController { return resultController }
        let controller = makeResultPanel()
        controller.onClose = { [weak self] in
            if self?.pipeline.presentsResult == false { self?.cancelTranslation() }
            self?.resultController = nil
        }
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        controller.onOpenScreenRecordingSettings = { [weak self] in self?.showScreenRecordingSettings() }
        resultController = controller
        return controller
    }

    private func cancelTranslation() {
        activeRequestID = nil
        let tasks = translationTasks.values
        translationTasks.removeAll()
        for task in tasks { task.cancel() }
    }

    private func ensureCapturePermission() -> Bool {
        if capturePermission() { return true }
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = ScreenCapturePermission.recoveryMessage + "\n\n应用仅在你框选区域后截取一张图片。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            showScreenRecordingSettings()
        }
        return false
    }

    private func showScreenRecordingSettings() {
        // Let System Settings come forward without a floating result obscuring it.
        resultController?.dismiss()
        NSWorkspace.shared.open(ScreenCapturePermission.settingsURL)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
