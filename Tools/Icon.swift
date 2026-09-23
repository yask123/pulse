import AppKit

// Renders the app icon: three gauges on a dark glass squircle. Usage: swift Tools/Icon.swift out.png
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    let inset: CGFloat = 100, rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    NSColor.black.setFill(); tile.fill()
    ctx.restoreGState()

    // Body
    NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.16, blue: 0.22, alpha: 1),
                        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.08, alpha: 1)])!.draw(in: tile, angle: -90)

    // Glass sheen on the upper half
    ctx.saveGState(); tile.addClip()
    let sheen = NSBezierPath(ovalIn: CGRect(x: rect.minX - 200, y: rect.midY + 40, width: rect.width + 400, height: rect.height))
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0.0)])!.draw(in: sheen, angle: -90)
    ctx.restoreGState()

    // Hairline rim
    NSColor.white.withAlphaComponent(0.14).setStroke()
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184); rim.lineWidth = 3; rim.stroke()

    // Gauges
    let accent = NSColor(srgbRed: 0.42, green: 0.80, blue: 0.95, alpha: 1)
    let w: CGFloat = 92, gap: CGFloat = 62, h: CGFloat = 470
    let x0 = size / 2 - (3 * w + 2 * gap) / 2, y0 = size / 2 - h / 2
    for (i, v) in [0.42, 0.78, 0.58].enumerated() {
        let x = x0 + CGFloat(i) * (w + gap)
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: y0, width: w, height: h), xRadius: w / 2, yRadius: w / 2).fill()
        let fill = NSBezierPath(roundedRect: CGRect(x: x, y: y0, width: w, height: h * v), xRadius: w / 2, yRadius: w / 2)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 50, color: accent.withAlphaComponent(0.55).cgColor)
        NSGradient(colors: [accent, NSColor(srgbRed: 0.30, green: 0.62, blue: 0.95, alpha: 1)])!.draw(in: fill, angle: -90)
        ctx.restoreGState()
    }
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
