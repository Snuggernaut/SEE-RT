import AppKit

/// What the TV's green on-screen display is showing. Rendered into a 640x480
/// layer that the shader composites *before* scanlines, so it looks burned into the raster.
struct OSDState: Equatable {
    var topLeft: String?
    var topLeft2: String?
    var channel: String?
    var title: String?
    var center: String?
    var volume: Int?
    var bar: Int?            // picture setting 0...100
    var barLabel: String?
    var progress: Double?
    var progressText: String?
}

enum OSDRenderer {
    static let width = 640
    static let height = 480
    static let green = NSColor(srgbRed: 0.35, green: 1.0, blue: 0.42, alpha: 1)

    static func makeContext(width: Int = width, height: Int = height) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    /// Classic seven-bar test pattern shown when no tape is "in".
    static func colorBars() -> CGContext {
        let ctx = makeContext()
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.92, 0.92, 0.92), (0.92, 0.90, 0.22), (0.12, 0.92, 0.90), (0.16, 0.86, 0.26),
            (0.92, 0.18, 0.80), (0.92, 0.12, 0.25), (0.12, 0.16, 0.92),
        ]
        let bw = CGFloat(width) / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * bw, y: 0, width: bw + 1, height: CGFloat(height)))
        }
        return ctx
    }

    private static func attrs(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowOffset = NSSize(width: 2, height: -2)
        shadow.shadowBlurRadius = 0
        return [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .heavy),
            .foregroundColor: green,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0,
            .shadow: shadow,
            .kern: size * 0.08,
        ]
    }

    static func draw(_ s: OSDState, in ctx: CGContext) {
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState(); ctx.restoreGState() }

        let margin: CGFloat = 50
        if let t = s.topLeft { t.draw(at: NSPoint(x: margin, y: 34), withAttributes: attrs(30)) }
        if let t = s.topLeft2 { t.draw(at: NSPoint(x: margin, y: 72), withAttributes: attrs(22)) }
        if let c = s.channel {
            let a = attrs(42)
            let sz = c.size(withAttributes: a)
            c.draw(at: NSPoint(x: CGFloat(width) - margin - sz.width, y: 30), withAttributes: a)
        }
        if let c = s.center {
            let a = attrs(34)
            let sz = c.size(withAttributes: a)
            c.draw(at: NSPoint(x: (CGFloat(width) - sz.width) / 2, y: (CGFloat(height) - sz.height) / 2), withAttributes: a)
        }

        // Bottom slot: volume > progress > title
        let barRect = NSRect(x: margin, y: 404, width: CGFloat(width) - margin * 2, height: 18)
        if let v = s.volume ?? s.bar {
            (s.volume != nil ? "VOLUME" : s.barLabel ?? "").draw(at: NSPoint(x: margin, y: 368), withAttributes: attrs(22))
            let segs = 25
            let gap: CGFloat = 4
            let segW = (barRect.width - gap * CGFloat(segs - 1)) / CGFloat(segs)
            let lit = Int((Double(v) / 100 * Double(segs)).rounded())
            for i in 0..<segs {
                let r = NSRect(x: barRect.minX + CGFloat(i) * (segW + gap), y: barRect.minY, width: segW, height: barRect.height)
                NSColor.black.setFill(); r.insetBy(dx: -1.5, dy: -1.5).fill()
                (i < lit ? green : green.withAlphaComponent(0.18)).setFill(); r.fill()
            }
        } else if let p = s.progress {
            if let t = s.progressText { t.draw(at: NSPoint(x: margin, y: 368), withAttributes: attrs(22)) }
            NSColor.black.setFill(); barRect.insetBy(dx: -3, dy: -3).fill()
            green.setFill(); barRect.insetBy(dx: -1, dy: -1).fill()
            NSColor.black.setFill(); barRect.insetBy(dx: 1, dy: 1).fill()
            green.setFill()
            NSRect(x: barRect.minX + 3, y: barRect.minY + 3,
                   width: (barRect.width - 6) * CGFloat(min(max(p, 0), 1)), height: barRect.height - 6).fill()
        } else if let t = s.title {
            let name = t.count > 34 ? String(t.prefix(33)) + "…" : t
            name.uppercased().draw(at: NSPoint(x: margin, y: 396), withAttributes: attrs(20))
        }
    }
}
