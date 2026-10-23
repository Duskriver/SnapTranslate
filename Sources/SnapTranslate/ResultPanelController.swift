import AppKit

/// A plain-text result window. No browser, history, or image is retained here.
@MainActor
final class ResultPanelController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 396, height: 220))
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let copyButton = NSButton(title: "复制译文", target: nil, action: nil)
    private let settingsButton = NSButton(title: "设置…", target: nil, action: nil)
    private var presentationIsActive = false
    private var isDisplayingError = false
    private var hasTranslatedText = false

    init() {
        let panel = TranslationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 354),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "轻译 · SnapTranslate"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.contentMinSize = NSSize(width: 340, height: 250)

        super.init(window: panel)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.dismiss() }
        configureContent(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    func showLoading(near anchor: NSRect? = nil) {
        guard let panel = window else { return }
        // Reusing a visible panel is still the same presentation. This does not
        // invoke onClose, which the owner uses to cancel the active request.
        presentationIsActive = true
        isDisplayingError = false
        hasTranslatedText = false
        textView.string = ""
        copyButton.isEnabled = false
        copyButton.title = "复制译文"
        settingsButton.isHidden = true
        statusLabel.stringValue = "正在读取截图并翻译…"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
        statusLabel.setAccessibilityHelp(nil)
        progress.isHidden = false
        progress.startAnimation(nil)
        position(panel, near: anchor)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func update(text: String) {
        guard presentationIsActive else { return }
        let shouldFollow = scrollView.contentView.bounds.maxY >= textView.bounds.height - 40
        let oldText = textView.string
        if !isDisplayingError, text.hasPrefix(oldText), let storage = textView.textStorage {
            let suffix = String(text.dropFirst(oldText.count))
            if !suffix.isEmpty {
                storage.append(NSAttributedString(string: suffix, attributes: textAttributes))
            }
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: textAttributes))
        }
        isDisplayingError = false
        hasTranslatedText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        statusLabel.stringValue = "正在翻译…"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
        statusLabel.setAccessibilityHelp(nil)
        settingsButton.isHidden = true
        copyButton.title = "复制译文"
        copyButton.isEnabled = hasTranslatedText
        if shouldFollow {
            textView.scrollRangeToVisible(NSRange(location: textView.string.utf16.count, length: 0))
        }
    }

    func showError(_ message: String) {
        guard presentationIsActive else { return }
        stopProgress()
        isDisplayingError = true
        let summary = hasTranslatedText ? "译文不完整 · \(message)" : "翻译未完成"
        statusLabel.stringValue = summary
        statusLabel.textColor = .systemRed
        statusLabel.toolTip = hasTranslatedText ? summary : message
        statusLabel.setAccessibilityHelp(hasTranslatedText ? summary : message)
        // A failed stream may still contain useful translation. Keep it
        // selectable and copyable; an error message must never replace it.
        if !hasTranslatedText {
            textView.textStorage?.setAttributedString(NSAttributedString(string: message, attributes: textAttributes))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }
        copyButton.isEnabled = hasTranslatedText
        copyButton.title = hasTranslatedText ? "复制已有译文" : "复制译文"
        // Only credentials and target language are configurable in this MVP.
        // Network, service, and capture failures cannot be fixed in settings.
        settingsButton.isHidden = !message.localizedCaseInsensitiveContains("API Key")
            && !message.contains("目标语言")
    }

    func finish() {
        guard presentationIsActive, !isDisplayingError else { return }
        stopProgress()
        if textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showError("没有收到译文，请重新截取包含文字的区域后重试。")
            return
        }
        statusLabel.stringValue = "翻译完成"
        statusLabel.textColor = .secondaryLabelColor
    }

    func dismiss() {
        window?.orderOut(nil)
        endPresentation()
    }

    func windowWillClose(_ notification: Notification) {
        endPresentation()
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    private func configureContent(in panel: NSPanel) {
        let content = NSView()
        panel.contentView = content

        let title = NSTextField(labelWithString: "截图翻译")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let engine = NSTextField(labelWithString: "DeepSeek")
        engine.font = .systemFont(ofSize: 11, weight: .medium)
        engine.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true
        progress.setAccessibilityLabel("正在翻译")

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 396, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("翻译结果")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .bezelBorder

        copyButton.bezelStyle = .rounded
        copyButton.target = self
        copyButton.action = #selector(copyTranslation)
        copyButton.isEnabled = false
        copyButton.toolTip = "将当前收到的译文复制到剪贴板"
        settingsButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.isHidden = true

        let hint = NSTextField(labelWithString: "Esc 关闭")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        for view in [title, engine, statusLabel, progress, scrollView, copyButton, settingsButton, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            engine.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            engine.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            engine.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -8),
            progress.trailingAnchor.constraint(equalTo: engine.trailingAnchor),
            progress.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -14),
            copyButton.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            settingsButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            hint.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: settingsButton.leadingAnchor, constant: -8),
        ])
    }

    private func position(_ panel: NSWindow, near anchor: NSRect?) {
        let screen = anchor.flatMap { rect in
            NSScreen.screens.max { first, second in
                intersectionArea(first.frame, rect) < intersectionArea(second.frame, rect)
            }
        } ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame.insetBy(dx: 12, dy: 12) else {
            panel.center()
            return
        }

        let size = NSSize(
            width: min(panel.frame.width, visibleFrame.width),
            height: min(panel.frame.height, visibleFrame.height)
        )
        var origin: NSPoint
        if let anchor {
            let right = anchor.maxX + 12
            let left = anchor.minX - size.width - 12
            let x = right + size.width <= visibleFrame.maxX ? right : left
            origin = NSPoint(x: x, y: anchor.maxY - size.height)
        } else {
            origin = NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let rect = first.intersection(second)
        return rect.isNull ? 0 : rect.width * rect.height
    }

    private func stopProgress() {
        progress.stopAnimation(nil)
        progress.isHidden = true
    }

    private func endPresentation() {
        guard presentationIsActive else { return }
        presentationIsActive = false
        stopProgress()
        textView.string = ""
        statusLabel.stringValue = ""
        statusLabel.toolTip = nil
        statusLabel.setAccessibilityHelp(nil)
        copyButton.isEnabled = false
        copyButton.title = "复制译文"
        settingsButton.isHidden = true
        isDisplayingError = false
        hasTranslatedText = false
        // All teardown precedes the callback. The owner may release its only
        // controller reference here, including from windowWillClose.
        let callback = onClose
        withExtendedLifetime(self) { callback?() }
    }

    @objc private func copyTranslation() {
        guard presentationIsActive, hasTranslatedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        if isDisplayingError {
            // Keep the incomplete warning and its full error explanation.
            copyButton.title = "已复制"
        } else {
            statusLabel.stringValue = "已复制译文"
        }
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}

@MainActor
private final class TranslationPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
