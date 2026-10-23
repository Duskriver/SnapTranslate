import AppKit
import TranslationCore

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
    private let settings = SettingsStore()
    private let hotKey = GlobalHotKey()
    private let selector = RegionSelector()
    private let client = DeepSeekClient()
    private var statusItem: NSStatusItem?
    private var settingsController: SettingsWindowController?
    private var resultController: ResultPanelController?
    private var translationTask: Task<Void, Never>?
    private var activeRequestID: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installStatusItem()
        hotKey.onPress = { [weak self] in self?.beginCapture() }
        do { try hotKey.register() }
        catch { showAlert(title: "快捷键暂不可用", message: error.localizedDescription) }
        do {
            if try settings.loadAPIKey().isEmpty { showSettings() }
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
        cancelTranslation()
        selector.cancel()
        hotKey.unregister()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "character.viewfinder", accessibilityDescription: "SnapTranslate 截屏翻译")
            ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "SnapTranslate")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "SnapTranslate · ⌥⇧T 截屏翻译"
        let menu = NSMenu()
        let title = NSMenuItem(title: "SnapTranslate · 轻译", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(.separator())
        let capture = NSMenuItem(title: "截屏翻译", action: #selector(beginCapture), keyEquivalent: "t")
        capture.keyEquivalentModifierMask = [.option, .shift]
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
        let capture = NSMenuItem(title: "截屏翻译", action: #selector(beginCapture), keyEquivalent: "t")
        capture.target = self
        capture.keyEquivalentModifierMask = [.option, .shift]
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

    @objc private func showSettings() {
        selector.cancel()
        if settingsController == nil { settingsController = SettingsWindowController(store: settings) }
        settingsController?.present()
    }

    @objc private func beginCapture() {
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
        let identifier = UUID()
        activeRequestID = identifier
        let panel = resultPanel()
        panel.showLoading(near: region.rect)
        translationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeRequestID == identifier { self.translationTask = nil }
            }
            do {
                let image = try await ScreenCapture.capture(region)
                try Task.checkCancellation()
                let text = try await self.client.translate(
                    imageData: image.data, mimeType: image.mimeType, apiKey: apiKey, targetLanguage: language
                ) { [weak self] text in
                    await MainActor.run {
                        guard let self, self.activeRequestID == identifier else { return }
                        self.resultController?.update(text: text)
                    }
                }
                try Task.checkCancellation()
                guard self.activeRequestID == identifier else { return }
                panel.update(text: text)
                panel.finish()
            } catch {
                guard !Task.isCancelled, self.activeRequestID == identifier else { return }
                panel.showError(error.localizedDescription)
            }
        }
    }

    private func resultPanel() -> ResultPanelController {
        if let resultController { return resultController }
        let controller = ResultPanelController()
        controller.onClose = { [weak self] in
            self?.cancelTranslation()
            self?.resultController = nil
        }
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        resultController = controller
        return controller
    }

    private func cancelTranslation() {
        activeRequestID = nil
        translationTask?.cancel()
        translationTask = nil
    }

    private func ensureCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在系统设置的「隐私与安全性 → 屏幕与系统音频录制」中允许 SnapTranslate，然后重新尝试 ⌥⇧T。应用仅在你框选区域后截取一张图片。若系统要求，请退出并重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
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
