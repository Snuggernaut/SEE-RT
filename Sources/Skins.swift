import AppKit

// MARK: - Finishes (cabinet colours)

/// A cabinet colour. Surfaces are drawn as shades of `base`, so every skin
/// can be recoloured without separate artwork.
struct Finish {
    let name: String
    let r: CGFloat, g: CGFloat, b: CGFloat
    var wood = false

    /// k < 1 darkens toward black, k > 1 lightens toward white (gently, like plastic sheen).
    func shade(_ k: CGFloat, _ a: CGFloat = 1) -> NSColor {
        func f(_ c: CGFloat) -> CGFloat { k <= 1 ? c * k : min(1, c + (1 - c) * (k - 1) * 0.165) }
        return NSColor(srgbRed: f(r), green: f(g), blue: f(b), alpha: a)
    }
    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.42 }
    /// Printed labels: light on dark plastic, dark on light plastic.
    var ink: NSColor { isLight ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 0.55, alpha: 1) }
    var brandInk: NSColor { isLight ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.80, alpha: 1) }
}

/// What the cabinet needs to know to draw its controls.
struct SkinState {
    var pressed: TVButton?
    var scan: TVController.ScanMode = .none
    var poweredOn = true
    var channel = 0
    var volume = 70
    var brightness = 50
    var saturation = 50
    var brand = Cabinet.brand
}

/// A TV cabinet design. All geometry is in the skin's own design units
/// (y grows downward); the screen rect must be 4:3.
@MainActor
protocol TVSkin {
    var id: String { get }
    var name: String { get }
    var design: NSSize { get }
    var screenRect: NSRect { get }
    /// Corner rounding of the picture tube, in design units.
    var screenCorner: CGFloat { get }
    /// The cabinet's outer bounds, used for the resize edges.
    var outline: NSRect { get }
    var finishes: [Finish] { get }
    func hitRect(_ b: TVButton) -> NSRect?
    func draw(_ f: Finish, _ s: SkinState)
}

@MainActor
enum Skins {
    static let all: [TVSkin] = [LivingRoomSkin(), WoodConsoleSkin(), ProMonitorSkin(), SpaceAgeSkin()]
    static func named(_ id: String?) -> TVSkin { all.first { $0.id == id } ?? all[0] }
}

// MARK: - Shared drawing helpers

private func gray(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v) / 255, green: CGFloat(v) / 255, blue: CGFloat(v + 2) / 255, alpha: a)
}

private func latched(_ b: TVButton, _ s: SkinState) -> Bool {
    (b == .rewind && s.scan == .rewind) || (b == .fastForward && s.scan == .forward)
}

private let latchGreen = NSColor(srgbRed: 0.4, green: 1, blue: 0.5, alpha: 1)

/// Brand text centred on `center`, shrunk to fit `maxWidth`.
private func drawBrand(_ text: String, center: NSPoint, maxWidth: CGFloat, size: CGFloat, color: NSColor,
                       font: String = "TimesNewRomanPS-BoldMT", kern: CGFloat = 1 / 6) {
    guard !text.isEmpty else { return }
    func attrs(_ s: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont(name: font, size: s) ?? NSFont.boldSystemFont(ofSize: s), .foregroundColor: color, .kern: s * kern]
    }
    var sz = size
    let w = text.size(withAttributes: attrs(sz)).width
    if w > maxWidth { sz = max(8, sz * maxWidth / w) }
    let a = attrs(sz)
    let b = text.size(withAttributes: a)
    text.draw(at: NSPoint(x: center.x - b.width / 2, y: center.y - b.height / 2), withAttributes: a)
}

private func drawCentered(_ s: String, x: CGFloat, y: CGFloat, _ attrs: [NSAttributedString.Key: Any]) {
    let w = s.size(withAttributes: attrs).width
    s.draw(at: NSPoint(x: x - w / 2, y: y), withAttributes: attrs)
}

private func drawGlyph(_ b: TVButton, in r: NSRect, color: NSColor, size: CGFloat, down: Bool) {
    guard let g = b.glyph else { return }
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color]
    let sz = g.size(withAttributes: a)
    g.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2 + (down ? 0.5 : 0)), withAttributes: a)
}

private func drawLED(_ led: NSRect, on: Bool) {
    if on {
        NSGradient(colors: [NSColor(srgbRed: 0.3, green: 1, blue: 0.4, alpha: 0.35), .clear])!
            .draw(in: NSBezierPath(ovalIn: led.insetBy(dx: -led.width * 0.7, dy: -led.height * 0.7)), relativeCenterPosition: .zero)
    }
    (on ? NSColor(srgbRed: 0.35, green: 1, blue: 0.45, alpha: 1)
        : NSColor(srgbRed: 0.55, green: 0.08, blue: 0.06, alpha: 1)).setFill()
    NSBezierPath(ovalIn: led).fill()
}

