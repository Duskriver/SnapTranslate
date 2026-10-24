import Foundation

struct TranslationDelivery: Sendable {
    let onDelta: @Sendable (String) async -> Void
    let onAction: @Sendable (TranslationWorker.Action) async -> Void
    var onCaptureComplete: @Sendable () async -> Void = {}
}

/// Production owns result windows in the shared disposable process. Injected
/// capture/network boundaries keep lifecycle tests in the app process.
struct TranslationPipeline: Sendable {
    let presentsResult: Bool
    var run: @MainActor @Sendable (
        SelectedRegion, String, String, TranslationDelivery
    ) async throws -> Void

    init(capture: @escaping @MainActor @Sendable (SelectedRegion) async throws -> CapturedImage,
         translate: @escaping @Sendable (
            CapturedImage, String, String, @escaping @Sendable (String) async -> Void
         ) async throws -> Void) {
        presentsResult = false
        run = { region, key, language, delivery in
            let image = try await capture(region)
            await delivery.onCaptureComplete()
            try Task.checkCancellation()
            try await translate(image, key, language, delivery.onDelta)
        }
    }

    init(presentsResult: Bool, run: @escaping @MainActor @Sendable (
        SelectedRegion, String, String, TranslationDelivery
    ) async throws -> Void) {
        self.presentsResult = presentsResult
        self.run = run
    }

    static let live = TranslationPipeline(presentsResult: true, run: TranslationWorker.translate)
}
