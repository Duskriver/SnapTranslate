import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    private let store: SettingsStore
    private let hotKey: GlobalHotKey
    private let keyField = NSSecureTextField()
    private let languagePopup = NSPopUpButton()
    private let shortcutRecorder = ShortcutRecorder()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var keyStatusLoaded = false
    private var hasSavedKey = false
    private var removeSavedKey = false
    private let deleteKeyButton = NSButton(title: "删除密钥", target: nil, action: nil)
    private var saveButton: NSButton!

    init(store: SettingsStore, hotKey: GlobalHotKey) {
        self.store = store
        self.hotKey = hotKey
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SnapTranslate 设置"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone]
        WindowResourcePolicy.configureUtilityWindow(window)
        super.init(window: window)
        window.delegate = self
        shortcutRecorder.onValidation = { [weak self] message in self?.errorLabel.stringValue = message ?? "" }
        shortcutRecorder.onRecordingChanged = { [weak self] recording in
            guard let self else { return }
            if recording {
                self.hotKey.unregister()
            } else {
                do { try self.hotKey.register(self.store.captureShortcut) }
                catch { self.errorLabel.stringValue = error.localizedDescription }
            }
        }
        buildInterface(in: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        prepareForPresentation()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func prepareForPresentation() {
        shortcutRecorder.stopRecording()
        shortcutRecorder.shortcut = store.captureShortcut
        errorLabel.stringValue = ""
        keyField.stringValue = ""
        removeSavedKey = false
        do {
            hasSavedKey = try store.hasAPIKey()
            keyStatusLoaded = true
            saveButton.isEnabled = true
        } catch {
            keyField.stringValue = ""
            hasSavedKey = false
            keyStatusLoaded = false
            saveButton.isEnabled = false
            errorLabel.stringValue = error.localizedDescription
        }
        updateKeyControls()
        languagePopup.selectItem(withTitle: store.targetLanguage)
        if languagePopup.indexOfSelectedItem < 0 { languagePopup.selectItem(at: 0) }
        // A saved key does not need editing on every visit. Focusing the secure
        // field can launch macOS Password AutoFill even when it is not used.
        window?.initialFirstResponder = hasSavedKey || !keyStatusLoaded ? languagePopup : keyField
    }

    func windowWillClose(_ notification: Notification) {
        shortcutRecorder.stopRecording()
        // End secure editing before the owner releases this window and its controls.
        keyField.currentEditor()?.string = ""
        keyField.stringValue = ""
        window?.makeFirstResponder(nil)
        keyStatusLoaded = false
        hasSavedKey = false
        removeSavedKey = false
        errorLabel.stringValue = ""
        shortcutRecorder.onRecordingChanged = nil
        shortcutRecorder.onValidation = nil
        onSave = nil
        let callback = onClose
        onClose = nil
        // Closing via the title bar, Cancel, Save, or capture all use this path.
        // Keep the delegate alive while its owner drops the last reference.
        withExtendedLifetime(self) { callback?() }
    }

    func windowDidResignKey(_ notification: Notification) {
        shortcutRecorder.stopRecording()
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
        let keyNote = note("留空保留已存密钥，输入新密钥替换。密钥仅保存在本机钥匙串。")
        deleteKeyButton.bezelStyle = .inline
        deleteKeyButton.font = .systemFont(ofSize: 11)
        deleteKeyButton.target = self
        deleteKeyButton.action = #selector(toggleKeyDeletion)
        let keyNoteRow = NSStackView(views: [keyNote, NSView(), deleteKeyButton])
        keyNoteRow.orientation = .horizontal
        keyNoteRow.alignment = .centerY
        deleteKeyButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let keySection = verticalStack([keyTitleRow, keyField, keyNoteRow], spacing: 7)

        languagePopup.addItems(withTitles: ["简体中文", "繁體中文", "English", "日本語", "한국어"])
        languagePopup.controlSize = .regular
        let languageRow = NSStackView(views: [label("目标语言", size: 13), NSView(), languagePopup])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY

        shortcutRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        let resetShortcut = NSButton(title: "恢复默认", target: self, action: #selector(restoreDefaultShortcut))
        resetShortcut.bezelStyle = .rounded
        let shortcutRow = NSStackView(views: [label("截屏快捷键", size: 13), NSView(), shortcutRecorder, resetShortcut])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        let shortcutSection = verticalStack([
            shortcutRow, note("点击快捷键后按下新组合，需包含 ⌘、⌥ 或 ⌃。Esc 取消录制，保存后生效。"),
        ], spacing: 7)

        let privacy = note("仅在你框选截图后，选区图片才会发送给 DeepSeek。\n首次截屏需要允许“屏幕录制”；应用不会持续录屏。")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3
        errorLabel.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = verticalStack([header, keySection, languageRow, shortcutSection, privacy, errorLabel, buttons], spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
    }

    @objc private func save() {
        guard keyStatusLoaded else { return }
        shortcutRecorder.stopRecording()
        let previousShortcut = store.captureShortcut
        do {
            try hotKey.register(shortcutRecorder.shortcut)
            do {
                let replacement = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !replacement.isEmpty || removeSavedKey {
                    try store.saveAPIKey(replacement)
                }
            } catch {
                let keychainError = error.localizedDescription
                do { try hotKey.register(previousShortcut) }
                catch { errorLabel.stringValue = "\(keychainError)\n\(error.localizedDescription)"; return }
                errorLabel.stringValue = keychainError
                return
            }
            store.captureShortcut = shortcutRecorder.shortcut
            store.targetLanguage = languagePopup.titleOfSelectedItem ?? "简体中文"
            onSave?()
            close()
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func cancel() { close() }

    private func updateKeyControls() {
        deleteKeyButton.isHidden = !hasSavedKey
        deleteKeyButton.title = removeSavedKey ? "撤销删除" : "删除密钥"
        keyField.placeholderString = removeSavedKey ? "点击保存后删除现有密钥"
            : (hasSavedKey ? "已保存 API Key；留空保持不变" : "输入 DeepSeek API Key")
    }

    @objc private func toggleKeyDeletion() {
        removeSavedKey.toggle()
        keyField.stringValue = ""
        updateKeyControls()
    }

    @objc private func restoreDefaultShortcut() {
        shortcutRecorder.stopRecording()
        shortcutRecorder.shortcut = .default
        errorLabel.stringValue = ""
    }

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
