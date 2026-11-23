import AppKit

/// Borderless windows refuse key status by default; the TV needs keyboard input.
final class TVWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: TVWindow!
    private var controller: TVController?
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let body = TVBodyView(frame: NSRect(x: 0, y: 0, width: 820, height: 700))
        let d = body.design
        let size = NSSize(width: 820, height: 820 * d.height / d.width)
        window = TVWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentAspectRatio = d
        window.minSize = NSSize(width: 420 * d.width / 1000, height: 420 * d.height / 1000)
        window.isReleasedWhenClosed = false
        window.title = "SEE-RT"

        body.frame = NSRect(origin: .zero, size: size)
        body.onSkinChange = { [weak self] old, new in self?.adoptSkin(from: old, to: new) }
        guard let renderer = CRTRenderer(view: body.crtView) else {
            let a = NSAlert()
            a.messageText = "Couldn't start the Metal renderer."
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        let controller = TVController(renderer: renderer)
        self.controller = controller
        body.controller = controller
        controller.bodyView = body
        window.contentView = body
        buildMenu()
        restoreWindowFrame()
        // Remember size and position (but not the temporary full-screen frame)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveWindowFrame() }
            }
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(body)
        NSApp.activate(ignoringOtherApps: true)

        if controller.player == nil {
            let a = NSAlert()
            a.messageText = "VLC engine not found"
            a.informativeText = "SEE-RT's built-in VLC playback engine couldn't start. Try rebuilding the app with build.sh."
            a.runModal()
        }

        // Files from Finder ("Open With") or a path passed on the command line
        let arg = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if let url = pendingURL ?? arg.map({ URL(fileURLWithPath: $0) }) { controller.open(url) }

        // Debug hooks: CRTTV_SNAPSHOT=/path/prefix plus an optional timed script, e.g.
        // CRTTV_SCRIPT="2:ff 3.5:snap 5:rew 6:snap 7:play 8:width=600 9:snap"
        if let prefix = ProcessInfo.processInfo.environment["CRTTV_SNAPSHOT"] {
            let script = ProcessInfo.processInfo.environment["CRTTV_SCRIPT"] ?? "2.5:snap 5:snap"
            var shot = 0
            for token in script.split(separator: " ") {
                let parts = token.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let delay = Double(parts[0]) else { continue }
                let cmd = String(parts[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let c = self.controller else { return }
                    switch cmd {
                    case "snap":
                        shot += 1
                        self.writeSnapshot(to: URL(fileURLWithPath: "\(prefix)\(shot).png"))
                    case "ff": c.toggleScan(.forward)
                    case "rew": c.toggleScan(.rewind)
                    case "play": c.togglePlay()
                    case "fs": self.toggleFullScreenMode(nil)
                    case "cab": self.toggleCabinet()
                    case _ where cmd.hasPrefix("skin="):
                        if let i = Int(cmd.dropFirst(5)), Skins.all.indices.contains(i) { self.body?.setSkin(Skins.all[i]); self.rebuildCabinetMenu() }
                    case _ where cmd.hasPrefix("finish="):
                        if let i = Int(cmd.dropFirst(7)) { self.body?.setFinish(i) }
                    default:
                        if cmd.hasPrefix("mode="), let v = Int(cmd.dropFirst(5)), let m = TVController.PictureMode(rawValue: v) { c.setPictureMode(m) }
                        if cmd.hasPrefix("persist="), let v = Int(cmd.dropFirst(8)), let p = TVController.Persistence(rawValue: v) { c.setPersistence(p) }
                        if cmd.hasPrefix("bright="), let v = Int(cmd.dropFirst(7)) { c.setBrightness(v) }
                        if cmd.hasPrefix("sat="), let v = Int(cmd.dropFirst(4)) { c.setSaturation(v) }
                        if cmd.hasPrefix("brand=") {
                            Cabinet.brand = String(cmd.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
                            self.window.contentView?.needsDisplay = true
                        }
                        if cmd.hasPrefix("url="), let u = WebStream.url(from: String(cmd.dropFirst(4))) { c.openWeb(u) }
                        if cmd.hasPrefix("seek="), let v = Double(cmd.dropFirst(5)) { c.seek(by: v) }
                        if cmd.hasPrefix("width="), let w = Double(cmd.dropFirst(6)) { self.setWidth(CGFloat(w)) }
                    }
                }
            }
        }
    }

    /// The whole TV: cabinet drawn by AppKit, tube image rendered offscreen by Metal.
    private func writeSnapshot(to url: URL) {
        let scale = window.backingScaleFactor
        guard let body = window.contentView as? TVBodyView, let controller,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(body.bounds.width * scale), pixelsHigh: Int(body.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = body.bounds.size
        body.cacheDisplay(in: body.bounds, to: rep)
        let px = rep.pixelsWide, py = rep.pixelsHigh
        let sx = CGFloat(px) / body.bounds.width
        let f = body.crtView.frame
        guard let tube = controller.renderer.snapshot(size: CGSize(width: f.width * sx, height: f.height * sx)),
              let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cabinet = rep.cgImage else { return }
        ctx.draw(cabinet, in: CGRect(x: 0, y: 0, width: px, height: py))
        // body view is flipped; CG origin is bottom-left
        let r = CGRect(x: f.minX * sx, y: CGFloat(py) - f.maxY * sx, width: f.width * sx, height: f.height * sx)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: (body.crtView.layer?.cornerRadius ?? 0) * sx, cornerHeight: (body.crtView.layer?.cornerRadius ?? 0) * sx, transform: nil))
        ctx.clip()
        ctx.draw(tube, in: r)
        ctx.restoreGState()
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    @objc private func saveSnapshot() {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let stamp = Int(Date().timeIntervalSince1970)
        writeSnapshot(to: desktop.appendingPathComponent("SEE-RT \(stamp).png"))
        NSSound(named: "Tink")?.play()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let controller { controller.open(url) } else { pendingURL = url }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SEE-RT", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide SEE-RT", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit SEE-RT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: main, title: "SEE-RT")

        let file = NSMenu(title: "File")
        file.addItem(item("Open…", #selector(openFile), "o"))
        let openURL = item("Open URL…", #selector(openURL), "O")   // ⇧⌘O
        file.addItem(openURL)
        file.addItem(item("Save Snapshot to Desktop", #selector(saveSnapshot), "s"))
        file.addItem(.separator())
        file.addItem(item("Close", #selector(closeWindow), "w"))
        addSubmenu(file, to: main, title: "File")

        // Standard Edit menu (nil targets): makes ⌘V work in text fields, and on the TV
        // it reaches TVBodyView.paste(_:), which plays a copied link or video file.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(edit, to: main, title: "Edit")

        let play = NSMenu(title: "Playback")
        play.addItem(item("Play / Pause   (Space)", #selector(playPause), ""))
        play.addItem(item("Rewind   (R)", #selector(rewind), ""))
        play.addItem(item("Fast Forward   (F)", #selector(fastForward), ""))
        play.addItem(.separator())
        play.addItem(item("Channel Up   ( ] )", #selector(channelUp), ""))
        play.addItem(item("Channel Down   ( [ )", #selector(channelDown), ""))
        play.addItem(.separator())
        play.addItem(item("Forward 10s   (→)", #selector(seekFwd), ""))
        play.addItem(item("Back 10s   (←)", #selector(seekBack), ""))
        play.addItem(.separator())
        play.addItem(item("Volume Up   (↑)", #selector(volUp), ""))
        play.addItem(item("Volume Down   (↓)", #selector(volDown), ""))
        play.addItem(item("Mute   (M)", #selector(mute), ""))
        play.addItem(.separator())
        play.addItem(item("Power   (P)", #selector(power), ""))
        addSubmenu(play, to: main, title: "Playback")

        let pic = NSMenu(title: "Picture")
        pic.addItem(item("Picture Adjustments…", #selector(showAdjustments), "p"))
        pic.items.last?.keyEquivalentModifierMask = [.command, .option]
        pic.addItem(item("Brightness Up", #selector(brightUp), "]"))
        pic.items.last?.keyEquivalentModifierMask = [.command, .option]
        pic.addItem(item("Brightness Down", #selector(brightDown), "["))
        pic.items.last?.keyEquivalentModifierMask = [.command, .option]
        pic.addItem(item("Saturation Up", #selector(satUp), "}"))
        pic.items.last?.keyEquivalentModifierMask = [.command, .option, .shift]
        pic.addItem(item("Saturation Down", #selector(satDown), "{"))
        pic.items.last?.keyEquivalentModifierMask = [.command, .option, .shift]
        pic.addItem(item("Reset Picture", #selector(resetPicture), ""))
        pic.addItem(.separator())
        pic.addItem(submenu("Picture Mode", [("Clean", 0), ("Authentic (480i)", 1), ("Worn Out", 2)], #selector(setMode(_:))))
        pic.addItem(submenu("Scan Mode", [("Progressive", 0), ("Interlaced (480i)", 1)], #selector(setScan(_:))))
        pic.addItem(submenu("Phosphor Persistence", [("Off", 0), ("Subtle", 1), ("Heavy", 2)], #selector(setPersist(_:))))
        pic.addItem(.separator())
        for (title, n) in [("Auto (match display)", 0), ("240 Lines (chunky)", 240), ("360 Lines", 360), ("480 Lines (fine)", 480)] {
            let i = item(title, #selector(setLines(_:)), "")
            i.tag = n
            pic.addItem(i)
        }
        pic.addItem(.separator())
        pic.addItem(item("Curved Glass", #selector(toggleCurvature), ""))
        pic.addItem(item("Zoom to Fill 4:3   (Z)", #selector(toggleFill), ""))
        addSubmenu(pic, to: main, title: "Picture")

        cabinetMenu = NSMenu(title: "Cabinet")
        rebuildCabinetMenu()
        addSubmenu(cabinetMenu, to: main, title: "Cabinet")

        let win = NSMenu(title: "Window")
        win.addItem(item("Enter Full Screen", #selector(toggleFullScreenMode(_:)), "f"))
        win.items.last?.keyEquivalentModifierMask = [.control, .command]
        win.addItem(item("Show Cabinet in Full Screen", #selector(toggleCabinet), ""))
        win.addItem(.separator())
        win.addItem(item("Minimize", #selector(minimize), "m"))
        win.addItem(.separator())
        win.addItem(item("Bigger", #selector(bigger), "="))
        win.addItem(item("Smaller", #selector(smaller), "-"))
        win.addItem(item("Fit to Screen", #selector(fitToScreen), "0"))
        win.addItem(.separator())
        for (title, w, key) in [("Small", 560, "1"), ("Medium", 820, "2"), ("Large", 1150, "3"), ("Extra Large", 1500, "4")] {
            let i = item(title, #selector(setSize(_:)), key)
            i.tag = w
            win.addItem(i)
        }
        addSubmenu(win, to: main, title: "Window")
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ choices: [(String, Int)], _ action: Selector) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        for (t, tag) in choices {
            let i = item(t, action, "")
            i.tag = tag
            m.addItem(i)
        }
        holder.submenu = m
        return holder
    }

    @objc private func setMode(_ s: NSMenuItem) {
        if let m = TVController.PictureMode(rawValue: s.tag) { controller?.setPictureMode(m) }
    }
    @objc private func setScan(_ s: NSMenuItem) { controller?.setInterlaced(s.tag == 1) }
    @objc private func setPersist(_ s: NSMenuItem) {
        if let p = TVController.Persistence(rawValue: s.tag) { controller?.setPersistence(p) }
    }

    private func addSubmenu(_ menu: NSMenu, to main: NSMenu, title: String) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let c = controller else { return item.action == #selector(closeWindow) }
        switch item.action {
        case #selector(setLines(_:)): item.state = Int(c.scanlines) == item.tag ? .on : .off
        case #selector(toggleCurvature): item.state = c.curvature ? .on : .off
        case #selector(toggleFill): item.state = c.fillScreen ? .on : .off
        case #selector(setMode(_:)): item.state = c.pictureMode?.rawValue == item.tag ? .on : .off
        case #selector(setScan(_:)): item.state = (c.interlaced ? 1 : 0) == item.tag ? .on : .off
        case #selector(setPersist(_:)): item.state = c.persistence.rawValue == item.tag ? .on : .off
        case #selector(power): item.state = c.isPoweredOn ? .on : .off
        case #selector(toggleFullScreenMode(_:)):
            item.title = isFullScreen ? "Exit Full Screen" : "Enter Full Screen"
        case #selector(chooseSkin(_:)): item.state = Skins.all.firstIndex { $0.id == body?.skin.id } == item.tag ? .on : .off
        case #selector(chooseFinish(_:)): item.state = body?.finishIndex == item.tag ? .on : .off
        case #selector(toggleCabinet): item.state = (body?.showCabinet ?? true) ? .on : .off
        case #selector(setSize(_:)), #selector(bigger), #selector(smaller), #selector(fitToScreen), #selector(minimize):
            return !isFullScreen
        default: break
        }
        return true
    }

    @objc private func openFile() { controller?.openPanel() }
    @objc private func openURL() { controller?.openURLPanel() }
    @objc private func closeWindow() { window.close() }
    @objc private func playPause() { controller?.togglePlay() }
    @objc private func channelUp() { controller?.channel(1) }
    @objc private func channelDown() { controller?.channel(-1) }
    @objc private func seekFwd() { controller?.seek(by: 10) }
    @objc private func seekBack() { controller?.seek(by: -10) }
    @objc private func volUp() { controller?.changeVolume(5) }
    @objc private func volDown() { controller?.changeVolume(-5) }
    @objc private func mute() { controller?.toggleMute() }
    @objc private func power() { controller?.togglePower() }
    @objc private func setLines(_ sender: NSMenuItem) { controller?.scanlines = Float(sender.tag) }
    @objc private func toggleCurvature() { controller?.curvature.toggle() }
    @objc private func toggleFill() { controller?.fillScreen.toggle() }
    @objc private func minimize() { window.miniaturize(nil) }

    // MARK: Window frame

    // MARK: Cabinet (skins and colours)

    private var cabinetMenu = NSMenu(title: "Cabinet")

    private func rebuildCabinetMenu() {
        cabinetMenu.removeAllItems()
        cabinetMenu.addItem(submenu("Skin", Skins.all.enumerated().map { ($1.name, $0) }, #selector(chooseSkin(_:))))
        let finishes = body?.skin.finishes ?? []
        cabinetMenu.addItem(submenu("Color", finishes.enumerated().map { ($1.name, $0) }, #selector(chooseFinish(_:))))
        cabinetMenu.addItem(.separator())
        cabinetMenu.addItem(item("Brand Name…", #selector(changeBrand), ""))
    }

    @objc private func chooseSkin(_ s: NSMenuItem) {
        guard let body, Skins.all.indices.contains(s.tag) else { return }
        body.setSkin(Skins.all[s.tag])
        rebuildCabinetMenu()
    }

    @objc private func chooseFinish(_ s: NSMenuItem) { body?.setFinish(s.tag) }

    /// New skins have different proportions: keep the picture the same size on screen.
    private func adoptSkin(from old: TVSkin, to new: TVSkin) {
        let d = new.design
        window.contentAspectRatio = d
        window.minSize = NSSize(width: 420 * d.width / 1000, height: 420 * d.height / 1000)
        guard !isFullScreen else { return }
        let oldPicture = window.frame.width * old.screenRect.width / old.design.width
        setWidth(oldPicture * new.design.width / new.screenRect.width)
    }

    private func saveWindowFrame() {
        guard !isFullScreen else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "windowFrame")
    }

    private func restoreWindowFrame() {
        let d = body?.design ?? NSSize(width: 1000, height: 845)
        if let s = UserDefaults.standard.string(forKey: "windowFrame") {
            var f = NSRectFromString(s)
            f.size.height = f.width * d.height / d.width   // keep proportions exact
            // only reuse it if it is still mostly on a connected screen
            if f.width >= window.minSize.width,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersection(f).width > f.width / 2 }) {
                window.setFrame(f, display: false)
                return
            }
        }
        window.center()
    }

    // MARK: Full screen

    private var savedFrame: NSRect?
    private var cursorTimer: Timer?
    private var lastMouse = NSPoint.zero
    private var mouseStill: TimeInterval = 0
    private var isFullScreen: Bool { savedFrame != nil }
    private var body: TVBodyView? { window.contentView as? TVBodyView }

    /// Our own full screen (the borderless TV window has no green button): the window
    /// covers the display on black and the TV scales up, keeping its proportions.
    @objc func toggleFullScreenMode(_ sender: Any?) {
        guard let body else { return }
        if let frame = savedFrame {
            savedFrame = nil
            cursorTimer?.invalidate(); cursorTimer = nil
            NSApp.presentationOptions = []
            body.fullScreen = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.setFrame(frame, display: true)
        } else {
            guard let screen = window.screen ?? NSScreen.main else { return }
            savedFrame = window.frame
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            body.fullScreen = true
            window.setFrame(screen.frame, display: true)
            // hide the pointer after 2 s without movement
            lastMouse = NSEvent.mouseLocation
            mouseStill = 0
            cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let m = NSEvent.mouseLocation
                    if m == self.lastMouse { self.mouseStill += 0.5 } else { self.mouseStill = 0; self.lastMouse = m }
                    if self.mouseStill == 2 { NSCursor.setHiddenUntilMouseMoves(true) }
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(body)
    }

    @objc private func toggleCabinet() { body?.showCabinet.toggle() }

    // MARK: Picture adjustments

    private var adjustPanel: NSPanel?
    private var brightSlider: NSSlider?
    private var satSlider: NSSlider?

    @objc private func brightUp() { controller?.setBrightness((controller?.brightness ?? 50) + 5); syncSliders() }
    @objc private func brightDown() { controller?.setBrightness((controller?.brightness ?? 50) - 5); syncSliders() }
    @objc private func satUp() { controller?.setSaturation((controller?.saturation ?? 50) + 5); syncSliders() }
    @objc private func satDown() { controller?.setSaturation((controller?.saturation ?? 50) - 5); syncSliders() }
    @objc private func resetPicture() { controller?.resetPicture(); syncSliders() }

    private func syncSliders() {
        guard let c = controller else { return }
        brightSlider?.integerValue = c.brightness
        satSlider?.integerValue = c.saturation
    }

    @objc private func sliderMoved(_ s: NSSlider) {
        if s === brightSlider { controller?.setBrightness(s.integerValue) } else { controller?.setSaturation(s.integerValue) }
    }

    @objc private func showAdjustments() {
        if adjustPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
                                styleMask: [.titled, .closable, .utilityWindow, .hudWindow],
                                backing: .buffered, defer: false)
            panel.title = "Picture"
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true   // keep keyboard focus on the TV
            panel.isReleasedWhenClosed = false
            func row(_ title: String) -> (NSStackView, NSSlider) {
                let label = NSTextField(labelWithString: title)
                label.widthAnchor.constraint(equalToConstant: 80).isActive = true
                let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: self, action: #selector(sliderMoved(_:)))
                slider.isContinuous = true
                slider.numberOfTickMarks = 3   // centre tick = neutral
                let r = NSStackView(views: [label, slider])
                r.spacing = 8
                return (r, slider)
            }
            let (r1, b) = row("Brightness")
            let (r2, s) = row("Saturation")
            brightSlider = b
            satSlider = s
            let reset = NSButton(title: "Reset", target: self, action: #selector(resetPicture))
            let stack = NSStackView(views: [r1, r2, reset])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            r1.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
            r2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
            panel.contentView = stack
            let f = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX + 12, y: f.maxY - 40))
            adjustPanel = panel
        }
        syncSliders()
        adjustPanel?.orderFront(nil)
    }

    // MARK: Brand

    @objc private func changeBrand() {
        let alert = NSAlert()
        alert.messageText = "Brand Name"
        alert.informativeText = "The name shown on the front of the TV. Leave it empty for no name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = Cabinet.brand
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Restore Default")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Cabinet.brand = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .alertThirdButtonReturn:
            Cabinet.brand = Cabinet.defaultBrand
        default:
            return
        }
        window.contentView?.needsDisplay = true
    }

    @objc private func rewind() { controller?.toggleScan(.rewind) }
    @objc private func fastForward() { controller?.toggleScan(.forward) }
    @objc private func setSize(_ sender: NSMenuItem) { setWidth(CGFloat(sender.tag)) }
    @objc private func bigger() { setWidth(window.frame.width * 1.15) }
    @objc private func smaller() { setWidth(window.frame.width / 1.15) }
    @objc private func fitToScreen() { setWidth(.greatestFiniteMagnitude, center: true) }

    /// Resizes around the window's centre, clamped to the screen, and keeps it on screen.
    private func setWidth(_ requested: CGFloat, center: Bool = false) {
        let d = body?.design ?? NSSize(width: 1000, height: 845)
        let vis = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let w = min(max(requested, window.minSize.width), vis.width, vis.height * d.width / d.height)
        var f = window.frame
        let mid = NSPoint(x: f.midX, y: f.midY)
        f.size = NSSize(width: w, height: w * d.height / d.width)
        f.origin = center ? NSPoint(x: vis.midX - f.width / 2, y: vis.midY - f.height / 2)
                          : NSPoint(x: mid.x - f.width / 2, y: mid.y - f.height / 2)
        f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
        window.setFrame(f, display: true, animate: true)
    }
}
