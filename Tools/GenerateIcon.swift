import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: GenerateIcon <output.icns>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let variants: [(type: String, pixels: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]

func makeIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let scale = CGFloat(pixels) / 512
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let background = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 20 * scale, dy: 20 * scale),
        xRadius: 112 * scale,
        yRadius: 112 * scale
    )
    NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.18, alpha: 1).setFill()
    background.fill()

    let dial = NSBezierPath(
        ovalIn: NSRect(
            x: 106 * scale,
            y: 106 * scale,
            width: 300 * scale,
            height: 300 * scale
        )
    )
    NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.96, alpha: 1).setFill()
    dial.fill()

    let center = NSPoint(x: 256 * scale, y: 256 * scale)
    let hand = NSBezierPath()
    hand.lineCapStyle = .round
    hand.lineWidth = max(1, 26 * scale)
    hand.move(to: center)
    hand.line(to: NSPoint(x: 256 * scale, y: 342 * scale))
    hand.move(to: center)
    hand.line(to: NSPoint(x: 326 * scale, y: 218 * scale))
    NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.43, alpha: 1).setStroke()
    hand.stroke()

    let hub = NSBezierPath(
        ovalIn: NSRect(
            x: 239 * scale,
            y: 239 * scale,
            width: 34 * scale,
            height: 34 * scale
        )
    )
    NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.18, alpha: 1).setFill()
    hub.fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

func appendFourCC(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

let chunks: [(type: String, data: Data)] = try variants.map {
    ($0.type, try makeIcon(pixels: $0.pixels))
}
let totalSize = 8 + chunks.reduce(0) { $0 + 8 + $1.data.count }

var iconData = Data()
appendFourCC("icns", to: &iconData)
appendBigEndian(UInt32(totalSize), to: &iconData)
for chunk in chunks {
    appendFourCC(chunk.type, to: &iconData)
    appendBigEndian(UInt32(chunk.data.count + 8), to: &iconData)
    iconData.append(chunk.data)
}
try iconData.write(to: outputURL, options: .atomic)
