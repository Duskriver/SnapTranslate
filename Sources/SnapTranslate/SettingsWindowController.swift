import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSave: (() -> Void)?

    private let store: SettingsStore
    private let keyField = NSSecureTextField()
    private let languagePopup = NSPopUpButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var keyLoaded = false
    private var saveButton: NSButton!

    init(store: SettingsStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 464, height: 384),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapTranslate 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        errorLabel.stringValue = ""
        do {
            keyField.stringValue = try store.loadAPIKey()
            keyLoaded = true
            saveButton.isEnabled = true
        } catch {
            keyField.stringValue = ""
            keyLoaded = false
            saveButton.isEnabled = false
            errorLabel.stringValue = error.localizedDescription
        }
        languagePopup.selectItem(withTitle: store.targetLanguage)
        if languagePopup.indexOfSelectedItem < 0 { languagePopup.selectItem(at: 0) }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Do not retain the key in the reusable settings window between visits.
        keyField.currentEditor()?.string = ""
        keyField.stringValue = ""
        keyLoaded = false
        errorLabel.stringValue = ""
    }

    private func buildInterface(in window: NSWindow) {
        guard let content = window.contentView else { return }

        let title = label("轻译", size: 25, weight: .semibold)
        let subtitle = label("截取一块屏幕，让 DeepSeek 翻译。", size: 13)
        subtitle.textColor = .secondaryLabelColor
        let header = verticalStack([title, subtitle], spacing: 5)

        let keyHeading = label("DeepSeek API Key", size: 13, weight: .medium)
        let consoleButton = NSButton(title: "获取 API Key ↗", target: self, action: #selector(openConsole))
        consoleButton.bezelStyle = .inline
        consoleButton.font = .systemFont(ofSize: 12)
        let keyTitleRow = NSStackView(views: [keyHeading, NSView(), consoleButton])
        keyTitleRow.orientation = .horizontal
        keyTitleRow.alignment = .centerY

        keyField.placeholderString = "输入 DeepSeek API Key"
        keyField.font = .systemFont(ofSize: 13)
        keyField.bezelStyle = .roundedBezel
        keyField.controlSize = .large
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let keyNote = note("密钥仅保存在本机钥匙串。清空后保存将删除密钥。")
        let keySection = verticalStack([keyTitleRow, keyField, keyNote], spacing: 7)

        languagePopup.addItems(withTitles: ["简体中文", "繁體中文", "English", "日本語", "한국어"])
        languagePopup.controlSize = .regular
        let languageRow = NSStackView(views: [label("目标语言", size: 13), NSView(), languagePopup])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY

        let shortcut = label("⌥ ⇧ T", size: 14, weight: .medium)
        shortcut.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        let shortcutRow = NSStackView(views: [label("截屏快捷键", size: 13), NSView(), shortcut])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY

        let privacy = note("仅在你框选截图后，选区图片才会发送给 DeepSeek。\n首次截屏需要允许“屏幕录制”；应用不会持续录屏。")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        errorLabel.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = verticalStack([header, keySection, languageRow, shortcutRow, privacy, errorLabel, buttons], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        window.initialFirstResponder = keyField
    }

    @objc private func save() {
        guard keyLoaded else { return }
        do {
            try store.saveAPIKey(keyField.stringValue)
            store.targetLanguage = languagePopup.titleOfSelectedItem ?? "简体中文"
            close()
            onSave?()
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func cancel() { close() }

    @objc private func openConsole() {
        guard let url = URL(string: "https://platform.deepseek.com/api_keys") else { return }
        NSWorkspace.shared.open(url)
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }
}