/// Small deterministic random numbers so textures look the same every redraw.
private struct Seeded {
    var s: UInt64
    mutating func next() -> CGFloat {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((s >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
}

// MARK: - Living Room '98 (black flat-front set from the original photo)

struct LivingRoomSkin: TVSkin {
    let id = "livingRoom98"
    let name = "Living Room '98"
    let design = NSSize(width: 1000, height: 845)
    let screenRect = NSRect(x: 100, y: 77, width: 800, height: 600)
    let screenCorner: CGFloat = 26
    let outline = NSRect(x: 10, y: 8, width: 980, height: 828)
    private let openingRect = NSRect(x: 80, y: 58, width: 840, height: 638)

    let finishes: [Finish] = [
        Finish(name: "Black", r: 0.141, g: 0.141, b: 0.149),
        Finish(name: "Charcoal Grey", r: 0.30, g: 0.30, b: 0.315),
        Finish(name: "Silver", r: 0.66, g: 0.67, b: 0.69),
        Finish(name: "Putty Beige", r: 0.78, g: 0.74, b: 0.64),
        Finish(name: "White", r: 0.86, g: 0.86, b: 0.84),
    ]

    func hitRect(_ b: TVButton) -> NSRect? {
        let y: CGFloat = 766, h: CGFloat = 15
        switch b {
        case .open:        return NSRect(x: 322, y: y, width: 36, height: h)
        case .rewind:      return NSRect(x: 370, y: y, width: 34, height: h)
        case .play:        return NSRect(x: 408, y: y, width: 40, height: h)
        case .fastForward: return NSRect(x: 452, y: y, width: 34, height: h)
        case .volDown:     return NSRect(x: 500, y: y, width: 32, height: h)
        case .volUp:       return NSRect(x: 536, y: y, width: 32, height: h)
        case .chDown:      return NSRect(x: 584, y: y, width: 32, height: h)
        case .chUp:        return NSRect(x: 620, y: y, width: 32, height: h)
        case .power:       return NSRect(x: 668, y: y, width: 44, height: h)
        default:           return nil
        }
    }

    func draw(_ f: Finish, _ s: SkinState) {
        // Stand
        let base = NSBezierPath()
        base.move(to: NSPoint(x: 175, y: 790))
        base.line(to: NSPoint(x: 825, y: 790))
        base.line(to: NSPoint(x: 848, y: 836))
        base.line(to: NSPoint(x: 152, y: 836))
        base.close()
        NSGradient(colors: [f.shade(0.65), f.shade(0.28)])!.draw(in: base, angle: 90)

        // Shell
        let shell = NSBezierPath(roundedRect: NSRect(x: 10, y: 8, width: 980, height: 797), xRadius: 46, yRadius: 46)
        NSGradient(colors: [f.shade(1.45), f.shade(1.0), f.shade(0.76)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
            .draw(in: shell, angle: 90)
        NSGradient(colors: [gray(0, 0.28), gray(0, 0), gray(0, 0), gray(0, 0.32)],
                   atLocations: [0, 0.07, 0.93, 1], colorSpace: .sRGB)!.draw(in: shell, angle: 0)
        NSGradient(colors: [gray(255, 0.06), gray(255, 0)])!
            .draw(in: shell, relativeCenterPosition: NSPoint(x: -0.6, y: -0.8))
        gray(255, 0.10).setStroke()
        let rim = NSBezierPath(roundedRect: NSRect(x: 12, y: 10, width: 976, height: 793), xRadius: 44, yRadius: 44)
        rim.lineWidth = 2; rim.stroke()
        NSColor.black.setStroke(); shell.lineWidth = 2; shell.stroke()
        let face = NSBezierPath(roundedRect: NSRect(x: 26, y: 24, width: 948, height: 765), xRadius: 34, yRadius: 34)
        gray(255, 0.04).setStroke(); face.lineWidth = 1.5; face.stroke()

        // Screen bezel: sloped lip into a dark recess
        let lip = NSBezierPath(roundedRect: openingRect.insetBy(dx: -10, dy: -10), xRadius: 44, yRadius: 44)
        NSGradient(colors: [f.shade(0.33), f.shade(0.83), f.shade(1.7)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
            .draw(in: lip, angle: 90)
        let opening = NSBezierPath(roundedRect: openingRect, xRadius: 34, yRadius: 34)
        NSGradient(colors: [gray(4), gray(14)])!.draw(in: opening, angle: 90)
        gray(0, 0.9).setStroke(); opening.lineWidth = 2; opening.stroke()

        drawBrand(s.brand, center: NSPoint(x: 500, y: 723), maxWidth: 360, size: 30, color: f.brandInk)

        // Speaker grille
        let g = NSRect(x: 70, y: 712, width: 240, height: 74)
        f.shade(0.62).setFill()
        NSBezierPath(roundedRect: g, xRadius: 8, yRadius: 8).fill()
        gray(4).setFill()
        var y = g.minY + 8
        while y < g.maxY - 4 {
            var x = g.minX + 8
            while x < g.maxX - 4 {
                NSBezierPath(ovalIn: NSRect(x: x - 1.7, y: y - 1.7, width: 3.4, height: 3.4)).fill()
                x += 7
            }
            y += 7
        }

        // Controls
        let label: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .foregroundColor: f.ink, .kern: 0.6,
        ]
        func r(_ b: TVButton) -> NSRect { hitRect(b)! }
        drawCentered("OPEN", x: r(.open).midX, y: 751, label)
        drawCentered("REW", x: r(.rewind).midX, y: 751, label)
        drawCentered("PLAY", x: r(.play).midX, y: 751, label)
        drawCentered("FF", x: r(.fastForward).midX, y: 751, label)
        drawCentered("–  VOLUME  +", x: (r(.volDown).minX + r(.volUp).maxX) / 2, y: 751, label)
        drawCentered("–  CHANNEL  +", x: (r(.chDown).minX + r(.chUp).maxX) / 2, y: 751, label)
        drawCentered("POWER", x: r(.power).midX, y: 751, label)
        for b in TVButton.allCases where hitRect(b) != nil {
            let p = NSBezierPath(roundedRect: r(b), xRadius: 3, yRadius: 3)
            let lat = latched(b, s)
            let down = s.pressed == b || lat
            NSGradient(colors: down ? [f.shade(0.72), f.shade(1.1)] : [f.shade(2.3), f.shade(1.22)])!.draw(in: p, angle: 90)
            gray(0, 0.85).setStroke(); p.lineWidth = 1; p.stroke()
            drawGlyph(b, in: r(b), color: lat ? latchGreen : (f.isLight ? gray(60) : gray(185)), size: 7.5, down: down)
        }
        drawLED(NSRect(x: 721, y: 770, width: 9, height: 9), on: s.poweredOn)

        // AV jacks
        let block = NSRect(x: 768, y: 752, width: 96, height: 50)
        let bp = NSBezierPath(roundedRect: block, xRadius: 6, yRadius: 6)
        NSGradient(colors: [f.shade(1.0), f.shade(0.55)])!.draw(in: bp, angle: 90)
        gray(0).setStroke(); bp.lineWidth = 1.5; bp.stroke()
        for (x, c) in [(CGFloat(796), NSColor(srgbRed: 0.93, green: 0.93, blue: 0.9, alpha: 1)),
                       (836, NSColor(srgbRed: 0.8, green: 0.1, blue: 0.12, alpha: 1))] {
            let ring = NSRect(x: x - 10, y: 767, width: 20, height: 20)
            c.setFill(); NSBezierPath(ovalIn: ring).fill()
            gray(0, 0.5).setStroke(); NSBezierPath(ovalIn: ring).stroke()
            gray(150).setFill(); NSBezierPath(ovalIn: ring.insetBy(dx: 5, dy: 5)).fill()
            gray(5).setFill(); NSBezierPath(ovalIn: ring.insetBy(dx: 7.5, dy: 7.5)).fill()
        }
    }
}

// MARK: - Wood-Grain Console '82

/// Wide faux-wood cabinet: silver-trimmed tube on the left; control panel on the
/// right with a rotary channel dial, volume knob, piano-key buttons and a cloth speaker.
struct WoodConsoleSkin: TVSkin {
    let id = "woodConsole82"
    let name = "Wood-Grain Console '82"
    let design = NSSize(width: 1250, height: 880)
    let screenRect = NSRect(x: 100, y: 92, width: 800, height: 600)
    let screenCorner: CGFloat = 48            // older tubes are rounder
    let outline = NSRect(x: 10, y: 10, width: 1230, height: 864)
    private let cabinet = NSRect(x: 10, y: 10, width: 1230, height: 812)
    private let trim = NSRect(x: 46, y: 46, width: 904, height: 740)
    private let opening = NSRect(x: 84, y: 76, width: 832, height: 632)
    private let panel = NSRect(x: 974, y: 46, width: 232, height: 740)
    private let dialCenter = NSPoint(x: 1090, y: 222)
    private let dialRadius: CGFloat = 64
    private let volCenter = NSPoint(x: 1090, y: 382)
    private let volRadius: CGFloat = 36

    let finishes: [Finish] = [
        Finish(name: "Walnut", r: 0.36, g: 0.22, b: 0.13, wood: true),
        Finish(name: "Oak", r: 0.62, g: 0.44, b: 0.26, wood: true),
        Finish(name: "Dark Cherry", r: 0.38, g: 0.15, b: 0.10, wood: true),
    ]

    func hitRect(_ b: TVButton) -> NSRect? {
        let keyY: CGFloat = 462, keyH: CGFloat = 32, keyW: CGFloat = 46
        func key(_ i: CGFloat) -> NSRect { NSRect(x: 991 + i * 52, y: keyY, width: keyW, height: keyH) }
        switch b {
        // Dials: click the left half to turn down, the right half to turn up
        case .chDown:  return NSRect(x: dialCenter.x - dialRadius - 8, y: dialCenter.y - dialRadius - 8, width: dialRadius + 8, height: dialRadius * 2 + 16)
        case .chUp:    return NSRect(x: dialCenter.x, y: dialCenter.y - dialRadius - 8, width: dialRadius + 8, height: dialRadius * 2 + 16)
        case .volDown: return NSRect(x: volCenter.x - volRadius - 6, y: volCenter.y - volRadius - 6, width: volRadius + 6, height: volRadius * 2 + 12)
        case .volUp:   return NSRect(x: volCenter.x, y: volCenter.y - volRadius - 6, width: volRadius + 6, height: volRadius * 2 + 12)
        case .open:        return key(0)
        case .rewind:      return key(1)
        case .play:        return key(2)
        case .fastForward: return key(3)
        case .power:       return NSRect(x: 991, y: 520, width: 92, height: 28)
        default:           return nil
        }
    }

    func draw(_ f: Finish, _ s: SkinState) {
        // Plinth and feet
        for x in [CGFloat(80), 1090] {
            NSColor(white: 0.06, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 840, width: 80, height: 32), xRadius: 4, yRadius: 4).fill()
        }
        let plinth = NSBezierPath(roundedRect: NSRect(x: 34, y: 812, width: 1182, height: 36), xRadius: 6, yRadius: 6)
        NSGradient(colors: [f.shade(0.5), f.shade(0.3)])!.draw(in: plinth, angle: 90)

        // Wood cabinet
        let cab = NSBezierPath(roundedRect: cabinet, xRadius: 16, yRadius: 16)
        NSGradient(colors: [f.shade(1.25), f.shade(1.0), f.shade(0.82)], atLocations: [0, 0.4, 1], colorSpace: .sRGB)!
            .draw(in: cab, angle: 90)
        NSGraphicsContext.saveGraphicsState()
        cab.addClip()
        drawWoodGrain(cabinet, f)
        // edge shading so it reads as a solid box
        NSGradient(colors: [gray(0, 0.35), gray(0, 0), gray(0, 0), gray(0, 0.4)],
                   atLocations: [0, 0.04, 0.96, 1], colorSpace: .sRGB)!.draw(in: cab, angle: 0)
        NSGradient(colors: [gray(255, 0.10), gray(255, 0), gray(0, 0), gray(0, 0.35)],
                   atLocations: [0, 0.03, 0.95, 1], colorSpace: .sRGB)!.draw(in: cab, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.8).setStroke(); cab.lineWidth = 2; cab.stroke()

        // Silver trim around the tube
        let trimPath = NSBezierPath(roundedRect: trim, xRadius: 26, yRadius: 26)
        drawBrushedMetal(trimPath, trim, light: 0.80, dark: 0.50)
        NSColor.black.withAlphaComponent(0.6).setStroke(); trimPath.lineWidth = 1.5; trimPath.stroke()
        let mask = NSBezierPath(roundedRect: trim.insetBy(dx: 16, dy: 16), xRadius: 18, yRadius: 18)
        NSGradient(colors: [gray(10), gray(26)])!.draw(in: mask, angle: 90)
        let lip = NSBezierPath(roundedRect: opening.insetBy(dx: -8, dy: -8), xRadius: 66, yRadius: 66)
        NSGradient(colors: [gray(6), gray(22), gray(48)], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!.draw(in: lip, angle: 90)
        let open = NSBezierPath(roundedRect: opening, xRadius: 60, yRadius: 60)
        NSGradient(colors: [gray(3), gray(12)])!.draw(in: open, angle: 90)

        // Control panel
        let pp = NSBezierPath(roundedRect: panel, xRadius: 16, yRadius: 16)
        NSGradient(colors: [gray(46), gray(26)])!.draw(in: pp, angle: 90)
        NSGraphicsContext.saveGraphicsState()
        pp.addClip()
        var rng = Seeded(s: 7)
        var y = panel.minY
        while y < panel.maxY {   // fine vertical brushing
            NSColor(white: 1, alpha: 0.015 + rng.next() * 0.02).setFill()
            NSRect(x: panel.minX, y: y, width: panel.width, height: 1).fill()
            y += 2
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.75, alpha: 0.8).setStroke(); pp.lineWidth = 2; pp.stroke()

        drawBrand(s.brand, center: NSPoint(x: panel.midX, y: 92), maxWidth: 196, size: 28, color: NSColor(white: 0.86, alpha: 1))

        let label: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(white: 0.7, alpha: 1), .kern: 1.5,
        ]
        drawChannelDial(s)
        drawCentered("CHANNEL", x: dialCenter.x, y: dialCenter.y + dialRadius + 26, label)
        drawVolumeKnob(s)
        drawCentered("VOLUME", x: volCenter.x, y: volCenter.y + volRadius + 12, label)

        // Piano keys
        for b in [TVButton.open, .rewind, .play, .fastForward] {
            let r = hitRect(b)!
            let lat = latched(b, s)
            let down = s.pressed == b || lat
            let key = NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: down ? 2 : 0), xRadius: 3, yRadius: 3)
            NSGradient(colors: down ? [gray(150), gray(185)] : [gray(232), gray(176)])!.draw(in: key, angle: 90)
            gray(0, 0.7).setStroke(); key.lineWidth = 1; key.stroke()
            drawGlyph(b, in: r.offsetBy(dx: 0, dy: down ? 2 : 0), color: lat ? NSColor(srgbRed: 0.1, green: 0.6, blue: 0.2, alpha: 1) : gray(45), size: 11, down: false)
        }

        // Power push button + LED
        let pr = hitRect(.power)!
        let pDown = s.pressed == .power
        let pb = NSBezierPath(roundedRect: pr.offsetBy(dx: 0, dy: pDown ? 2 : 0), xRadius: 4, yRadius: 4)
        NSGradient(colors: pDown ? [gray(150), gray(185)] : [gray(232), gray(176)])!.draw(in: pb, angle: 90)
        gray(0, 0.7).setStroke(); pb.lineWidth = 1; pb.stroke()
        drawCentered("POWER", x: pr.midX, y: pr.midY - 7 + (pDown ? 2 : 0),
                     [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: gray(45), .kern: 1.2])
        drawLED(NSRect(x: 1130, y: 528, width: 12, height: 12), on: s.poweredOn)

        // Cloth speaker
        let spk = NSRect(x: 991, y: 566, width: 198, height: 202)
        let sp = NSBezierPath(roundedRect: spk, xRadius: 8, yRadius: 8)
        NSColor(srgbRed: 0.13, green: 0.11, blue: 0.09, alpha: 1).setFill(); sp.fill()
        NSGraphicsContext.saveGraphicsState()
        sp.addClip()
        var t = spk.minX
        while t < spk.maxX { NSColor(white: 1, alpha: 0.05).setFill(); NSRect(x: t, y: spk.minY, width: 1.2, height: spk.height).fill(); t += 3 }
        t = spk.minY
        while t < spk.maxY { NSColor(white: 0, alpha: 0.25).setFill(); NSRect(x: spk.minX, y: t, width: spk.width, height: 1.2).fill(); t += 3 }
        NSGradient(colors: [gray(0, 0), gray(0, 0.45)])!.draw(in: sp, relativeCenterPosition: .zero)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.7, alpha: 0.7).setStroke(); sp.lineWidth = 2; sp.stroke()
    }

    private func drawWoodGrain(_ r: NSRect, _ f: Finish) {
        var rng = Seeded(s: 1982)
        let lines = 140
        for i in 0..<lines {
            let y0 = r.minY + CGFloat(i) / CGFloat(lines) * r.height + rng.next() * 4
            let amp = 1.5 + rng.next() * 5
            let freq = 0.004 + rng.next() * 0.006
            let phase = rng.next() * 6.28
            let p = NSBezierPath()
            var x = r.minX
            p.move(to: NSPoint(x: x, y: y0 + sin(phase) * amp))
            while x < r.maxX {
                x += 24
                p.line(to: NSPoint(x: x, y: y0 + sin(x * freq + phase) * amp + sin(x * freq * 3.1) * amp * 0.3))
            }
            let dark = rng.next() < 0.75
            (dark ? f.shade(0.45, 0.30 + rng.next() * 0.4) : f.shade(1.9, 0.14 + rng.next() * 0.2)).setStroke()
            p.lineWidth = 0.6 + rng.next() * 2.2
            p.stroke()
        }
        // a couple of knots
        for (cx, cy) in [(CGFloat(330), CGFloat(790)), (CGFloat(1150), CGFloat(30))] {
            for k in 0..<6 {
                let w = 26 - CGFloat(k) * 4, h = 9 - CGFloat(k) * 1.3
                f.shade(0.5, 0.25).setStroke()
                let o = NSBezierPath(ovalIn: NSRect(x: cx - w, y: cy - h, width: w * 2, height: h * 2))
                o.lineWidth = 1.2; o.stroke()
            }
        }
    }

    private func drawBrushedMetal(_ path: NSBezierPath, _ r: NSRect, light: CGFloat, dark: CGFloat) {
        NSGradient(colors: [NSColor(white: light, alpha: 1), NSColor(white: (light + dark) / 2, alpha: 1), NSColor(white: dark, alpha: 1)],
                   atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: path, angle: 90)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        var rng = Seeded(s: 42)
        var y = r.minY
        while y < r.maxY {
            NSColor(white: rng.next() < 0.5 ? 1 : 0, alpha: 0.03 + rng.next() * 0.04).setFill()
            NSRect(x: r.minX, y: y, width: r.width, height: 1).fill()
            y += 1.5
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Rotary channel selector: 12 detents marked 2–13; the pointer follows the current channel.
    private func drawChannelDial(_ s: SkinState) {
        let c = dialCenter, R = dialRadius
        // numbered ring
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - R - 22, y: c.y - R - 22, width: (R + 22) * 2, height: (R + 22) * 2))
        NSGradient(colors: [gray(70), gray(36)])!.draw(in: ring, angle: 90)
        let numAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        for i in 0..<12 {
            let a = (-90 + Double(i) * 30) * .pi / 180
            let t = "\(i + 2)"
            let sz = t.size(withAttributes: numAttrs)
            t.draw(at: NSPoint(x: c.x + cos(a) * (R + 12) - sz.width / 2, y: c.y + sin(a) * (R + 12) - sz.height / 2), withAttributes: numAttrs)
        }
        // knob body with grip ridges
        let pressedHalf = s.pressed == .chDown || s.pressed == .chUp
        let knob = NSBezierPath(ovalIn: NSRect(x: c.x - R + 6, y: c.y - R + 6, width: (R - 6) * 2, height: (R - 6) * 2))
        NSGradient(colors: pressedHalf ? [gray(40), gray(20)] : [gray(64), gray(22)])!.draw(in: knob, relativeCenterPosition: NSPoint(x: -0.3, y: -0.4))
        gray(0, 0.9).setStroke(); knob.lineWidth = 1.5; knob.stroke()
        for i in 0..<36 {
            let a = Double(i) * 10 * .pi / 180
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x + cos(a) * (R - 12), y: c.y + sin(a) * (R - 12)))
            p.line(to: NSPoint(x: c.x + cos(a) * (R - 7), y: c.y + sin(a) * (R - 7)))
            gray(0, 0.5).setStroke(); p.lineWidth = 1.5; p.stroke()
        }
        // centre bar with pointer
        let a = (-90 + Double(((s.channel % 12) + 12) % 12) * 30) * .pi / 180
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(a + .pi / 2))
        let bar = NSBezierPath(roundedRect: NSRect(x: -11, y: -R + 14, width: 22, height: (R - 14) * 2), xRadius: 9, yRadius: 9)
        NSGradient(colors: [gray(205), gray(130)])!.draw(in: bar, angle: 0)
        gray(0, 0.6).setStroke(); bar.lineWidth = 1; bar.stroke()
        NSColor(srgbRed: 0.85, green: 0.2, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: -2.5, y: -R + 18, width: 5, height: 20), xRadius: 2, yRadius: 2).fill()
        ctx.restoreGState()
    }

    /// Silver volume knob; the pointer sweeps from 7 o'clock (0) to 5 o'clock (100).
    private func drawVolumeKnob(_ s: SkinState) {
        let c = volCenter, R = volRadius
        let pressedHalf = s.pressed == .volDown || s.pressed == .volUp
        let skirt = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        NSGradient(colors: [gray(60), gray(20)])!.draw(in: skirt, angle: 90)
        let cap = NSBezierPath(ovalIn: NSRect(x: c.x - R + 7, y: c.y - R + 7, width: (R - 7) * 2, height: (R - 7) * 2))
        NSGradient(colors: pressedHalf ? [gray(160), gray(110)] : [gray(225), gray(140)])!.draw(in: cap, relativeCenterPosition: NSPoint(x: -0.3, y: -0.4))
        gray(0, 0.6).setStroke(); cap.lineWidth = 1; cap.stroke()
        let a = (135 + Double(s.volume) / 100 * 270) * .pi / 180   // 135° → 405°
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x + cos(a) * 8, y: c.y + sin(a) * 8))
        p.line(to: NSPoint(x: c.x + cos(a) * (R - 10), y: c.y + sin(a) * (R - 10)))
        NSColor(srgbRed: 0.85, green: 0.2, blue: 0.15, alpha: 1).setStroke(); p.lineWidth = 3; p.lineCapStyle = .round; p.stroke()
    }
}

