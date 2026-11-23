import Foundation

/// Receives decoded BGRA frames from libvlc on VLC's decoder thread and hands the
/// newest one to the renderer. Triple-buffered: VLC writes `write`, publishes it as
/// `ready`, and the renderer swaps `ready` into `read` when it draws.
final class VideoSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [UnsafeMutableRawPointer] = []
    private var writeIdx = 0, readyIdx = 1, readIdx = 2
    private var hasNew = false
    private(set) var width = 0
    private(set) var height = 0

    func configure(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        buffers.forEach { free($0) }
        buffers = (0..<3).map { _ in calloc(width * height * 4, 1)! }
        self.width = width
        self.height = height
        hasNew = false
    }

    func writeBuffer() -> UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        return buffers.isEmpty ? nil : buffers[writeIdx]
    }

    func publish() {
        lock.lock(); defer { lock.unlock() }
        guard !buffers.isEmpty else { return }
        (writeIdx, readyIdx) = (readyIdx, writeIdx)
        hasNew = true
    }

    func discardPending() {
        lock.lock(); defer { lock.unlock() }
        hasNew = false
    }

    /// Calls `body` with the newest frame if one arrived since the last call.
    func withLatestFrame(_ body: (UnsafeRawPointer, Int, Int) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard hasNew, !buffers.isEmpty else { return }
        (readyIdx, readIdx) = (readIdx, readyIdx)
        hasNew = false
        body(buffers[readIdx], width, height)
    }
}

// MARK: - libvlc C callbacks (no captures, so they convert to C function pointers)

/// Largest frame width we ask VLC for. The CRT look throws away detail anyway,
/// and smaller frames keep the CPU→GPU copy cheap.
private let maxFrameWidth = 1280

private let vlcFormat: libvlc_video_format_cb = { opaque, chroma, width, height, pitches, lines in
    guard let opaque, let ctx = opaque.pointee, let chroma, let width, let height, let pitches, let lines
    else { return 0 }
    let sink = Unmanaged<VideoSink>.fromOpaque(ctx).takeUnretainedValue()
    var w = Int(width.pointee), h = Int(height.pointee)
    if w > maxFrameWidth { h = h * maxFrameWidth / w; w = maxFrameWidth }
    w = max(2, w & ~1); h = max(2, h & ~1)
    _ = "BGRA".withCString { memcpy(chroma, $0, 4) }
    width.pointee = UInt32(w)
    height.pointee = UInt32(h)
    pitches.pointee = UInt32(w * 4)
    lines.pointee = UInt32(h)
    sink.configure(width: w, height: h)
    return 1
}

private let vlcCleanup: libvlc_video_cleanup_cb = { _ in }

private let vlcLock: libvlc_video_lock_cb = { opaque, planes in
    guard let opaque, let planes else { return nil }
    planes.pointee = Unmanaged<VideoSink>.fromOpaque(opaque).takeUnretainedValue().writeBuffer()
    return nil
}

private let vlcUnlock: libvlc_video_unlock_cb = { _, _, _ in }

private let vlcDisplay: libvlc_video_display_cb = { opaque, _ in
    guard let opaque else { return }
    Unmanaged<VideoSink>.fromOpaque(opaque).takeUnretainedValue().publish()
}

// MARK: - Player

/// Thin wrapper over libvlc (from the installed VLC.app). VLC handles demuxing
/// (MKV, MP4, ...), decoding and audio; video frames come back through VideoSink.
final class VLCPlayer {
    /// The VLC engine is bundled next to our executable (Contents/MacOS/lib and /plugins),
    /// mirroring VLC.app's own layout so its plugins find libvlccore via @executable_path/lib.
    static let vlcRoot = Bundle.main.executableURL!.deletingLastPathComponent().path

    let sink = VideoSink()
    private let instance: OpaquePointer
    private let mp: OpaquePointer
    private var media: OpaquePointer?

