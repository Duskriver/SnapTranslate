import AppKit

let destination = CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = pointSize * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        NSGraphicsContext.current?.cgContext.scaleBy(x: factor, y: factor)
        let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
        NSColor(calibratedRed: 0.12, green: 0.39, blue: 0.92, alpha: 1).setFill()
        background.fill()
        let marks = NSBezierPath()
        marks.lineWidth = 36
        marks.lineCapStyle = .round
        marks.lineJoinStyle = .round
        for (x, y, dx, dy) in [(250.0, 250.0, 1.0, 1.0), (774, 250, -1, 1), (250, 774, 1, -1), (774, 774, -1, -1)] {
            marks.move(to: NSPoint(x: x + dx * 90, y: y))
            marks.line(to: NSPoint(x: x, y: y))
            marks.line(to: NSPoint(x: x, y: y + dy * 90))
        }
        NSColor.white.withAlphaComponent(0.9).setStroke()
        marks.stroke()
        let text = "译" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 340, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png"))
    }
}
