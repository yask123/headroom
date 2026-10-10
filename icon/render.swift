// Renders Headroom's 1024px icon: two gauges on graphite glass — Claude's outside, Codex's in.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [NSColor(srgbRed: 0.20, green: 0.19, blue: 0.19, alpha: 1).cgColor,
                                                    NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    let sheen = CGGradient(colorsSpace: nil, colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 400, y: 860), startRadius: 0, endCenter: CGPoint(x: 400, y: 860), endRadius: 560, options: [])

    let c = CGPoint(x: 512, y: 512)
    func arc(_ r: CGFloat, _ width: CGFloat, _ frac: CGFloat, _ color: NSColor) {
        let start = CGFloat.pi * 1.25, sweep = CGFloat.pi * 1.5
        ctx.setLineCap(.round); ctx.setLineWidth(width)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: start - sweep, clockwise: true); ctx.strokePath()
        ctx.setStrokeColor(color.cgColor)
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: start - sweep * frac, clockwise: true); ctx.strokePath()
    }
    arc(290, 64, 0.88, NSColor(srgbRed: 0.88, green: 0.52, blue: 0.40, alpha: 1))
    arc(190, 64, 0.66, NSColor(srgbRed: 0.55, green: 0.66, blue: 1.0, alpha: 1))
    ctx.restoreGState()

    ctx.addPath(shape); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(3); ctx.strokePath()
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
