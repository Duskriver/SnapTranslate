import AppKit
import Carbon.HIToolbox

@MainActor
final class ShortcutRecorder: NSButton {
    var shortcut: KeyboardShortcut = .default { didSet { updateTitle() } }
    var onRecordingChanged: ((Bool) -> Void)?
    var onValidation: ((String?) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self
        action = #selector(toggleRecording)
        setAccessibilityLabel("截屏快捷键")
        toolTip = "点击后按下新的组合键；Esc 取消录制"
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func toggleRecording() {
        if isRecording { stopRecording(); return }
        window?.makeFirstResponder(self)
        isRecording = true
        updateTitle()
        onValidation?(nil)
        onRecordingChanged?(true)
        // Installed only while recording; consume keys before AppKit menu equivalents.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        updateTitle()
        onRecordingChanged?(false)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    // Kept separate from the monitor so keyboard behavior can be tested without posting OS events.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        guard event.window === window else { stopRecording(); return event }
        if event.type != .keyDown {
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { stopRecording() }
            return event
        }
        guard !event.isARepeat else { return nil }
        if event.keyCode == UInt16(kVK_Escape) {
            onValidation?(nil)
            stopRecording()
            return nil
        }
        let candidate = KeyboardShortcut(event: event)
        if let message = candidate.validationMessage {
            onValidation?(message)
            return nil
        }
        shortcut = candidate
        onValidation?(nil)
        stopRecording()
        return nil
    }

    private func updateTitle() {
        title = isRecording ? "请按组合键…" : shortcut.displayName
        setAccessibilityValue(title)
    }
}
