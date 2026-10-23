import AppKit
import CoreVideo
// Xcode 16's SDK lacks Sendable annotations on its immutable content snapshot.
// We consume that snapshot on the main actor, rather than sharing it ourselves.
@preconcurrency import ScreenCaptureKit

struct CapturedImage: Sendable {
    let data: Data
    let mimeType: String
}

enum CaptureError: LocalizedError {
    case missingDisplay, emptySelection, encodingFailed, imageTooLarge
    var errorDescription: String? {
        switch self {
        case .missingDisplay: "找不到所选显示器，请重新截图。"
        case .emptySelection: "截图区域过小，请重新选择。"
        case .encodingFailed: "无法处理截图，请重试。"
        case .imageTooLarge: "截图内容过大，请缩小选择区域。"
        }
    }
}

enum ScreenCapture {
    @MainActor
    static func capture(_ region: SelectedRegion) async throws -> CapturedImage {
        try Task.checkCancellation()
        guard let displayNumber = region.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.missingDisplay
        }
        let screenFrame = region.screen.frame
        let scale = region.screen.backingScaleFactor
        let rect = region.rect.intersection(screenFrame)
        guard rect.width >= 8, rect.height >= 8 else { throw CaptureError.emptySelection }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayNumber.uint32Value }) else {
            throw CaptureError.missingDisplay
        }
        // Exclude our windows, even if the compositor hasn't removed the selection overlay yet.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
        // Bound a single bitmap to 8 megapixels, retaining native resolution for ordinary crops.
        let nativeWidth = rect.width * scale
        let nativeHeight = rect.height * scale
        let factor = min(1, 4096 / max(nativeWidth, nativeHeight), sqrt(8_000_000 / (nativeWidth * nativeHeight)))
        configuration.width = max(1, Int((nativeWidth * factor).rounded()))
        configuration.height = max(1, Int((nativeHeight * factor).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = .best
        // Admit before allocating a bitmap, so rapid replacements wait without
        // retaining screenshots while the previous ImageIO call finishes.
        return try await PNGEncoder.shared.captureAndEncode { @MainActor in
            try Task.checkCancellation()
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }
}
