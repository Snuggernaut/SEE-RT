// Renders the SEE-RT app icon (colour-bar test pattern on a curved CRT screen)
// into an .iconset folder. Run via build.sh; iconutil turns it into AppIcon.icns.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = s / 1024
    // macOS icon grid: 824pt body inset 100pt, with a soft drop shadow
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let shape = CGPath(roundedRect: body, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // Dark cabinet bezel
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bezel = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.22, alpha: 1), CGColor(gray: 0.08, alpha: 1)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(bezel, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Screen: slightly bulged rounded rect
    let scr = body.insetBy(dx: 70 * k, dy: 70 * k)
    let p = CGMutablePath()
    let bulge = 22 * k, r = 70 * k
    p.move(to: CGPoint(x: scr.minX + r, y: scr.maxY + bulge * 0.4))
    p.addQuadCurve(to: CGPoint(x: scr.maxX - r, y: scr.maxY + bulge * 0.4), control: CGPoint(x: scr.midX, y: scr.maxY + bulge))
    p.addQuadCurve(to: CGPoint(x: scr.maxX + bulge * 0.4, y: scr.maxY - r), control: CGPoint(x: scr.maxX, y: scr.maxY))
    p.addQuadCurve(to: CGPoint(x: scr.maxX + bulge * 0.4, y: scr.minY + r), control: CGPoint(x: scr.maxX + bulge, y: scr.midY))
    p.addQuadCurve(to: CGPoint(x: scr.maxX - r, y: scr.minY - bulge * 0.4), control: CGPoint(x: scr.maxX, y: scr.minY))
    p.addQuadCurve(to: CGPoint(x: scr.minX + r, y: scr.minY - bulge * 0.4), control: CGPoint(x: scr.midX, y: scr.minY - bulge))
    p.addQuadCurve(to: CGPoint(x: scr.minX - bulge * 0.4, y: scr.minY + r), control: CGPoint(x: scr.minX, y: scr.minY))
    p.addQuadCurve(to: CGPoint(x: scr.minX - bulge * 0.4, y: scr.maxY - r), control: CGPoint(x: scr.minX - bulge, y: scr.midY))
    p.addQuadCurve(to: CGPoint(x: scr.minX + r, y: scr.maxY + bulge * 0.4), control: CGPoint(x: scr.minX, y: scr.maxY))
    p.closeSubpath()
    ctx.addPath(p); ctx.clip()

    // Seven colour bars, same colours as the app's test pattern
    let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.92, 0.92, 0.92), (0.92, 0.90, 0.22), (0.12, 0.92, 0.90), (0.16, 0.86, 0.26),
        (0.92, 0.18, 0.80), (0.92, 0.12, 0.25), (0.12, 0.16, 0.92),
    ]
    let full = scr.insetBy(dx: -bulge, dy: -bulge)
    let bw = full.width / CGFloat(bars.count)
    for (i, c) in bars.enumerated() {
        ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        ctx.fill(CGRect(x: full.minX + CGFloat(i) * bw, y: full.minY, width: bw + 1, height: full.height))
    }
    // Scanlines (skipped at tiny sizes where they'd just smear)
    if px >= 64 {
        let period = max(2, s / 96)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.28))
        var y = full.minY
        while y < full.maxY { ctx.fill(CGRect(x: full.minX, y: y, width: full.width, height: period * 0.45)); y += period }
    }
    // Green "VIDEO" OSD, as in the photo
    if px >= 128 {
        let font = NSFont.monospacedSystemFont(ofSize: 92 * k, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(srgbRed: 0.35, green: 1, blue: 0.42, alpha: 1),
            .strokeColor: NSColor.black, .strokeWidth: -4.0, .kern: 6 * k,
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("VIDEO" as NSString).draw(at: NSPoint(x: scr.minX + 34 * k, y: scr.maxY - 150 * k), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
    // Vignette + glass highlight
    let vig = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.55)] as CFArray, locations: [0.55, 1])!
    ctx.drawRadialGradient(vig, startCenter: CGPoint(x: scr.midX, y: scr.midY), startRadius: 0,
                           endCenter: CGPoint(x: scr.midX, y: scr.midY), endRadius: scr.width * 0.75, options: [])
    let hl = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.28), CGColor(gray: 1, alpha: 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: scr.minX + scr.width * 0.28, y: scr.maxY - scr.height * 0.15), startRadius: 0,
                           endCenter: CGPoint(x: scr.minX + scr.width * 0.28, y: scr.maxY - scr.height * 0.15), endRadius: scr.width * 0.45, options: [])
    ctx.restoreGState()

    // Thin rim highlight on the cabinet edge
    ctx.addPath(shape); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12)); ctx.setLineWidth(max(1, 3 * k)); ctx.strokePath()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
