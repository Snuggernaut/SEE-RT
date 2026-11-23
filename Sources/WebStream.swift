import Foundation

/// Turns a web page link (YouTube, Vimeo, …) into playable stream addresses using
/// yt-dlp, which the user installs separately so it can be updated as sites change.
/// Direct links to video files skip yt-dlp and play as they are.
struct WebStream: Sendable {
    var video: String
    var audio: String?          // separate audio track, when the site splits them
    var title: String
    var userAgent: String?
    var isLive = false

    enum Failure: Error {
        case notInstalled
        case failed(String)     // yt-dlp's own error message
    }

    static let installHint = "Install it with Homebrew by running:  brew install yt-dlp\n\nIf YouTube links stop working later, update it with:  brew upgrade yt-dlp"

    /// Apps opened from the Finder don't get the shell's PATH, so look in the usual places.
    static func ytdlpPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", home + "/.local/bin", home + "/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { $0 + "/yt-dlp" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Links that point straight at a media file or stream don't need resolving.
    static func isDirectMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return TVController.videoExtensions.contains(ext) || ["m3u8", "mpd", "mp3", "m4a", "aac", "flac", "ogg", "wav"].contains(ext)
            || ["rtsp", "rtmp", "mms", "udp"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Pulls a usable link out of pasted text: trims spaces and adds https:// to "youtube.com/…".
    static func url(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.split(whereSeparator: \.isWhitespace).first { s = String(first) }
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            guard s.contains("."), !s.hasPrefix("/"), !s.hasPrefix("~") else { return nil }
            s = "https://" + s
        }
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              ["http", "https", "rtsp", "rtmp", "mms", "udp"].contains(scheme), u.host != nil else { return nil }
        return u
    }

    /// Runs off the main thread; takes a few seconds for YouTube.
    static func resolve(_ page: URL) async -> Result<WebStream, Failure> {
        if isDirectMedia(page) {
            let name = page.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? page.lastPathComponent
            return .success(WebStream(video: page.absoluteString, title: name.isEmpty ? (page.host ?? "STREAM") : name))
        }
        guard let tool = ytdlpPath() else { return .failure(.notInstalled) }
        // Up to 720p (the CRT look can't show more), preferring H.264, which decodes cheaply.
        // HLS (m3u8) first: YouTube refuses its plain https stream addresses to other players (HTTP 403)
        // but serves HLS. Separate HLS video and audio are paired in a small master playlist (see parse).
        let format = "bv*[height<=720][vcodec^=avc1][protocol^=m3u8]+ba[protocol^=m3u8]"
            + "/bv*[height<=720][protocol^=m3u8]+ba[protocol^=m3u8]"
            + "/b[height<=720][protocol^=m3u8]"
            + "/bv*[height<=720][vcodec^=avc1]+ba[ext=m4a]/bv*[height<=720]+ba/b[height<=720]/b"
        let args = ["-J", "--no-playlist", "--no-warnings", "--no-progress", "-f", format, "--", page.absoluteString]

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                // Homebrew's yt-dlp is a Python script; make sure its interpreter and helpers are findable.
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: .failure(.failed("Couldn't run yt-dlp: \(error.localizedDescription)")))
                    return
                }
                // Read both pipes before waiting so a big JSON reply can't fill the pipe and stall yt-dlp.
                var errData = Data()
                let errReader = DispatchQueue(label: "ytdlp.stderr")
                errReader.async { errData = err.fileHandleForReading.readDataToEndOfFile() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                errReader.sync {}
                cont.resume(returning: parse(data, status: p.terminationStatus, stderr: errData))
            }
        }
    }

    private static func parse(_ data: Data, status: Int32, stderr: Data) -> Result<WebStream, Failure> {
        guard status == 0, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n")
            let msg = lines.last { $0.hasPrefix("ERROR") } ?? lines.last ?? "yt-dlp couldn't read that link."
            return .failure(.failed(msg.replacingOccurrences(of: "ERROR: ", with: "")))
        }
        let title = json["title"] as? String ?? "STREAM"
        let live = json["is_live"] as? Bool ?? false
        func agent(_ f: [String: Any]) -> String? { (f["http_headers"] as? [String: String])?["User-Agent"] }

        if let parts = json["requested_formats"] as? [[String: Any]], !parts.isEmpty {
            let video = parts.first { ($0["vcodec"] as? String ?? "none") != "none" } ?? parts[0]
            // The audio part is the one without video. Don't require "acodec": YouTube's HLS
            // audio streams leave it empty, and skipping them meant silent playback.
            let audio = parts.first { ($0["vcodec"] as? String ?? "none") == "none" && ($0["url"] as? String) != (video["url"] as? String) }
            if let v = video["url"] as? String {
                // HLS video + HLS audio: their timestamps don't line up when the audio is added as a
                // separate track (the picture never starts), so pair them in one master playlist,
                // the standard HLS way, and play that as a single stream.
                if let audio, let a = audio["url"] as? String,
                   isHLS(video), isHLS(audio), let master = writeMasterPlaylist(video: video, videoURL: v, audioURL: a) {
                    return .success(WebStream(video: master, title: title, userAgent: agent(video), isLive: live))
                }
                return .success(WebStream(video: v, audio: audio?["url"] as? String, title: title,
                                          userAgent: agent(video), isLive: live))
            }
        }
        if let v = json["url"] as? String {
            return .success(WebStream(video: v, title: title, userAgent: agent(json), isLive: live))
        }
        return .failure(.failed("yt-dlp didn't find a playable video at that link."))
    }

    private static func isHLS(_ f: [String: Any]) -> Bool { (f["protocol"] as? String ?? "").hasPrefix("m3u8") }

    /// Writes a master playlist naming the video stream and its audio rendition; returns its file URL.
    private static func writeMasterPlaylist(video: [String: Any], videoURL: String, audioURL: String) -> String? {
        let w = video["width"] as? Int ?? 1280, h = video["height"] as? Int ?? 720
        let vcodec = video["vcodec"] as? String ?? "avc1.4D401F"
        let text = """
            #EXTM3U
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioURL)"
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="\(vcodec),mp4a.40.2",RESOLUTION=\(w)x\(h),AUDIO="aud"
            \(videoURL)

            """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SEE-RT-\(UUID().uuidString).m3u8")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url.absoluteString
    }
}
