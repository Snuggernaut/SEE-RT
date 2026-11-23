import AppKit
import UniformTypeIdentifiers

/// The TV's "brain": playlist (every video in the opened file's folder = a channel),
/// volume, power, and what the on-screen display shows.
@MainActor
final class TVController {
    nonisolated static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "wmv", "flv", "mpg", "mpeg",
        "ts", "m2ts", "mts", "3gp", "ogv", "vob", "divx", "xvid", "rm", "rmvb",
    ]

    let renderer: CRTRenderer
    let player: VLCPlayer?
    weak var bodyView: TVBodyView?

    private(set) var playlist: [URL] = []
    private(set) var index = -1
    private(set) var volume = UserDefaults.standard.object(forKey: "volume") as? Int ?? 70
    private(set) var muted = false
    private var resumeOnPowerOn = false
    private var noSignal = false
    private var channelUntil: CFTimeInterval = 0
    private var volumeUntil: CFTimeInterval = 0
    private var seekUntil: CFTimeInterval = 0
    private var statusUntil: CFTimeInterval = 0
    private var statusText = ""
    private var timer: Timer?
    /// Web links: the page's title (from yt-dlp) and whether we're still looking up the stream.
    private var webTitles: [URL: String] = [:]
    private(set) var tuning = false
    private var tuneToken = 0

    /// Picture controls, 0...100 with 50 = neutral. Remembered between launches.
    private(set) var brightness = UserDefaults.standard.object(forKey: "brightness") as? Int ?? 50
    private(set) var saturation = UserDefaults.standard.object(forKey: "saturation") as? Int ?? 50
    private(set) var contrast = UserDefaults.standard.object(forKey: "contrast") as? Int ?? 50
    private var adjustUntil: CFTimeInterval = 0

    /// Tube "look": scan mode, phosphor persistence and the worn-out extras. Remembered between launches.
    enum Persistence: Int { case off, subtle, heavy }
    enum PictureMode: Int { case clean, authentic, wornOut }
    private(set) var interlaced = UserDefaults.standard.bool(forKey: "interlaced")
    private(set) var persistence = Persistence(rawValue: UserDefaults.standard.object(forKey: "persistence") as? Int ?? 1) ?? .subtle
    private(set) var wornLook = UserDefaults.standard.bool(forKey: "wornLook")
    private var adjustLabel = ""

    /// VCR-style scanning. FF plays at 8x; REW steps backwards (VLC can't decode in reverse).
    enum ScanMode { case none, forward, rewind }
    private(set) var scan: ScanMode = .none
    private var scanTimer: Timer?
    private var rewindTarget: Int64 = 0
    static let ffRate: Float = 8
    static let rewindStepMs: Int64 = 1600   // per 0.2s tick ≈ 8x

    init(renderer: CRTRenderer) {
        self.renderer = renderer
        self.player = VLCPlayer()
        renderer.sink = player?.sink
        applyPicture()
        applyLook()
        loadDisplaySettings()
        if player == nil { NSLog("libvlc failed to start; is VLC.app in /Applications?") }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refreshOSD()
    }

    private var now: CFTimeInterval { CACurrentMediaTime() }
    private var hasMedia: Bool { index >= 0 && index < playlist.count }
    private var currentTitle: String? {
        guard hasMedia else { return nil }
        let u = playlist[index]
        return u.isFileURL ? u.deletingPathExtension().lastPathComponent : webTitles[u] ?? u.host ?? "STREAM"
    }
    var isPoweredOn: Bool { renderer.isPoweredOn }

    // MARK: Opening

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
            + ["mkv", "webm", "avi", "flv", "wmv", "ts", "vob"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video to tune in"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        let target = url.standardizedFileURL
        let dir = target.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var list = files
            .filter { Self.videoExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.standardizedFileURL }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if !list.contains(where: { $0.path == target.path }) { list = [target] }
        playlist = list
        index = list.firstIndex { $0.path == target.path } ?? 0
        NSDocumentController.shared.noteNewRecentDocumentURL(target)
        playCurrent()
    }

    /// Plays a web link (YouTube etc.) as its own channel.
    func openWeb(_ url: URL) {
        playlist = [url]
        index = 0
        playCurrent()
    }

    /// Asks for a link, pre-filled from the clipboard when it holds one.
    func openURLPanel() {
        let a = NSAlert()
        a.messageText = "Open URL"
        a.informativeText = "Paste a link to a YouTube video, another video site, or a video file on the web."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://www.youtube.com/watch?v=…"
        if let clip = NSPasteboard.general.string(forType: .string), let u = WebStream.url(from: clip) {
            field.stringValue = u.absoluteString
        }
        a.accessoryView = field
        a.addButton(withTitle: "Play")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let u = WebStream.url(from: field.stringValue) { openWeb(u) } else { NSSound.beep() }
    }

    /// ⌘V on the TV: play a link from the clipboard, or a copied video file.
    func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let f = files.first {
            open(f)
        } else if let text = pb.string(forType: .string), let u = WebStream.url(from: text) {
            openWeb(u)
        } else {
            NSSound.beep()
        }
    }

    private func playCurrent() {
        guard hasMedia else { return }
        stopScan()
        renderer.powerOn()
        guard let player else { showNoSignal(); return }
        noSignal = false
        statusUntil = 0
        tuneToken += 1
        tuning = false
        renderer.resetVideo()
        let item = playlist[index]
        if item.isFileURL {
            renderer.source = .video
            renderer.burstStatic()
            player.load(item)
        } else {
            tune(item, player)
        }
        channelUntil = now + 3.5
        bodyView?.needsDisplay = true
        refreshOSD()
    }

    /// Snow while yt-dlp looks up the stream, then the picture fades in.
    private func tune(_ page: URL, _ player: VLCPlayer) {
        player.stop()
        tuning = true
        renderer.source = .snow
        let token = tuneToken
        Task { @MainActor [weak self] in
            let result = await WebStream.resolve(page)
            guard let self, token == self.tuneToken else { return }   // user changed channel meanwhile
            self.tuning = false
            switch result {
            case .success(let s):
                self.webTitles[page] = s.title
                self.renderer.source = .video
                self.renderer.burstStatic()
                player.load(stream: s)
                self.channelUntil = self.now + 4
            case .failure(let f):
                self.showNoSignal()
                self.reportWebFailure(f)
            }
            self.refreshOSD()
        }
    }

    private func reportWebFailure(_ f: WebStream.Failure) {
        let a = NSAlert()
        switch f {
        case .notInstalled:
            a.messageText = "SEE-RT needs yt-dlp to play web videos"
            a.informativeText = "yt-dlp is a free tool that finds the video stream behind a YouTube (or other site) link. "
                + WebStream.installHint
        case .failed(let msg):
            a.messageText = "Couldn't tune in to that link"
            a.informativeText = msg + "\n\nIf YouTube links that used to work have stopped, update yt-dlp by running:  brew upgrade yt-dlp"
        }
        if let w = bodyView?.window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    private func goIdle() {
        tuneToken += 1
        tuning = false
        stopScan()
        player?.stop()
        renderer.resetVideo()
        renderer.source = .bars
        renderer.burstStatic(0.25)
        refreshOSD()
    }

    private func showNoSignal() {
        noSignal = true
        renderer.source = .snow
        refreshOSD()
    }

    // MARK: Controls

    func press(_ button: TVButton) {
        switch button {
        case .open: openPanel()
        case .play: togglePlay()
        case .volDown: changeVolume(-5)
        case .volUp: changeVolume(5)
        case .chDown: channel(-1)
        case .chUp: channel(1)
        case .rewind: toggleScan(.rewind)
        case .fastForward: toggleScan(.forward)
        case .power: togglePower()
        case .brightDown: setBrightness(brightness - 5)
        case .brightUp: setBrightness(brightness + 5)
        case .satDown: setSaturation(saturation - 5)
        case .satUp: setSaturation(saturation + 5)
        }
    }

    func togglePlay() {
        guard isPoweredOn else { togglePower(); return }
        guard hasMedia, let player else { openPanel(); return }
        if tuning { return }
        if renderer.source != .video { playCurrent(); return }
        if scan != .none {
            stopScan()
            statusText = "PLAY"; statusUntil = now + 2
        } else if player.isPlaying {
            player.setPaused(true)
        } else if player.isPaused {
            player.setPaused(false)
            statusText = "PLAY"; statusUntil = now + 2
        } else {
            playCurrent()
        }
        refreshOSD()
    }

    func channel(_ delta: Int) {
        guard isPoweredOn else { return }
        guard !playlist.isEmpty else { renderer.burstStatic(); return }
        index = ((index + delta) % playlist.count + playlist.count) % playlist.count
        playCurrent()
    }

    func changeVolume(_ delta: Int) {
        guard isPoweredOn else { return }
        volume = min(100, max(0, volume + delta))
        UserDefaults.standard.set(volume, forKey: "volume")
        muted = false
        player?.syncAudio(volume: volume, muted: muted)
        volumeUntil = now + 2
        adjustUntil = 0
        bodyView?.needsDisplay = true   // volume knob
        refreshOSD()
    }

    func toggleMute() {
        guard isPoweredOn else { return }
        muted.toggle()
        bodyView?.needsDisplay = true
        player?.syncAudio(volume: volume, muted: muted)
        refreshOSD()
    }

    func seek(by seconds: Double) {
        guard isPoweredOn, hasMedia, renderer.source == .video, let player else { return }
        let len = player.lengthMs
        guard len > 0 else { return }
        let t = min(max(0, player.timeMs + Int64(seconds * 1000)), max(0, len - 500))
        player.seek(toMs: t)
        if scan == .rewind { rewindTarget = t }
        renderer.tapeGlitch()
        seekUntil = now + 2.5
        refreshOSD()
    }

    func togglePower() {
        if isPoweredOn {
            stopScan()
            resumeOnPowerOn = player?.isPlaying ?? false
            if resumeOnPowerOn { player?.setPaused(true) }
            renderer.powerOff()
        } else {
            renderer.powerOn()
            if resumeOnPowerOn { player?.setPaused(false) }
            resumeOnPowerOn = false
            channelUntil = hasMedia ? now + 3 : 0
        }
        bodyView?.needsDisplay = true
        refreshOSD()
    }

    // MARK: Scanning

    func toggleScan(_ mode: ScanMode) {
        guard isPoweredOn, hasMedia, renderer.source == .video, let player, player.isSeekable, mode != .none else { return }
        if scan == mode {
            stopScan()
            statusText = "PLAY"; statusUntil = now + 2
            refreshOSD()
            return
        }
        stopScan()
        if player.isPaused { player.setPaused(false) }
        scan = mode
        switch mode {
        case .forward:
            player.setRate(Self.ffRate)
            renderer.tapeMode = .forward
        case .rewind:
            rewindTarget = player.timeMs
            renderer.tapeMode = .rewind
            scanTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.rewindStep() }
            }
        case .none: break
        }
        player.syncAudio(volume: volume, muted: true)
        bodyView?.needsDisplay = true
        refreshOSD()
    }

    private func rewindStep() {
        guard scan == .rewind, let player else { return }
        rewindTarget -= Self.rewindStepMs
        if rewindTarget <= 0 {
            player.seek(toMs: 0)
            stopScan()
            statusText = "PLAY"; statusUntil = now + 2
        } else {
            player.seek(toMs: rewindTarget)
        }
        refreshOSD()
    }

    func stopScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        guard scan != .none else { return }
        if scan == .forward { player?.setRate(1) }
        scan = .none
        renderer.tapeMode = .normal
        player?.syncAudio(volume: volume, muted: muted)
        bodyView?.needsDisplay = true
    }

    // MARK: Picture settings

    func setBrightness(_ value: Int) {
        brightness = min(100, max(0, value))
        UserDefaults.standard.set(brightness, forKey: "brightness")
        showAdjustment("BRIGHTNESS")
    }

    func setSaturation(_ value: Int) {
        saturation = min(100, max(0, value))
        UserDefaults.standard.set(saturation, forKey: "saturation")
        showAdjustment("SATURATION")
    }

    func setContrast(_ value: Int) {
        contrast = min(100, max(0, value))
        UserDefaults.standard.set(contrast, forKey: "contrast")
        showAdjustment("CONTRAST")
    }

    func resetPicture() {
        setContrast(50)
        setSaturation(50)
        setBrightness(50)
    }

    private func showAdjustment(_ label: String) {
        applyPicture()
        bodyView?.needsDisplay = true   // picture knobs
        guard isPoweredOn else { return }
        adjustLabel = label
        adjustUntil = now + 2
        volumeUntil = 0
        refreshOSD()
    }

    // MARK: Tube look

    /// The preset matching the current settings, or nil if they've been mixed by hand.
    var pictureMode: PictureMode? {
        switch (interlaced, persistence, wornLook) {
        case (false, .subtle, false): return .clean
        case (true, .subtle, false): return .authentic
        case (false, .heavy, true): return .wornOut
        default: return nil
        }
    }

    func setPictureMode(_ mode: PictureMode) {
        switch mode {
        case .clean: (interlaced, persistence, wornLook) = (false, .subtle, false)
        case .authentic: (interlaced, persistence, wornLook) = (true, .subtle, false)
        case .wornOut: (interlaced, persistence, wornLook) = (false, .heavy, true)
        }
        scanlines = 0   // presets use Auto line density
        saveLook()
    }

    func setInterlaced(_ on: Bool) {
        interlaced = on
        if on && persistence == .off { persistence = .subtle }   // bare interlace just flickers
        saveLook()
    }

    func setPersistence(_ p: Persistence) {
        persistence = p
        if p == .off { interlaced = false }
        saveLook()
    }

    private func saveLook() {
        let d = UserDefaults.standard
        d.set(interlaced, forKey: "interlaced")
        d.set(persistence.rawValue, forKey: "persistence")
        d.set(wornLook, forKey: "wornLook")
        applyLook()
    }

    private func applyLook() {
        renderer.interlaced = interlaced
        renderer.persistence = [0, 0.5, 0.8][persistence.rawValue]
        renderer.glow = wornLook ? 0.3 : 0.14
        renderer.grain = wornLook ? 0.065 : 0.03
    }

    private func applyPicture() {
        renderer.picBrightness = 0.4 + Float(brightness) / 100 * 1.2   // 0.4x ... 1.6x
        renderer.picSaturation = Float(saturation) / 50                // 0 (B&W) ... 2x
        renderer.picContrast = 0.4 + Float(contrast) / 100 * 1.2       // 0.4x (flat) ... 1.6x (punchy)
    }

    // Saved as soon as they change, restored at launch.
    var scanlines: Float {
        get { renderer.lines }
        set { renderer.lines = newValue; UserDefaults.standard.set(newValue, forKey: "scanlines") }
    }
    var curvature: Bool {
        get { renderer.curvatureEnabled }
        set { renderer.curvatureEnabled = newValue; UserDefaults.standard.set(newValue, forKey: "curvature") }
    }
    var fillScreen: Bool {
        get { renderer.fill }
        set { renderer.fill = newValue; UserDefaults.standard.set(newValue, forKey: "fillScreen") }
    }

    private func loadDisplaySettings() {
        let d = UserDefaults.standard
        renderer.lines = d.object(forKey: "scanlines") as? Float ?? 0
        renderer.curvatureEnabled = d.object(forKey: "curvature") as? Bool ?? true
        renderer.fill = d.bool(forKey: "fillScreen")
    }

    // MARK: Periodic update

    private func tick() {
        bodyView?.updateGlow(renderer.averageLight())
        if let player, renderer.source == .video, isPoweredOn {
            let st = player.state
            let isWeb = hasMedia && !playlist[index].isFileURL
            if isWeb, st == libvlc_Error || (st == libvlc_Ended && renderer.videoAspect == 0) {
                // The site refused the stream before any picture arrived.
                showNoSignal()
                player.stop()
                reportWebFailure(.failed("The site refused to send the video (it may be blocking outside players right now)."))
            } else if st == libvlc_Ended {
                if index < playlist.count - 1 { index += 1; playCurrent() } else { goIdle() }
            } else if st == libvlc_Error {
                showNoSignal()
            } else {
                if renderer.videoAspect == 0, let a = player.videoDisplayAspect() { renderer.videoAspect = a }
                player.syncAudio(volume: volume, muted: muted || scan != .none)
            }
        }
        if scan == .none {
            renderer.tapeMode = (renderer.source == .video && (player?.isPaused ?? false)) ? .paused : .normal
        }
        refreshOSD()
    }

    private func fmt(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func refreshOSD() {
        var s = OSDState()
        let t = now
        guard isPoweredOn else { renderer.setOSD(s); return }
        let paused = renderer.source == .video && (player?.isPaused ?? false)

        if renderer.source == .bars { s.topLeft = "VIDEO" }
        else if scan == .forward { s.topLeft = "FF ▶▶" }
        else if scan == .rewind { s.topLeft = "◀◀ REW" }
        else if paused { s.topLeft = "PAUSE" }
        else if t < statusUntil { s.topLeft = statusText }
        if muted { if s.topLeft == nil { s.topLeft = "MUTE" } else { s.topLeft2 = "MUTE" } }
        if noSignal { s.center = "NO SIGNAL" }
        if tuning { s.center = "TUNING…"; s.channel = "WEB"; s.title = playlist[index].host }
        else if hasMedia, t < channelUntil {
            s.channel = playlist[index].isFileURL ? String(format: "CH %02d", index + 1) : "WEB"
            s.title = currentTitle
        }
        if t < volumeUntil {
            s.volume = muted ? 0 : volume
        } else if t < adjustUntil {
            s.bar = adjustLabel == "SATURATION" ? saturation : adjustLabel == "CONTRAST" ? contrast : brightness
            s.barLabel = adjustLabel
        } else if hasMedia, renderer.source == .video, t < seekUntil || paused || scan != .none, let player, player.lengthMs > 0 {
            s.progress = Double(player.timeMs) / Double(player.lengthMs)
            s.progressText = "\(fmt(player.timeMs)) / \(fmt(player.lengthMs))"
        }
        renderer.setOSD(s)
    }
}
