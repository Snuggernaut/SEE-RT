import AppKit
import MetalKit

/// Text printed on the cabinet. Set from the Picture ▸ Brand Name… menu; remembered between launches.
enum Cabinet {
    static let defaultBrand = "SEE-RT"
    static var brand: String {
        get { UserDefaults.standard.string(forKey: "brandName") ?? defaultBrand }
        set { UserDefaults.standard.set(newValue, forKey: "brandName") }
    }
}

/// Front-panel controls. Where each one sits depends on the skin (see Skins.swift).
enum TVButton: CaseIterable {
    case open, rewind, play, fastForward, volDown, volUp, chDown, chUp, power
    // picture knobs (only on skins that have them)
    case brightDown, brightUp, satDown, satUp

    /// Small symbol printed on the key cap.
    var glyph: String? {
        switch self {
        case .open: return "⏏"
        case .rewind: return "◀◀"
        case .play: return "▶❚❚"
        case .fastForward: return "▶▶"
        default: return nil
        }
    }
}

/// Draws the TV cabinet (the current skin) and hosts the Metal "tube" in its screen opening.
@MainActor
final class TVBodyView: NSView {
    weak var controller: TVController? { didSet { needsDisplay = true } }
    let crtView = MTKView(frame: .zero)
    private var pressed: TVButton?

    /// Current cabinet design and colour; each skin remembers its own colour.
    private(set) var skin: TVSkin = Skins.named(UserDefaults.standard.string(forKey: "skin"))
    private(set) var finishIndex = 0
    /// The view's design size: the cabinet plus the transparent margin its shadow falls into.
    var design: NSSize { Self.paddedSize(skin) }
    static func paddedSize(_ s: TVSkin) -> NSSize {
        let p = CabinetLighting.pad
        return NSSize(width: s.design.width + p.left + p.right, height: s.design.height + p.top + p.bottom)
    }

