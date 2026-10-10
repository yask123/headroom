// Colour, the two marks, and the menu bar image.

import AppKit
import SwiftUI

private func dynamic(dark: NSColor, light: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
}

extension Color {
    /// Claude's terracotta.
    static let claude = dynamic(dark: NSColor(srgbRed: 0.88, green: 0.52, blue: 0.40, alpha: 1),
                                light: NSColor(srgbRed: 0.80, green: 0.42, blue: 0.29, alpha: 1))
    /// A cool, quiet blue for Codex so the two never read as one.
    static let codex = dynamic(dark: NSColor(srgbRed: 0.55, green: 0.66, blue: 1.0, alpha: 1),
                               light: NSColor(srgbRed: 0.27, green: 0.40, blue: 0.86, alpha: 1))
    static let low = dynamic(dark: NSColor(srgbRed: 1.0, green: 0.48, blue: 0.42, alpha: 1),
                             light: NSColor(srgbRed: 0.82, green: 0.20, blue: 0.18, alpha: 1))

    /// Deepens the glass so numbers stay crisp over bright windows (and lifts it in light mode).
    static let panelTint = dynamic(dark: NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 0.62),
                                   light: NSColor(srgbRed: 0.98, green: 0.97, blue: 0.96, alpha: 0.55))
}

extension Provider {
    var tint: Color { self == .claude ? .claude : .codex }
}

// MARK: Marks

/// Claude's spark: tapered spokes of uneven length around a small centre.
enum Marks {
    static func claude(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        let c = CGPoint(x: r.midX, y: r.midY)
        let s = min(r.width, r.height) / 2
        let lengths: [CGFloat] = [1.0, 0.80, 0.94, 0.76, 1.0, 0.84, 0.92, 0.78, 0.98, 0.82, 0.90, 0.79]
        for (i, len) in lengths.enumerated() {
            let a = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi + 0.13
            let dir = CGPoint(x: cos(a), y: sin(a))
            let n = CGPoint(x: -dir.y, y: dir.x)
            let inner: CGFloat = 0, outer = s * len
            let w0 = s * 0.12, w1 = s * 0.07
            path.move(to: CGPoint(x: c.x + dir.x * inner + n.x * w0, y: c.y + dir.y * inner + n.y * w0))
            path.addLine(to: CGPoint(x: c.x + dir.x * outer + n.x * w1, y: c.y + dir.y * outer + n.y * w1))
            path.addArc(center: CGPoint(x: c.x + dir.x * outer, y: c.y + dir.y * outer), radius: w1,
                        startAngle: a + .pi / 2, endAngle: a - .pi / 2, clockwise: true)
            path.addLine(to: CGPoint(x: c.x + dir.x * inner - n.x * w0, y: c.y + dir.y * inner - n.y * w0))
            path.closeSubpath()
        }
        return path
    }

    /// OpenAI's blossom, simplified: six petals turning around a hexagonal hollow.
    static func codex(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        let c = CGPoint(x: r.midX, y: r.midY)
        let s = min(r.width, r.height) / 2
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 + .pi / 6
            let petal = CGPath(roundedRect: CGRect(x: -s * 0.19, y: -s * 0.08, width: s * 0.38, height: s * 0.86),
                               cornerWidth: s * 0.19, cornerHeight: s * 0.19, transform: nil)
            path.addPath(petal, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a).translatedBy(x: s * 0.30, y: 0))
        }
        return path
    }

    static func path(_ p: Provider, in r: CGRect) -> CGPath { p == .claude ? claude(in: r) : codex(in: r) }
}

struct ProviderMark: View {
    let provider: Provider
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            let path = Path(Marks.path(provider, in: r))
            if provider == .claude {
                ctx.fill(path, with: .color(.claude))
            } else {
                ctx.stroke(path, with: .color(.primary), lineWidth: max(1, size.width * 0.075))
            }
        }
    }
}

// MARK: Menu bar

enum MenuBarImage {
    /// "✳ 88%  ✿ 66%", drawn as one template image so the menu bar tints it (and inverts it
    /// when highlighted). With numbers off, two short stacked gauges.
    static func render(claude: Double?, codex: Double?, numbers: Bool) -> NSImage {
        numbers ? labelled(claude: claude, codex: codex) : gauges(claude: claude, codex: codex)
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)

    private static func text(_ left: Double?) -> NSAttributedString {
        NSAttributedString(string: left.map { "\(Int(($0 * 100).rounded()))%" } ?? "–",
                           attributes: [.font: font, .foregroundColor: NSColor.black])
    }

    private static func labelled(claude: Double?, codex: Double?) -> NSImage {
        let mark: CGFloat = 12, gap: CGFloat = 3.5, between: CGFloat = 9, h: CGFloat = 18
        let parts = [(Provider.claude, text(claude)), (Provider.codex, text(codex))]
        let width = parts.reduce(0) { $0 + mark + gap + ceil($1.1.size().width) } + between
        let img = NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
            for (p, t) in parts {
                let r = CGRect(x: x, y: (h - mark) / 2, width: mark, height: mark)
                ctx.addPath(Marks.path(p, in: r))
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.setStrokeColor(NSColor.black.cgColor)
                if p == .claude { ctx.fillPath() } else { ctx.setLineWidth(1.05); ctx.strokePath() }
                x += mark + gap
                let size = t.size()
                t.draw(at: NSPoint(x: x, y: (h - size.height) / 2 + 0.5))
                x += ceil(size.width) + between
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func gauges(claude: Double?, codex: Double?) -> NSImage {
        let w: CGFloat = 18, h: CGFloat = 18, bar: CGFloat = 3.6
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            for (i, left) in [claude, codex].enumerated() {
                let y = i == 0 ? h / 2 + 1.4 : h / 2 - 1.4 - bar
                let track = NSRect(x: 1, y: y, width: w - 2, height: bar)
                NSColor.black.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: bar / 2, yRadius: bar / 2).fill()
                if let left {
                    NSColor.black.setFill()
                    let fill = NSRect(x: 1, y: y, width: max(bar, track.width * left), height: bar)
                    NSBezierPath(roundedRect: fill, xRadius: bar / 2, yRadius: bar / 2).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(.tertiary)
    }
}
