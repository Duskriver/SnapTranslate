import AppKit
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

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
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        // Encoding can be CPU intensive. Keep it off the UI actor, with cancellation propagated.
        let encodingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool { try encode(image) }
        }
        return try await withTaskCancellationHandler {
            try await encodingTask.value
        } onCancel: {
            encodingTask.cancel()
        }
    }

    private static func encode(_ image: CGImage) throws -> CapturedImage {
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.encodingFailed }
        try Task.checkCancellation()
        guard CFDataGetLength(data) <= 10 * 1024 * 1024 else { throw CaptureError.imageTooLarge }
        return CapturedImage(data: data as Data, mimeType: "image/png")
    }
}
