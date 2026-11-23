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
    var design: NSSize { skin.design }
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
        scale = min(bounds.width / design.width, bounds.height / design.height)
        offset = CGPoint(x: (bounds.width - design.width * scale) / 2,
                         y: (bounds.height - design.height * scale) / 2)
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
        skin.draw(finish, st)
        ctx.restoreGState()
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
