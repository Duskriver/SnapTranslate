import AppKit
import ScreenCaptureKit
import Testing
import TranslationCore
@testable import SnapTranslate

@MainActor
@Suite(.serialized)
struct ResultErrorPresentationTests {
    @Test(arguments: [TranslationError.missingAPIKey, .invalidAPIKey, .unauthorized, .invalidTargetLanguage])
    func settingsErrorsOfferWorkingRecoveryAction(error: TranslationError) throws {
        let controller = makeController()
        defer { controller.dismiss() }
        controller.showLoading()
        controller.showError(error)
        let controls = descendants(of: try #require(controller.window?.contentView))
        let settings = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "设置…" })
        let text = try #require(controls.compactMap { $0 as? NSTextView }.first)
        #expect(!settings.isHidden)
        #expect(text.string == error.localizedDescription)
        var settingsOpened = 0
        controller.onOpenSettings = { settingsOpened += 1 }
        // Dispatch the configured action without running a button animation's event loop.
        #expect(NSApp.sendAction(try #require(settings.action), to: settings.target, from: settings))
        #expect(settingsOpened == 1)
    }

    @Test func matchingErrorMessagesDoNotImplyMatchingRecoveryActions() {
        // The same message must not turn a system failure into a settings error.
        for error in [TranslationError.invalidAPIKey, .invalidTargetLanguage] {
            let domain = ResultErrorPresentation(error: error)
            let unclassified = ResultErrorPresentation(error: MessageOnlyError(message: error.localizedDescription))
            #expect(domain.message == unclassified.message)
            #expect(domain.recoveryAction == .openSettings)
            #expect(unclassified.recoveryAction == nil)
        }
        for error in [CaptureError.missingDisplay, .emptySelection, .encodingFailed, .imageTooLarge] {
            let presentation = ResultErrorPresentation(error: error)
            #expect(presentation.message == error.localizedDescription)
            #expect(presentation.recoveryAction == nil)
        }
    }

    @Test func screenCaptureDenialUsesDomainAndCodeAcrossLocalizedMessages() throws {
        for message in ["用户拒绝了应用程序、窗口、显示器捕捉的 TCC", "The user declined TCCs for application, window, display capture"] {
            let error = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: message])
            let bridged = try #require(error as? SCStreamError)
            for presentation in [ResultErrorPresentation(error: error), ResultErrorPresentation(error: bridged)] {
                #expect(presentation.recoveryAction == .openScreenRecordingSettings)
                #expect(presentation.message.contains("退出并重新打开应用"))
                #expect(presentation.message.contains("移除旧条目"))
                #expect(!presentation.message.contains("TCC"))
            }
        }
        let unrelated: [any Error] = [
            NSError(domain: NSCocoaErrorDomain, code: SCStreamError.Code.userDeclined.rawValue),
            NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.internalError.rawValue),
            MessageOnlyError(message: "用户拒绝了应用程序、窗口、显示器捕捉的 TCC"),
            CancellationError(),
        ]
        for error in unrelated {
            let presentation = ResultErrorPresentation(error: error)
            #expect(presentation.recoveryAction == nil)
            #expect(presentation.message == error.localizedDescription)
        }
    }

    @Test func screenCaptureRecoveryOpensSystemSettingsAndCannotLeaveStaleActions() throws {
        let controller = makeController()
        defer { controller.dismiss() }
        var appSettingsOpened = 0
        var systemSettingsOpened = 0
        controller.onOpenSettings = { appSettingsOpened += 1 }
        controller.onOpenScreenRecordingSettings = { systemSettingsOpened += 1 }
        controller.showLoading()
        controller.showError(TranslationError.invalidAPIKey)
        let controls = descendants(of: try #require(controller.window?.contentView))
        let recovery = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "设置…" })
        let action = try #require(recovery.action)
        let denied = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        controller.showError(denied)
        controller.finish()
        #expect(!recovery.isHidden)
        #expect(recovery.title == "打开系统设置…")
        #expect(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "需要屏幕录制权限" })
        #expect(controls.compactMap { $0 as? NSTextView }.first?.string == ScreenCapturePermission.recoveryMessage)
        #expect(controls.compactMap { $0 as? NSButton }.first { $0.title == "复制译文" }?.isEnabled == false)
        #expect(controls.compactMap { $0 as? NSProgressIndicator }.allSatisfy { $0.isHidden })
        #expect(NSApp.sendAction(action, to: recovery.target, from: recovery))
        #expect(systemSettingsOpened == 1)
        #expect(appSettingsOpened == 0)

        controller.showError(CaptureError.missingDisplay)
        #expect(recovery.isHidden)
        #expect(NSApp.sendAction(action, to: recovery.target, from: recovery))
        controller.showError(denied)
        controller.showLoading()
        #expect(recovery.isHidden)
        #expect(NSApp.sendAction(action, to: recovery.target, from: recovery))
        controller.showError(denied)
        controller.append(delta: "新译文")
        #expect(recovery.isHidden)
        #expect(NSApp.sendAction(action, to: recovery.target, from: recovery))
        controller.showError(denied)
        controller.dismiss()
        controller.showError(denied)
        #expect(recovery.isHidden)
        #expect(NSApp.sendAction(action, to: recovery.target, from: recovery))
        #expect(systemSettingsOpened == 1)
        #expect(appSettingsOpened == 0)
    }

    @Test func interruptedTranslationKeepsPartialTextAndClearsStaleRecoveryAction() throws {
        let controller = makeController()
        defer { controller.dismiss() }
        controller.showLoading()
        controller.append(delta: "已经收到的译文")
        controller.showError(TranslationError.unauthorized)
        let controls = descendants(of: try #require(controller.window?.contentView))
        let settings = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "设置…" })
        #expect(!settings.isHidden)

        controller.showError(TranslationError.incompleteStream)
        controller.finish()
        let text = try #require(controls.compactMap { $0 as? NSTextView }.first)
        let copy = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "复制已有译文" })
        #expect(text.string == "已经收到的译文")
        #expect(copy.isEnabled)
        #expect(settings.isHidden)
        #expect(controls.compactMap { $0 as? NSProgressIndicator }.allSatisfy { $0.isHidden })
        #expect(controls.compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "译文不完整 · \(TranslationError.incompleteStream.localizedDescription)"
        })

        controller.showLoading()
        controller.append(delta: "新译文")
        controller.finish()
        #expect(text.string == "新译文")
        #expect(settings.isHidden)
        #expect(copy.title == "复制译文")
        #expect(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "翻译完成" })
    }

    @Test func emptyResultUsesTypedFailureAndLateFailureCannotReopenDismissedPanel() throws {
        let controller = makeController()
        defer { controller.dismiss() }
        controller.showLoading()
        controller.finish()
        let controls = descendants(of: try #require(controller.window?.contentView))
        let text = try #require(controls.compactMap { $0 as? NSTextView }.first)
        let settings = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "设置…" })
        let copy = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == "复制译文" })
        #expect(text.string == TranslationError.emptyTranslation.localizedDescription)
        #expect(settings.isHidden)
        #expect(!copy.isEnabled)

        controller.dismiss()
        controller.showError(TranslationError.missingAPIKey)
        #expect(text.string.isEmpty)
        #expect(settings.isHidden)
        #expect(controller.window?.isVisible == false)
    }

    private func makeController() -> ResultPanelController {
        _ = NSApplication.shared
        let controller = ResultPanelController()
        controller.window?.alphaValue = 0
        return controller
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

private struct MessageOnlyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