// MARK: - Knob shared by the newer skins

/// Round knob; `frac` 0…1 sweeps the pointer from 7 o'clock to 5 o'clock.
private func drawKnob(_ c: NSPoint, _ R: CGFloat, frac: Double, pressed: Bool, cap: (CGFloat, CGFloat) = (0.88, 0.55),
                      pointer: NSColor = NSColor(srgbRed: 0.9, green: 0.25, blue: 0.15, alpha: 1)) {
    let skirt = NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
    NSGradient(colors: [gray(55), gray(15)])!.draw(in: skirt, angle: 90)
    let inset = R * 0.18
    let capPath = NSBezierPath(ovalIn: NSRect(x: c.x - R + inset, y: c.y - R + inset, width: (R - inset) * 2, height: (R - inset) * 2))
    let hi = pressed ? cap.0 - 0.15 : cap.0, lo = pressed ? cap.1 - 0.1 : cap.1
    NSGradient(colors: [NSColor(white: hi, alpha: 1), NSColor(white: lo, alpha: 1)])!
        .draw(in: capPath, relativeCenterPosition: NSPoint(x: -0.3, y: -0.4))
    gray(0, 0.6).setStroke(); capPath.lineWidth = 1; capPath.stroke()
    let a = (135 + frac * 270) * .pi / 180
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x + cos(a) * R * 0.2, y: c.y + sin(a) * R * 0.2))
    p.line(to: NSPoint(x: c.x + cos(a) * (R - inset - 3), y: c.y + sin(a) * (R - inset - 3)))
    pointer.setStroke(); p.lineWidth = max(2, R * 0.12); p.lineCapStyle = .round; p.stroke()
}