    /// Lit, textured cabinet with a drawn shadow, a faint glow from the picture on the bezel,
    /// and realistic glass. Off = the original flat look with the system window shadow.
    var realistic = UserDefaults.standard.object(forKey: "realisticLighting") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(realistic, forKey: "realisticLighting")
            controller?.renderer.realisticGlass = realistic
            glow = nil
            needsDisplay = true
            onRealisticChange?()
        }
    }
    var onRealisticChange: (() -> Void)?
    /// Light the picture currently casts on the bezel (smoothed), nil when dark.
    private var glow: SIMD3<Float>?
    var finish: Finish { skin.finishes[min(finishIndex, skin.finishes.count - 1)] }
    /// Lets the window adopt a new skin's proportions.
    var onSkinChange: ((_ old: TVSkin, _ new: TVSkin) -> Void)?

    func setSkin(_ s: TVSkin) {
        let old = skin
        skin = s
        finishIndex = UserDefaults.standard.integer(forKey: "finish.\(s.id)")
        UserDefaults.standard.set(s.id, forKey: "skin")
        needsLayout = true
        needsDisplay = true
        onSkinChange?(old, s)
        window?.invalidateCursorRects(for: self)
    }

    func setFinish(_ i: Int) {
        finishIndex = min(max(0, i), skin.finishes.count - 1)
        UserDefaults.standard.set(finishIndex, forKey: "finish.\(skin.id)")
        needsDisplay = true
    }

    /// Full screen: the view fills the display on black. With `showCabinet` off,
    /// only the 4:3 picture is shown, as large as the screen height allows.
    var fullScreen = false {
        didSet { needsLayout = true; needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }
    var showCabinet = UserDefaults.standard.object(forKey: "fullScreenCabinet") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showCabinet, forKey: "fullScreenCabinet")
            needsLayout = true; needsDisplay = true
        }
    }
    private var pictureOnly: Bool { fullScreen && !showCabinet }
    private var scale: CGFloat = 1
    private var offset = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        finishIndex = UserDefaults.standard.integer(forKey: "finish.\(skin.id)")
        wantsLayer = true
        crtView.wantsLayer = true
        crtView.layer?.masksToBounds = true
        addSubview(crtView)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        // The shadow margin only matters in a window; full screen uses the cabinet's own size.
        let p = fullScreen ? NSEdgeInsetsZero : CabinetLighting.pad
        let total = NSSize(width: skin.design.width + p.left + p.right, height: skin.design.height + p.top + p.bottom)
        scale = min(bounds.width / total.width, bounds.height / total.height)
        offset = CGPoint(x: (bounds.width - total.width * scale) / 2 + p.left * scale,
                         y: (bounds.height - total.height * scale) / 2 + p.top * scale)   // flipped: top margin
        if pictureOnly {
            let h = min(bounds.height, bounds.width * 3 / 4)
            let w = h * 4 / 3
            crtView.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
            crtView.layer?.cornerRadius = 0
        } else {
            crtView.frame = toView(skin.screenRect)
            crtView.layer?.cornerRadius = skin.screenCorner * scale
        }
        window?.invalidateShadow()
    }

    private func toView(_ r: NSRect) -> NSRect {
        NSRect(x: offset.x + r.minX * scale, y: offset.y + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    private func toDesign(_ p: NSPoint) -> NSPoint {
        NSPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Glow updates mark just thin strips; don't repaint more than was asked for.
        var rects: UnsafePointer<NSRect>?
        var count = 0
        getRectsBeingDrawn(&rects, count: &count)
        if let rects, count > 0 { ctx.clip(to: Array(UnsafeBufferPointer(start: rects, count: count))) }
        if fullScreen {
            NSColor.black.setFill()
            bounds.fill()
            if pictureOnly { return }
        }
        ctx.saveGState()
        ctx.translateBy(x: offset.x, y: offset.y)
        ctx.scaleBy(x: scale, y: scale)
        var st = SkinState()
        st.pressed = pressed
        if let c = controller {
            st.scan = c.scan
            st.poweredOn = c.isPoweredOn
            st.channel = max(c.index, 0)
            st.volume = c.muted ? 0 : c.volume
            st.brightness = c.brightness
            st.saturation = c.saturation
        }
        let layers = realistic ? CabinetLighting.layers(for: skin) : nil
        if let layers, !fullScreen {
            let p = CabinetLighting.pad
            drawImage(layers.shadow, in: NSRect(x: -p.left, y: -p.top, width: design.width, height: design.height), ctx)
        }
        skin.draw(finish, st)
        if let layers {
            let r = NSRect(origin: .zero, size: skin.design)
            ctx.saveGState(); ctx.setBlendMode(.softLight); drawImage(layers.texture, in: r, ctx); ctx.restoreGState()
            drawImage(layers.light, in: r, ctx)
            if let g = glow, g.max() > 0.01 {
                // The picture's light on the bezel: add its colour through the ring mask
                ctx.saveGState()
                flip(r, ctx)
                ctx.clip(to: CGRect(origin: .zero, size: r.size), mask: layers.glowRing)
                ctx.setBlendMode(.plusLighter)
                let s: CGFloat = 0.22   // faint: about a tenth of the picture's light at the very edge
                ctx.setFillColor(red: CGFloat(g.x) * s, green: CGFloat(g.y) * s, blue: CGFloat(g.z) * s, alpha: 1)
                ctx.fill(CGRect(origin: .zero, size: r.size))
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }

    /// Our context is flipped (y down); images and masks are y-up.
    private func flip(_ r: NSRect, _ ctx: CGContext) {
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
    }

    private func drawImage(_ img: CGImage, in r: NSRect, _ ctx: CGContext) {
        ctx.saveGState()
        flip(r, ctx)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    /// Called a few times a second with the picture's average light; eases toward it and
    /// redraws just the bezel around the glass when it changes visibly.
    func updateGlow(_ light: SIMD3<Float>?) {
        guard realistic, !pictureOnly else { if glow != nil { glow = nil; needsDisplay = true }; return }
        let target = light ?? .zero
        let current = glow ?? .zero
        let next = current + (target - current) * 0.6
        guard simd_reduce_max(simd_abs(next - current)) > 0.012 || (glow == nil) != (light == nil) else { return }
        glow = light == nil && next.max() < 0.01 ? nil : next
        // Only the bezel strips around the glass change (the glass itself is the Metal view).
        let s = skin.screenRect, m: CGFloat = 30
        for r in [NSRect(x: s.minX - m, y: s.minY - m, width: s.width + 2 * m, height: m),
                  NSRect(x: s.minX - m, y: s.maxY, width: s.width + 2 * m, height: m),
                  NSRect(x: s.minX - m, y: s.minY, width: m, height: s.height),
                  NSRect(x: s.maxX, y: s.minY, width: m, height: s.height)] {
            setNeedsDisplay(toView(r).insetBy(dx: -1, dy: -1))
        }
    }

    // MARK: Mouse

    private func button(at p: NSPoint) -> TVButton? {
        TVButton.allCases.first { skin.hitRect($0)?.insetBy(dx: -4, dy: -6).contains(p) ?? false }
    }

    /// Points within this distance of the TV's outline resize instead of moving the window.
    private let edgeZone: CGFloat = 14

    private func edges(at v: NSPoint) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
        let tv = toView(skin.outline)
        guard tv.insetBy(dx: -2, dy: -2).contains(v) else { return (false, false, false, false) }
        return (v.x < tv.minX + edgeZone, v.x > tv.maxX - edgeZone,
                v.y < tv.minY + edgeZone, v.y > tv.maxY - edgeZone)   // flipped: minY is the top
    }

    override func resetCursorRects() {
        guard !fullScreen else { return }
        let tv = toView(skin.outline)
        let z = edgeZone
        addCursorRect(NSRect(x: tv.minX, y: tv.minY, width: z, height: tv.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: tv.maxX - z, y: tv.minY, width: z, height: tv.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: tv.minX + z, y: tv.minY, width: tv.width - 2 * z, height: z), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: tv.minX + z, y: tv.maxY - z, width: tv.width - 2 * z, height: z), cursor: .resizeUpDown)
    }

    /// Live resize keeping the TV's proportions; the opposite edge/corner stays put.
    private func resizeLoop(_ e: (left: Bool, right: Bool, top: Bool, bottom: Bool)) {
        guard let window else { return }
        let aspect = design.width / design.height
        let start = window.frame
        let mouse0 = NSEvent.mouseLocation
        let maxFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? start
        while let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp { break }
            let m = NSEvent.mouseLocation
            let dx = m.x - mouse0.x, dy = m.y - mouse0.y
            var cands: [CGFloat] = []
            if e.right { cands.append(start.width + dx) }
            if e.left { cands.append(start.width - dx) }
            if e.bottom { cands.append((start.height - dy) * aspect) }   // screen coords: y grows upward
            if e.top { cands.append((start.height + dy) * aspect) }
            guard var w = cands.max(by: { abs($0 - start.width) < abs($1 - start.width) }) else { break }
            w = min(max(w, window.minSize.width), maxFrame.width, maxFrame.height * aspect)
            let h = w / aspect
            let x = e.left ? start.maxX - w : start.minX
            let y = e.top && !e.bottom ? start.minY : start.maxY - h
            window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }
        window.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        let p = toDesign(v)
        if !pictureOnly, let b = button(at: p) {
            pressed = b
            needsDisplay = true
            return
        }
        if fullScreen {
            if event.clickCount == 2, crtView.frame.contains(v) { controller?.togglePlay() }
            return   // nothing to move or resize while full screen
        }
        let e = edges(at: v)
        if e.left || e.right || e.top || e.bottom {
            resizeLoop(e)
            return
        }
        if event.clickCount == 2, skin.screenRect.contains(p) {
            controller?.togglePlay()
            return
        }
        window?.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let b = pressed else { return }
        pressed = nil
        needsDisplay = true
        let p = toDesign(convert(event.locationInWindow, from: nil))
        if button(at: p) == b { controller?.press(b) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: c.togglePlay()                          // space
        case 53 where fullScreen:                        // esc
            NSApp.sendAction(#selector(AppDelegate.toggleFullScreenMode(_:)), to: nil, from: self)
        case 123: c.seek(by: shift ? -60 : -10)          // ←
        case 124: c.seek(by: shift ? 60 : 10)            // →
        case 126: c.changeVolume(5)                      // ↑
        case 125: c.changeVolume(-5)                     // ↓
        case 116: c.channel(1)                           // page up
        case 121: c.channel(-1)                          // page down
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r", ",": c.toggleScan(.rewind)
            case "f", ".": c.toggleScan(.forward)
            case "m": c.toggleMute()
            case "p": c.togglePower()
            case "z": c.fillScreen.toggle()
            case "]", "n": c.channel(1)
            case "[", "b": c.channel(-1)
            default: super.keyDown(with: event)
            }
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    /// Video files from the Finder, or links dragged from a web browser.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = files.first {
            controller?.open(url)
            return true
        }
        let links = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        guard let link = links.first.flatMap({ WebStream.url(from: $0.absoluteString) })
                ?? pb.string(forType: .string).flatMap(WebStream.url(from:)) else { return false }
        controller?.openWeb(link)
        return true
    }

    // MARK: Paste (⌘V)

    @objc func paste(_ sender: Any?) { controller?.pasteFromClipboard() }
}
