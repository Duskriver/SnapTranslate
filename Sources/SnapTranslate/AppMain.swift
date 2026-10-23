import AppKit

@main
struct SnapTranslateMain {
    @MainActor
    static func main() {
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
    private var statusItem: NSStatusItem?
    private var captureMenuItems: [NSMenuItem] = []
    private(set) var settingsController: SettingsWindowController?
    private(set) var resultController: ResultPanelController?
    private(set) var translationTask: Task<Void, Never>?
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
        makeResultPanel: @escaping () -> ResultPanelController = { ResultPanelController() }
    ) {
        self.settings = settings
        self.hotKey = hotKey
        self.selector = selector
        self.pipeline = pipeline
        self.capturePermission = capturePermission
        self.makeResultPanel = makeResultPanel
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
        selector.cancel()
        if settingsController == nil {
            let controller = SettingsWindowController(store: settings, hotKey: hotKey)
            controller.onSave = { [weak self] in self?.updateShortcutPresentation() }
            controller.onClose = { [weak self] in self?.settingsController = nil }
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
    }

    @objc func beginCapture() {
        guard !isTerminating else { return }
        if selector.isSelecting { selector.cancel(); return }
        let key: String
        do { key = try settings.loadAPIKey() }
        catch {
            showAlert(title: "无法读取 API Key", message: error.localizedDescription)
            showSettings()
            return
        }
        guard !key.isEmpty else { showSettings(); return }
        cancelTranslation()
        resultController?.dismiss()
        guard ensureCapturePermission() else { return }
        // A secure key field must never appear in the source screenshot.
        settingsController?.close()
        let language = settings.targetLanguage
        selector.begin { [weak self] region in
            guard let self, let region else { return }
            self.translate(region, apiKey: key, language: language)
        }
    }

    private func translate(_ region: SelectedRegion, apiKey: String, language: String) {
        guard !isTerminating else { return }
        let identifier = UUID()
        activeRequestID = identifier
        let panel = resultPanel()
        panel.showLoading(near: region.rect)
        let pipeline = pipeline
        translationTask = Task { [weak self] in
            // A cancelled system operation may take time to return. It must not
            // keep the app delegate or a dismissed result window alive meanwhile.
            defer {
                if let self, self.activeRequestID == identifier {
                    self.activeRequestID = nil
                    self.translationTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                let image = try await pipeline.capture(region)
                try Task.checkCancellation()
                try await pipeline.translate(image, apiKey, language) { [weak self] delta in
                    await MainActor.run {
                        guard let self, self.activeRequestID == identifier else { return }
                        self.resultController?.append(delta: delta)
                    }
                }
                try Task.checkCancellation()
                guard let self, self.activeRequestID == identifier else { return }
                self.resultController?.finish()
            } catch {
                guard !Task.isCancelled, let self, self.activeRequestID == identifier else { return }
                self.resultController?.showError(error)
            }
        }
    }

    private func resultPanel() -> ResultPanelController {
        if let resultController { return resultController }
        let controller = makeResultPanel()
        controller.onClose = { [weak self] in
            self?.cancelTranslation()
            self?.resultController = nil
        }
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        controller.onOpenScreenRecordingSettings = { [weak self] in self?.showScreenRecordingSettings() }
        resultController = controller
        return controller
    }

    private func cancelTranslation() {
        activeRequestID = nil
        translationTask?.cancel()
        translationTask = nil
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