/// Left half of a knob turns it down, right half up.
private func knobHalves(_ c: NSPoint, _ R: CGFloat) -> (NSRect, NSRect) {
    (NSRect(x: c.x - R - 4, y: c.y - R - 4, width: R + 4, height: R * 2 + 8),
     NSRect(x: c.x, y: c.y - R - 4, width: R + 4, height: R * 2 + 8))
}

// MARK: - Pro Studio Monitor

/// Boxy broadcast/editing monitor: metal case with rack handles, flat-ish tube with
/// tight corners, and a control strip with square buttons and working BRIGHT / CHROMA / VOLUME knobs.
struct ProMonitorSkin: TVSkin {
    let id = "proMonitor"
    let name = "Pro Studio Monitor"
    let design = NSSize(width: 1100, height: 860)
    let screenRect = NSRect(x: 150, y: 70, width: 800, height: 600)
    let screenCorner: CGFloat = 12
    let outline = NSRect(x: 8, y: 16, width: 1084, height: 836)
    private let caseRect = NSRect(x: 62, y: 18, width: 976, height: 810)
    private let bezel = NSRect(x: 82, y: 36, width: 936, height: 774)
    private let opening = NSRect(x: 136, y: 57, width: 828, height: 626)
    private let knobY: CGFloat = 752, knobR: CGFloat = 21
    private let brightC = NSPoint(x: 712, y: 752), chromaC = NSPoint(x: 792, y: 752), volC = NSPoint(x: 872, y: 752)

