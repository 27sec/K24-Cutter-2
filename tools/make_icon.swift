// Renders the K24 Cutter app icon and builds Resources/AppIcon.icns
// Usage: swift tools/make_icon.swift
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS-style squircle background with margin
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
bg.fill()
ctx.restoreGState()

bg.addClip()
NSGradient(colors: [NSColor(red: 0.10, green: 0.10, blue: 0.22, alpha: 1),
                    NSColor(red: 0.30, green: 0.12, blue: 0.48, alpha: 1)])!.draw(in: rect, angle: 70)

// Film strip (tilted)
ctx.saveGState()
ctx.translateBy(x: size / 2, y: size / 2 - 40)
ctx.rotate(by: -0.30)
let stripW: CGFloat = 1100, stripH: CGFloat = 300
let strip = CGRect(x: -stripW / 2, y: -stripH / 2, width: stripW, height: stripH)
NSColor(white: 0.06, alpha: 1).setFill()
NSBezierPath(rect: strip).fill()
// perforations
NSColor(white: 0.85, alpha: 1).setFill()
var x = -stripW / 2 + 20
while x < stripW / 2 {
    NSBezierPath(roundedRect: CGRect(x: x, y: stripH / 2 - 46, width: 34, height: 26), xRadius: 6, yRadius: 6).fill()
    NSBezierPath(roundedRect: CGRect(x: x, y: -stripH / 2 + 20, width: 34, height: 26), xRadius: 6, yRadius: 6).fill()
    x += 62
}
// frames: kept (green) / cut gap / kept
let frameColors: [NSColor] = [.systemTeal, .systemPink, .systemOrange, .systemGreen]
var fx = -stripW / 2 + 40
for i in 0..<6 {
    let c = frameColors[i % frameColors.count]
    NSGradient(colors: [c.withAlphaComponent(0.95), c.blended(withFraction: 0.5, of: .black)!])!
        .draw(in: CGRect(x: fx, y: -stripH / 2 + 66, width: 150, height: stripH - 132), angle: 90)
    fx += 175
}
// cut line (dashed, red)
ctx.setStrokeColor(NSColor.systemRed.cgColor)
ctx.setLineWidth(14)
ctx.setLineDash(phase: 0, lengths: [34, 22])
ctx.move(to: CGPoint(x: 18, y: stripH / 2 + 50))
ctx.addLine(to: CGPoint(x: 18, y: -stripH / 2 - 50))
ctx.strokePath()
ctx.restoreGState()

// Scissors symbol
if let sym = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 300, weight: .bold)) {
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let w: CGFloat = 330, h = w * sym.size.height / sym.size.width
    tinted.draw(in: CGRect(x: size / 2 - w / 2 + 10, y: 560, width: w, height: h))
}

// "K24" label
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 150, weight: .heavy),
    .foregroundColor: NSColor.white,
    .paragraphStyle: para,
    .kern: 6,
]
("K24" as NSString).draw(in: CGRect(x: inset, y: inset + 40, width: rect.width, height: 190), withAttributes: attrs)
img.unlockFocus()

// Write iconset + icns
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.imageInterpolation = .high
        NSGraphicsContext.current!.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run(); p.waitUntilExit()
try! fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"),
                 to: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/AppIcon-1024.png"))
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
