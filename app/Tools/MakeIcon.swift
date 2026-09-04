// Renders the app icon set and packs it into AppIcon.icns.
// Run via: swift Tools/MakeIcon.swift <output-directory>
import AppKit
import CoreGraphics
import Foundation

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetURL = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

/// Bar heights as a fraction of the drawable area: a load trace that reads as
/// "monitor" at 16pt as well as 1024pt.
let bars: [CGFloat] = [0.34, 0.58, 0.44, 0.78, 1.0, 0.66]

func render(size: Int) -> Data? {
    let dimension = CGFloat(size)
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Rounded-rect body with a subtle vertical gradient.
    let inset = dimension * 0.08
    let rect = CGRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let bodyPath = CGPath(
        roundedRect: rect, cornerWidth: rect.width * 0.22, cornerHeight: rect.width * 0.22,
        transform: nil
    )
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let background = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1),
            CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 0, y: dimension), end: CGPoint(x: 0, y: 0), options: []
    )

    // Load bars, cool-to-warm left to right.
    let plot = rect.insetBy(dx: rect.width * 0.20, dy: rect.height * 0.24)
    let slot = plot.width / CGFloat(bars.count)
    let barWidth = slot * 0.56
    for (index, height) in bars.enumerated() {
        let x = plot.minX + slot * CGFloat(index) + (slot - barWidth) / 2
        let barHeight = max(plot.height * height, barWidth)
        let barRect = CGRect(x: x, y: plot.minY, width: barWidth, height: barHeight)
        let progress = CGFloat(index) / CGFloat(bars.count - 1)
        context.setFillColor(CGColor(
            red: 0.20 + progress * 0.55,
            green: 0.82 - progress * 0.28,
            blue: 0.62 - progress * 0.32,
            alpha: 1
        ))
        context.addPath(CGPath(
            roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
            transform: nil
        ))
        context.fillPath()
    }
    context.restoreGState()

    guard let image = context.makeImage() else { return nil }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: size, height: size)
    return representation.representation(using: .png, properties: [:])
}

// The sizes `iconutil` expects, with their @1x/@2x file names.
let variants: [(size: Int, name: String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for variant in variants {
    guard let data = render(size: variant.size) else {
        FileHandle.standardError.write("failed to render \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconsetURL.appendingPathComponent(variant.name))
}
print("wrote \(iconsetURL.path)")
