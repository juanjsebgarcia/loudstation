import AppKit

// GitHub's social preview card (1280 x 640): the app icon beside the name and the problem it
// solves, in the icon's graphite and mint. Usage: swift Tools/make-social-preview.swift Resources/AppIcon.icns docs/social-preview.png. Upload the result in the repository settings (Social preview); GitHub has no API for it.

let arguments = CommandLine.arguments
let icon = NSImage(contentsOf: URL(fileURLWithPath: arguments[1]))!
let width = 1280, height = 640

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

NSGradient(starting: color(0x232830), ending: color(0x0E1014))!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// A faint mint sawtooth across the bottom, echoing the icon.
let wave = NSBezierPath()
let baseline: CGFloat = 70, amplitude: CGFloat = 26, tooth: CGFloat = 160
wave.move(to: NSPoint(x: -20, y: baseline))
var x: CGFloat = -20
while x < CGFloat(width) + tooth {
    wave.line(to: NSPoint(x: x, y: baseline + amplitude))
    wave.line(to: NSPoint(x: x + tooth, y: baseline - amplitude))
    x += tooth
}
wave.lineWidth = 6
wave.lineJoinStyle = .round
color(0x7FF0B2, 0.16).setStroke()
wave.stroke()

let iconSize: CGFloat = 380
icon.draw(in: NSRect(x: 90, y: (CGFloat(height) - iconSize) / 2 + 20, width: iconSize, height: iconSize))

let textLeft: CGFloat = 520
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, colour: NSColor, top: CGFloat, width: CGFloat = 690) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = size * 0.12
    let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: colour, .paragraphStyle: style])
    let bounds = attributed.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin])
    attributed.draw(with: NSRect(x: textLeft, y: CGFloat(height) - top - bounds.height, width: width, height: bounds.height), options: [.usesLineFragmentOrigin])
}

draw("LoudStation", size: 76, weight: .bold, colour: color(0xF2F4F7), top: 150)
draw("No sound from your HDMI or DisplayPort monitor on Apple Silicon?", size: 38, weight: .semibold, colour: color(0x7FF0B2), top: 258)
draw("A menu bar app that spots silent monitor speakers and fixes them, without unplugging anything.", size: 27, weight: .regular, colour: color(0xB8C0CC), top: 378)
draw("Free and open source · brew install juanjsebgarcia/tap/loudstation", size: 22, weight: .medium, colour: color(0x8A93A0), top: 500)

NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
