import Foundation
import TranslationCore

/// The asynchronous system boundaries; AppDelegate still owns request and UI lifetimes.
struct TranslationPipeline: Sendable {
    var capture: @MainActor @Sendable (SelectedRegion) async throws -> CapturedImage
    var translate: @Sendable (
        CapturedImage, String, String, @escaping @Sendable (String) async -> Void
    ) async throws -> Void

    static let live = TranslationPipeline(
        capture: { try await ScreenCapture.capture($0) },
        translate: { image, apiKey, language, onDelta in
            _ = try await DeepSeekClient().translate(
                imageData: image.data, mimeType: image.mimeType,
                apiKey: apiKey, targetLanguage: language, onDelta: onDelta
            )
        }
    )
}