    let finishes: [Finish] = [
        Finish(name: "Studio Grey", r: 0.50, g: 0.51, b: 0.53),
        Finish(name: "Graphite", r: 0.22, g: 0.22, b: 0.24),
        Finish(name: "Putty", r: 0.70, g: 0.68, b: 0.62),
    ]

    func hitRect(_ b: TVButton) -> NSRect? {
        func sq(_ i: CGFloat) -> NSRect { NSRect(x: 316 + i * 48, y: 740, width: 38, height: 26) }
        switch b {
        case .open: return sq(0)
        case .rewind: return sq(1)
        case .play: return sq(2)
        case .fastForward: return sq(3)
        case .chDown: return sq(4)
        case .chUp: return sq(5)
        case .power: return NSRect(x: 112, y: 738, width: 44, height: 30)
        case .brightDown: return knobHalves(brightC, knobR).0
        case .brightUp: return knobHalves(brightC, knobR).1
        case .satDown: return knobHalves(chromaC, knobR).0
        case .satUp: return knobHalves(chromaC, knobR).1
        case .volDown: return knobHalves(volC, knobR).0
        case .volUp: return knobHalves(volC, knobR).1
        }
    }

    func draw(_ f: Finish, _ s: SkinState) {
        // Rubber feet
        for x in [CGFloat(130), 910] {
            NSColor(white: 0.05, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 820, width: 60, height: 26), xRadius: 5, yRadius: 5).fill()
        }
        // Rack ears with handles
        for (x, flip) in [(CGFloat(8), false), (CGFloat(1032), true)] {
            let ear = NSRect(x: x, y: 40, width: 60, height: 766)
            let ep = NSBezierPath(roundedRect: ear, xRadius: 6, yRadius: 6)
            NSGradient(colors: [f.shade(1.3), f.shade(0.8)])!.draw(in: ep, angle: flip ? 180 : 0)
            gray(0, 0.7).setStroke(); ep.lineWidth = 1.5; ep.stroke()
            for y in [CGFloat(70), 760] {   // screws
                NSGradient(colors: [gray(200), gray(110)])!.draw(in: NSBezierPath(ovalIn: NSRect(x: ear.midX - 7, y: y - 7, width: 14, height: 14)), angle: 90)
                gray(60).setStroke()
                let sl = NSBezierPath(); sl.move(to: NSPoint(x: ear.midX - 5, y: y)); sl.line(to: NSPoint(x: ear.midX + 5, y: y)); sl.lineWidth = 1.5; sl.stroke()
            }
            // chrome handle loop
            let h = NSBezierPath(roundedRect: NSRect(x: ear.midX - 12, y: 180, width: 24, height: 486), xRadius: 12, yRadius: 12)
            NSGradient(colors: [gray(235), gray(150), gray(205)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: h, angle: 0)
            gray(0, 0.5).setStroke(); h.lineWidth = 1; h.stroke()
            let inner = NSBezierPath(roundedRect: NSRect(x: ear.midX - 5, y: 196, width: 10, height: 454), xRadius: 5, yRadius: 5)
            f.shade(0.5).setFill(); inner.fill()
        }

        // Metal case
        let cp = NSBezierPath(roundedRect: caseRect, xRadius: 10, yRadius: 10)
        NSGradient(colors: [f.shade(1.35), f.shade(1.0), f.shade(0.78)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: cp, angle: 90)
        gray(0, 0.85).setStroke(); cp.lineWidth = 2; cp.stroke()

        // Front bezel (darker moulded plastic)
        let bp = NSBezierPath(roundedRect: bezel, xRadius: 8, yRadius: 8)
        NSGradient(colors: [f.shade(0.62), f.shade(0.48)])!.draw(in: bp, angle: 90)
        gray(255, 0.08).setStroke(); bp.lineWidth = 1.5; bp.stroke()

        // Tube opening: tight corners, shallow lip
        let lip = NSBezierPath(roundedRect: opening.insetBy(dx: -6, dy: -6), xRadius: 22, yRadius: 22)
        NSGradient(colors: [gray(8), gray(28), gray(52)], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!.draw(in: lip, angle: 90)
        NSGradient(colors: [gray(3), gray(12)])!.draw(in: NSBezierPath(roundedRect: opening, xRadius: 18, yRadius: 18), angle: 90)

        // Tally light (top-right), lit amber while powered
        let tally = NSRect(x: 966, y: 42, width: 30, height: 10)
        (s.poweredOn ? NSColor(srgbRed: 1, green: 0.62, blue: 0.1, alpha: 1) : gray(40)).setFill()
        NSBezierPath(roundedRect: tally, xRadius: 3, yRadius: 3).fill()

        // Control strip
        let strip = NSRect(x: 96, y: 698, width: 908, height: 100)
        let sp = NSBezierPath(roundedRect: strip, xRadius: 6, yRadius: 6)
        NSGradient(colors: [f.shade(0.42), f.shade(0.34)])!.draw(in: sp, angle: 90)
        gray(0, 0.5).setStroke(); sp.lineWidth = 1; sp.stroke()

        let ink = NSColor(white: 0.78, alpha: 1)
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .foregroundColor: ink, .kern: 0.8]
        drawBrand(s.brand, center: NSPoint(x: 210, y: 714), maxWidth: 190, size: 17, color: NSColor(white: 0.9, alpha: 1),
                  font: "Helvetica-Bold", kern: 0.08)

        // Power rocker + LED
        let pr = hitRect(.power)!
        let pDown = s.pressed == .power
        let rocker = NSBezierPath(roundedRect: pr, xRadius: 4, yRadius: 4)
        NSGradient(colors: pDown ? [gray(30), gray(55)] : [gray(70), gray(25)])!.draw(in: rocker, angle: 90)
        gray(0).setStroke(); rocker.lineWidth = 1; rocker.stroke()
        drawCentered("POWER", x: pr.midX, y: pr.maxY + 6, label)
        drawLED(NSRect(x: 168, y: 748, width: 10, height: 10), on: s.poweredOn)

        // Square buttons
        for (b, t) in [(TVButton.open, "OPEN"), (.rewind, "REW"), (.play, "PLAY"), (.fastForward, "FF"), (.chDown, "CH –"), (.chUp, "CH +")] {
            let r = hitRect(b)!
            let lat = latched(b, s)
            let down = s.pressed == b || lat
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            NSGradient(colors: down ? [gray(40), gray(62)] : [gray(96), gray(52)])!.draw(in: p, angle: 90)
            gray(0).setStroke(); p.lineWidth = 1; p.stroke()
            if b.glyph != nil {
                drawGlyph(b, in: r, color: lat ? latchGreen : gray(215), size: 9, down: down)
            }
            drawCentered(t, x: r.midX, y: r.maxY + 6, label)
        }
        drawCentered("CHANNEL", x: (hitRect(.chDown)!.minX + hitRect(.chUp)!.maxX) / 2, y: 722, label)

        // Knobs
        drawKnob(brightC, knobR, frac: Double(s.brightness) / 100, pressed: s.pressed == .brightDown || s.pressed == .brightUp)
        drawKnob(chromaC, knobR, frac: Double(s.saturation) / 100, pressed: s.pressed == .satDown || s.pressed == .satUp)
        drawKnob(volC, knobR, frac: Double(s.volume) / 100, pressed: s.pressed == .volDown || s.pressed == .volUp)
        drawCentered("BRIGHT", x: brightC.x, y: knobY + knobR + 5, label)
        drawCentered("CHROMA", x: chromaC.x, y: knobY + knobR + 5, label)
        drawCentered("VOLUME", x: volC.x, y: knobY + knobR + 5, label)

        // Vent slots on the right of the strip
        for i in 0..<6 {
            gray(0, 0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: 930 + CGFloat(i) * 11, y: 718, width: 5, height: 60), xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}

// MARK: - Space Age '71

/// Round, helmet-shaped set on a pedestal: glossy sphere, chrome visor around a small
/// rounded tube, and a chrome control plate with round buttons and two knobs.
struct SpaceAgeSkin: TVSkin {
    let id = "spaceAge71"
    let name = "Space Age '71"
    let design = NSSize(width: 900, height: 970)
    let screenRect = NSRect(x: 190, y: 226, width: 520, height: 390)
    let screenCorner: CGFloat = 58
    let outline = NSRect(x: 50, y: 0, width: 800, height: 966)
    private let center = NSPoint(x: 450, y: 440)
    private let radius: CGFloat = 400
    private let visor = NSRect(x: 160, y: 198, width: 580, height: 446)
    private let plate = NSRect(x: 232, y: 664, width: 436, height: 104)
    private let chC = NSPoint(x: 280, y: 704), volC = NSPoint(x: 620, y: 704)

    let finishes: [Finish] = [
        Finish(name: "Tangerine", r: 0.93, g: 0.45, b: 0.12),
        Finish(name: "Space White", r: 0.90, g: 0.90, b: 0.88),
        Finish(name: "Lemon", r: 0.95, g: 0.80, b: 0.18),
        Finish(name: "Cherry Red", r: 0.78, g: 0.10, b: 0.12),
        Finish(name: "Midnight Black", r: 0.12, g: 0.12, b: 0.13),
    ]

    func hitRect(_ b: TVButton) -> NSRect? {
        func round(_ x: CGFloat) -> NSRect { NSRect(x: x - 17, y: 687, width: 34, height: 34) }
        switch b {
        case .open: return round(368)
        case .rewind: return round(422)
        case .play: return round(476)
        case .fastForward: return round(530)
        case .chDown: return knobHalves(chC, 26).0
        case .chUp: return knobHalves(chC, 26).1
        case .volDown: return knobHalves(volC, 26).0
        case .volUp: return knobHalves(volC, 26).1
        case .power: return NSRect(x: 432, y: 734, width: 36, height: 26)
        default: return nil
        }
    }

    private func chrome(_ p: NSBezierPath, angle: CGFloat = 90) {
        NSGradient(colors: [gray(250), gray(160), gray(225), gray(120)], atLocations: [0, 0.45, 0.6, 1], colorSpace: .sRGB)!
            .draw(in: p, angle: angle)
    }

    func draw(_ f: Finish, _ s: SkinState) {
        // Pedestal: chrome neck on a weighted disc
        let disc = NSBezierPath(ovalIn: NSRect(x: 240, y: 892, width: 420, height: 72))
        NSGradient(colors: [f.shade(1.2), f.shade(0.45)])!.draw(in: disc, angle: 90)
        gray(0, 0.6).setStroke(); disc.lineWidth = 1.5; disc.stroke()
        let neck = NSBezierPath(roundedRect: NSRect(x: 418, y: 812, width: 64, height: 104), xRadius: 10, yRadius: 10)
        chrome(neck, angle: 0)
        gray(0, 0.5).setStroke(); neck.lineWidth = 1; neck.stroke()

        // Carry ring on top
        let ring = NSBezierPath(ovalIn: NSRect(x: 420, y: 2, width: 60, height: 60))
        ring.appendOval(in: NSRect(x: 432, y: 14, width: 36, height: 36))
        ring.windingRule = .evenOdd
        chrome(ring)

        // Glossy sphere
        let sphere = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSGradient(colors: [f.shade(2.6), f.shade(1.15), f.shade(0.9), f.shade(0.5)], atLocations: [0, 0.25, 0.6, 1], colorSpace: .sRGB)!
            .draw(in: sphere, relativeCenterPosition: NSPoint(x: -0.35, y: -0.45))
        // rim shadow and specular highlight
        NSGradient(colors: [gray(0, 0), gray(0, 0), gray(0, 0.35)], atLocations: [0, 0.82, 1], colorSpace: .sRGB)!
            .draw(in: sphere, relativeCenterPosition: .zero)
        NSGraphicsContext.saveGraphicsState()
        sphere.addClip()
        let spec = NSBezierPath(ovalIn: NSRect(x: 200, y: 96, width: 220, height: 116))
        NSGradient(colors: [gray(255, 0.5), gray(255, 0)])!.draw(in: spec, relativeCenterPosition: .zero)
        NSGraphicsContext.restoreGraphicsState()
        gray(0, 0.55).setStroke(); sphere.lineWidth = 2; sphere.stroke()

        drawBrand(s.brand, center: NSPoint(x: center.x, y: 166), maxWidth: 260, size: 26, color: f.isLight ? NSColor(white: 0.2, alpha: 0.85) : NSColor(white: 0.92, alpha: 0.9),
                  font: "Futura-Bold", kern: 0.25)

        // Chrome visor around the tube
        let vp = NSBezierPath(roundedRect: visor, xRadius: 86, yRadius: 86)
        chrome(vp)
        gray(0, 0.5).setStroke(); vp.lineWidth = 1.5; vp.stroke()
        let inner = NSBezierPath(roundedRect: visor.insetBy(dx: 16, dy: 16), xRadius: 72, yRadius: 72)
        NSGradient(colors: [gray(6), gray(24)])!.draw(in: inner, angle: 90)
        let open = NSBezierPath(roundedRect: screenRect.insetBy(dx: -8, dy: -8), xRadius: screenCorner + 6, yRadius: screenCorner + 6)
        NSGradient(colors: [gray(3), gray(12)])!.draw(in: open, angle: 90)

        // Chrome control plate
        let pp = NSBezierPath(roundedRect: plate, xRadius: 30, yRadius: 30)
        chrome(pp)
        gray(0, 0.5).setStroke(); pp.lineWidth = 1.5; pp.stroke()
        let ink: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Futura-Medium", size: 9) ?? NSFont.systemFont(ofSize: 9), .foregroundColor: gray(40), .kern: 1]

        drawKnob(chC, 26, frac: Double(((s.channel % 12) + 12) % 12) / 11, pressed: s.pressed == .chDown || s.pressed == .chUp,
                 cap: (0.22, 0.08), pointer: f.shade(1.4))
        drawKnob(volC, 26, frac: Double(s.volume) / 100, pressed: s.pressed == .volDown || s.pressed == .volUp,
                 cap: (0.22, 0.08), pointer: f.shade(1.4))
        drawCentered("CHANNEL", x: chC.x, y: chC.y + 32, ink)
        drawCentered("VOLUME", x: volC.x, y: volC.y + 32, ink)

        for b in [TVButton.open, .rewind, .play, .fastForward] {
            let r = hitRect(b)!
            let lat = latched(b, s)
            let down = s.pressed == b || lat
            let c = NSBezierPath(ovalIn: r)
            NSGradient(colors: down ? [f.shade(0.6), f.shade(0.85)] : [f.shade(1.6), f.shade(0.8)])!.draw(in: c, angle: 90)
            gray(0, 0.6).setStroke(); c.lineWidth = 1; c.stroke()
            drawGlyph(b, in: r, color: lat ? latchGreen : (f.isLight ? gray(40) : gray(235)), size: 9, down: down)
        }

        // Power: small pill button with LED
        let pr = hitRect(.power)!
        let pDown = s.pressed == .power
        let pb = NSBezierPath(roundedRect: pr, xRadius: 13, yRadius: 13)
        NSGradient(colors: pDown ? [gray(30), gray(60)] : [gray(80), gray(25)])!.draw(in: pb, angle: 90)
        drawCentered("POWER", x: 396, y: pr.midY - 6, ink)
        drawLED(NSRect(x: 486, y: pr.midY - 5, width: 10, height: 10), on: s.poweredOn)
    }
}
