#!/usr/bin/env swift
// Zeichnet das App-Icon (Wellenform auf dunklem Squircle) und baut daraus Resources/AppIcon.icns.
// Aufruf: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS-Raster: 824/1024 großer Squircle, zentriert.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.13, alpha: 1).cgColor,
        NSColor(srgbRed: 0.13, green: 0.15, blue: 0.24, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])

    // Wellenform: Balken, deren Höhe einer weichen „Redefluss"-Kurve folgt.
    let heights: [CGFloat] = [0.16, 0.30, 0.52, 0.78, 0.60, 0.92, 0.70, 0.44, 0.64, 0.36, 0.20]
    let barWidth = body.width * 0.052
    let gap = body.width * 0.03
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    let maxHeight = body.height * 0.56
    let bars = CGMutablePath()
    for h in heights {
        let height = max(barWidth, maxHeight * h)
        let rect = CGRect(x: x, y: body.midY - height / 2, width: barWidth, height: height)
        bars.addRoundedRect(in: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
        x += barWidth + gap
    }
    ctx.addPath(bars)
    ctx.clip()
    let accent = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.37, green: 0.92, blue: 0.83, alpha: 1).cgColor,
        NSColor(srgbRed: 0.38, green: 0.65, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.66, green: 0.55, blue: 0.98, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(accent, start: CGPoint(x: body.minX, y: body.midY), end: CGPoint(x: body.maxX, y: body.midY), options: [])
    ctx.restoreGState()

    // Feine Kante oben für etwas Tiefe.
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "✅ Resources/AppIcon.icns" : "❌ iconutil fehlgeschlagen")
