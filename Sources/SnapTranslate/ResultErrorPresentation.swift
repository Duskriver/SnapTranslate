import Foundation
import TranslationCore

/// Maps domain failures to UI behavior without inspecting localized messages.
struct ResultErrorPresentation {
    enum RecoveryAction {
        case openSettings
        case openScreenRecordingSettings
    }

    let message: String
    let recoveryAction: RecoveryAction?

    init(error: any Error) {
        if ScreenCapturePermission.isDenied(error) {
            message = ScreenCapturePermission.recoveryMessage
            recoveryAction = .openScreenRecordingSettings
            return
        }
        message = error.localizedDescription
        guard let error = error as? TranslationError else {
            // Other capture and system errors have no settings recovery action.
            recoveryAction = nil
            return
        }
        switch error {
        case .missingAPIKey, .invalidAPIKey, .unauthorized, .invalidTargetLanguage:
            recoveryAction = .openSettings
        case .invalidImage, .imageTooLarge, .insufficientBalance, .rateLimited,
             .serverUnavailable, .rejectedRequest, .invalidResponse, .malformedStream,
             .incompleteStream, .emptyTranslation, .outputTooLarge, .outputTruncated,
             .contentFiltered, .networkUnavailable, .timedOut:
            recoveryAction = nil
        }
    }
}