    init?() {
        setenv("VLC_PLUGIN_PATH", Self.vlcRoot + "/plugins", 1)
        var args = ["--no-video-title-show", "--no-stats", "--no-snapshot-preview", "--no-osd"]
        if ProcessInfo.processInfo.environment["CRTTV_VLC_VERBOSE"] != nil { args.append("-vv") }   // debugging
        let cargs = args.map { strdup($0) }
        defer { cargs.forEach { free($0) } }
        let ptrs: [UnsafePointer<CChar>?] = cargs.map { UnsafePointer($0) }
        guard let inst = libvlc_new(Int32(ptrs.count), ptrs) else { return nil }
        guard let player = libvlc_media_player_new(inst) else { libvlc_release(inst); return nil }
        instance = inst
        mp = player
        let opaque = Unmanaged.passUnretained(sink).toOpaque()
        libvlc_video_set_format_callbacks(mp, vlcFormat, vlcCleanup)
        libvlc_video_set_callbacks(mp, vlcLock, vlcUnlock, vlcDisplay, opaque)
    }

    func load(_ url: URL) {
        libvlc_media_player_stop(mp)
        guard let m = libvlc_media_new_path(instance, url.path) else { return }
        start(m)
    }

    /// Plays a network stream; `audio` is a separate audio track played in sync (YouTube splits them).
    func load(stream s: WebStream) {
        libvlc_media_player_stop(mp)
        guard let m = libvlc_media_new_location(instance, s.video) else { return }
        if let a = s.audio { _ = libvlc_media_slaves_add(m, libvlc_media_slave_type_audio, 4, a) }
        if let ua = s.userAgent { libvlc_media_add_option(m, ":http-user-agent=\(ua)") }
        libvlc_media_add_option(m, ":network-caching=1500")
        start(m)
    }

    private func start(_ m: OpaquePointer) {
        libvlc_media_player_set_media(mp, m)
        if let media { libvlc_media_release(media) }
        media = m
        sink.discardPending()
        libvlc_media_player_play(mp)
    }

    /// Can this media be seeked? False for live streams.
    var isSeekable: Bool { libvlc_media_player_is_seekable(mp) != 0 }

    func play() { libvlc_media_player_play(mp) }
    func setPaused(_ paused: Bool) { libvlc_media_player_set_pause(mp, paused ? 1 : 0) }
    func stop() { libvlc_media_player_stop(mp) }

    var isPlaying: Bool { libvlc_media_player_is_playing(mp) != 0 }
    var state: libvlc_state_t { libvlc_media_player_get_state(mp) }
    var isPaused: Bool { state == libvlc_Paused }
    var timeMs: Int64 { max(0, libvlc_media_player_get_time(mp)) }
    var lengthMs: Int64 { max(0, libvlc_media_player_get_length(mp)) }
    func seek(toMs t: Int64) { libvlc_media_player_set_time(mp, t) }
    func setRate(_ r: Float) { _ = libvlc_media_player_set_rate(mp, r) }

    /// libvlc reports -1 until the audio output exists, so the controller re-applies this periodically.
    func syncAudio(volume: Int, muted: Bool) {
        let current = libvlc_audio_get_volume(mp)
        guard current >= 0 else { return }
        if current != Int32(volume) { libvlc_audio_set_volume(mp, Int32(volume)) }
        let m: Int32 = muted ? 1 : 0
        if libvlc_audio_get_mute(mp) != m { libvlc_audio_set_mute(mp, m) }
    }

    /// Display aspect ratio of the current video track, honouring non-square pixels.
    func videoDisplayAspect() -> Double? {
        guard let media else { return nil }
        var tracks: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_media_track_t>?>? = nil
        let n = libvlc_media_tracks_get(media, &tracks)
        defer { if n > 0 { libvlc_media_tracks_release(tracks, n) } }
        guard n > 0, let tracks else { return nil }
        for i in 0..<Int(n) {
            guard let t = tracks[i]?.pointee, t.i_type == libvlc_track_video, let vp = t.video else { continue }
            let v = vp.pointee
            guard v.i_width > 0, v.i_height > 0 else { continue }
            var a = Double(v.i_width) / Double(v.i_height)
            if v.i_sar_num > 0, v.i_sar_den > 0 { a *= Double(v.i_sar_num) / Double(v.i_sar_den) }
            return a
        }
        return nil
    }
}
