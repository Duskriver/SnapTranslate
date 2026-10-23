import Foundation
import ScreenCaptureKit

enum ScreenCapturePermission {
    static let recoveryMessage = """
    macOS 未允许本次屏幕捕获。

    请打开「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」（部分系统称为「屏幕录制」），允许 SnapTranslate，然后退出并重新打开应用，再次截图。

    如果开关已经开启，请先重启 SnapTranslate。若仍失败，请在该列表中移除旧条目，重新添加当前使用的 SnapTranslate.app 并开启权限。
    """

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func isDenied(_ error: any Error) -> Bool {
        let error = error as NSError
        // Preflight can succeed while ScreenCaptureKit rejects the actual
        // request. Match its domain and code, never the localized TCC message.
        return error.domain == SCStreamError.errorDomain
            && error.code == SCStreamError.Code.userDeclined.rawValue
    }
}
