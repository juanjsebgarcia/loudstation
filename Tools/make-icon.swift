// Draws LoudStation's app icon at every size macOS needs and builds Resources/AppIcon.icns.
// Run from the repository root: swift Tools/make-icon.swift
//
// The design (chosen from the icon review): a graphite tile, a light grey display outline and a
// mint sawtooth wave across its screen. Coordinates use a 100-unit grid for the tile, as in the
// review mock-ups. The tile sits on Apple's macOS icon grid: 824 of 1024 pixels with a soft
// shadow. Small sizes get thicker strokes so the lines stay visible.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let preview = root.appendingPathComponent("docs/icon.png")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// The sawtooth across the screen: three rising ramps with vertical drops, centred on y = 45.
let sawtooth: [CGPoint] = [(18, 45), (18, 56), (39.33, 34), (39.33, 56), (60.67, 34), (60.67, 56), (82, 34), (82, 45)].map { CGPoint(x: $0.0, y: $0.1) }

func strokeBoost(forPointSize points: Int) -> CGFloat {
    switch points {
    case ...16: return 2.1
    case ...32: return 1.55
    case ...64: return 1.2
    default: return 1
    }
}

func drawIcon(pixels: Int, pointSize: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let canvas = CGFloat(pixels)
    // Apple's grid: the shape is 824/1024 of the canvas, centred slightly high to leave room for the shadow.
    let side = canvas * 824 / 1024
    let origin = CGPoint(x: (canvas - side) / 2, y: (canvas - side) / 2 + canvas * 6 / 1024)
    let unit = side / 100
    let boost = strokeBoost(forPointSize: pointSize)

    // Flip so the 100-unit grid's y grows downwards, matching the SVG mock-ups.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * unit, y: origin.y + y * unit) }

    let tile = CGPath(roundedRect: CGRect(origin: p(0, 0), size: CGSize(width: side, height: side)),
                      cornerWidth: 22.5 * unit, cornerHeight: 22.5 * unit, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: canvas * 10 / 1024), blur: canvas * 22 / 1024, color: rgb(0x000000, 0.32))
    context.addPath(tile)
    context.setFillColor(rgb(0x12151A))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x2A2F38), rgb(0x12151A)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: p(0, 0), end: p(0, 100), options: [])
    // A faint top sheen gives the tile depth at large sizes without changing the design.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0xFFFFFF, 0.07), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: p(0, 0), end: p(0, 45), options: [])
    context.restoreGState()

    // The display: outlined screen, neck and foot, as in the mock-up.
    context.setStrokeColor(rgb(0xB8C0CC))
    context.setLineWidth(4 * unit * boost)
    context.setLineJoin(.round)
    context.addPath(CGPath(roundedRect: CGRect(origin: p(12, 20), size: CGSize(width: 76 * unit, height: 50 * unit)), cornerWidth: 5 * unit, cornerHeight: 5 * unit, transform: nil))
    context.strokePath()
    context.stroke(CGRect(origin: p(44, 70), size: CGSize(width: 12 * unit, height: 10 * unit)))
    context.addPath(CGPath(roundedRect: CGRect(origin: p(32, 80), size: CGSize(width: 36 * unit, height: 5 * unit)), cornerWidth: 2.5 * unit, cornerHeight: 2.5 * unit, transform: nil))
    context.strokePath()

    // The wave, with a soft glow underneath at large sizes.
    let wave = CGMutablePath()
    wave.addLines(between: sawtooth.map { p($0.x, $0.y) })
    if pointSize >= 128 {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 3.2 * unit, color: rgb(0x7FF0B2, 0.45))
        context.addPath(wave)
        context.setStrokeColor(rgb(0x7FF0B2))
        context.setLineWidth(4.5 * unit)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }
    context.addPath(wave)
    context.setStrokeColor(rgb(0x7FF0B2))
    context.setLineWidth(4.5 * unit * boost)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    return context.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot finalise \(url.path)"])
    }
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        guard let image = drawIcon(pixels: points * scale, pointSize: points) else { fatalError("drawing failed at \(points)@\(scale)x") }
        try writePNG(image, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
if let large = drawIcon(pixels: 512, pointSize: 512) { try writePNG(large, to: preview) }

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed with \(iconutil.terminationStatus)") }
print("Wrote \(output.path) and \(preview.path)")
