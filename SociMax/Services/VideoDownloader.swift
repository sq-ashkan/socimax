import Foundation

final class VideoDownloader {
    static let shared = VideoDownloader()

    private let videosDir: URL
    private let maxFileSize: Int64 = 50 * 1024 * 1024 // 50MB Telegram limit
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        videosDir = appSupport.appendingPathComponent("SociMax/videos")
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
    }

    /// Check if yt-dlp is installed
    var isAvailable: Bool {
        let result = shell("/usr/bin/which", ["yt-dlp"])
        return result.status == 0 && !result.output.isEmpty
    }

    /// Extract YouTube video ID from various URL formats
    static func youtubeVideoId(from url: String) -> String? {
        // youtube.com/watch?v=ID
        if let range = url.range(of: "v=") {
            let start = range.upperBound
            let id = String(url[start...]).components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted).first
            if let id, id.count == 11 { return id }
        }
        // youtube.com/shorts/ID
        if let range = url.range(of: "/shorts/") {
            let start = range.upperBound
            let id = String(url[start...]).components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted).first
            if let id, id.count == 11 { return id }
        }
        // youtu.be/ID
        if url.contains("youtu.be/") {
            if let range = url.range(of: "youtu.be/") {
                let start = range.upperBound
                let id = String(url[start...]).components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted).first
                if let id, id.count == 11 { return id }
            }
        }
        return nil
    }

    /// Check if URL is a YouTube video
    static func isYouTubeVideo(_ url: String) -> Bool {
        return url.contains("youtube.com/watch") ||
               url.contains("youtube.com/shorts/") ||
               url.contains("youtu.be/")
    }

    /// Download YouTube thumbnail image. Returns local file URL or nil.
    func downloadThumbnail(url: String) async -> URL? {
        guard let videoId = Self.youtubeVideoId(from: url) else { return nil }

        let thumbFile = videosDir.appendingPathComponent("\(videoId)_thumb.jpg")
        if FileManager.default.fileExists(atPath: thumbFile.path) { return thumbFile }

        // Try maxresdefault first, fallback to hqdefault
        let thumbURLs = [
            "https://img.youtube.com/vi/\(videoId)/maxresdefault.jpg",
            "https://img.youtube.com/vi/\(videoId)/hqdefault.jpg"
        ]

        for thumbURL in thumbURLs {
            guard let url = URL(string: thumbURL) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200, data.count > 5000 {
                    try data.write(to: thumbFile)
                    FileLogger.shared.log("VideoDownloader: thumbnail downloaded (\(data.count / 1024)KB)")
                    return thumbFile
                }
            } catch {
                continue
            }
        }
        return nil
    }

    /// Download a YouTube video. Returns (videoFile, thumbnailFile) or nil.
    func downloadVideo(url: String) async -> (video: URL, thumbnail: URL?)? {
        guard let videoId = Self.youtubeVideoId(from: url) else {
            FileLogger.shared.log("VideoDownloader: can't extract video ID from \(url)")
            return nil
        }

        let outputFile = videosDir.appendingPathComponent("\(videoId).mp4")
        var succeeded = false

        // Guarantee temp file cleanup on ALL exit paths (errors, early returns, etc.)
        defer {
            if !succeeded {
                cleanup(videoId: videoId)
            }
        }

        // Skip if already downloaded and valid
        if FileManager.default.fileExists(atPath: outputFile.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: outputFile.path)[.size] as? Int64) ?? 0
            if size > 0 && size <= maxFileSize {
                FileLogger.shared.log("VideoDownloader: using cached \(videoId).mp4 (\(size / 1024 / 1024)MB)")
                succeeded = true
                let thumb = await downloadThumbnail(url: url)
                return (video: outputFile, thumbnail: thumb)
            }
            try? FileManager.default.removeItem(at: outputFile)
        }

        let ytdlpPath = shell("/usr/bin/which", ["yt-dlp"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ytdlpPath.isEmpty else {
            FileLogger.shared.log("VideoDownloader: yt-dlp not found")
            return nil
        }

        // Strategy: try 1080p first, if too large try 720p, compress only as last resort
        let formats: [(label: String, format: String)] = [
            ("1080p", "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=1080]+bestaudio/best[height<=1080]"),
            ("720p", "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/bestvideo[height<=720]+bestaudio/best[height<=720]"),
        ]

        var downloadedFile: URL?

        for (label, format) in formats {
            let tempFile = videosDir.appendingPathComponent("\(videoId)_temp.%(ext)s")
            let actualTemp = videosDir.appendingPathComponent("\(videoId)_temp.mp4")

            // Clean previous attempt
            try? FileManager.default.removeItem(at: actualTemp)

            FileLogger.shared.log("VideoDownloader: trying \(label) for \(videoId)...")
            let dlResult = await shellAsync(ytdlpPath, [
                "-f", format,
                "--merge-output-format", "mp4",
                "-o", tempFile.path,
                "--no-playlist",
                "--no-warnings",
                url
            ])

            if dlResult.status != 0 {
                FileLogger.shared.log("VideoDownloader: \(label) download failed: \(dlResult.output)")
                cleanup(videoId: videoId)
                continue
            }

            guard FileManager.default.fileExists(atPath: actualTemp.path) else {
                FileLogger.shared.log("VideoDownloader: \(label) file not found after download")
                cleanup(videoId: videoId)
                continue
            }

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: actualTemp.path)[.size] as? Int64) ?? 0
            FileLogger.shared.log("VideoDownloader: \(label) = \(fileSize / 1024 / 1024)MB")

            if fileSize <= maxFileSize {
                // Fits! Use directly — no compression, original quality
                try? FileManager.default.moveItem(at: actualTemp, to: outputFile)
                downloadedFile = outputFile
                break
            }

            // Too large, clean up and try next format
            if label == "720p" {
                // Last format — try compression as final resort
                FileLogger.shared.log("VideoDownloader: 720p still too large, compressing...")
                let compressed = await compressVideo(input: actualTemp, output: outputFile)
                try? FileManager.default.removeItem(at: actualTemp)

                if compressed {
                    let compSize = (try? FileManager.default.attributesOfItem(atPath: outputFile.path)[.size] as? Int64) ?? 0
                    FileLogger.shared.log("VideoDownloader: compressed to \(compSize / 1024 / 1024)MB")
                    if compSize <= maxFileSize {
                        downloadedFile = outputFile
                    } else {
                        FileLogger.shared.log("VideoDownloader: still too large after compression, skipping")
                        try? FileManager.default.removeItem(at: outputFile)
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: actualTemp)
            }
        }

        guard let videoFile = downloadedFile else {
            // defer will handle cleanup
            return nil
        }

        succeeded = true
        // Download thumbnail in parallel-ish
        let thumb = await downloadThumbnail(url: url)
        return (video: videoFile, thumbnail: thumb)
    }

    /// Compress video to fit under 50MB using ffmpeg — quality-focused
    private func compressVideo(input: URL, output: URL) async -> Bool {
        let ffprobePath = shell("/usr/bin/which", ["ffprobe"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let ffmpegPath = shell("/usr/bin/which", ["ffmpeg"]).output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !ffmpegPath.isEmpty else {
            FileLogger.shared.log("VideoDownloader: ffmpeg not found")
            return false
        }

        // Calculate target bitrate from duration
        var videoBitrate = "2500k"
        var audioBitrate = "192k"

        if !ffprobePath.isEmpty {
            let probeResult = shell(ffprobePath, [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                input.path
            ])
            if let duration = Double(probeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)), duration > 0 {
                // Target 45MB with 192kbps audio
                let audioBytes = 192.0 * 1000.0 / 8.0 * duration
                let targetVideoBytes = 45.0 * 1024.0 * 1024.0 - audioBytes
                let bitrate = max(500_000, Int(targetVideoBytes * 8.0 / duration))
                videoBitrate = "\(bitrate / 1000)k"
                FileLogger.shared.log("VideoDownloader: duration \(Int(duration))s, video bitrate \(videoBitrate)")
            }
        }

        FileLogger.shared.log("VideoDownloader: compressing (keeping resolution)...")
        let result = await shellAsync(ffmpegPath, [
            "-i", input.path,
            "-c:v", "libx264",
            "-preset", "slow",
            "-b:v", videoBitrate,
            "-maxrate", "\(Int((Double(videoBitrate.dropLast()) ?? 2500) * 1.5))k",
            "-bufsize", "\(Int((Double(videoBitrate.dropLast()) ?? 2500) * 3))k",
            "-c:a", "aac",
            "-b:a", audioBitrate,
            "-movflags", "+faststart",
            "-y",
            output.path
        ])

        return result.status == 0
    }

    /// Delete a downloaded video file
    func deleteVideo(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanup(videoId: String) {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix(videoId) {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - Shell helpers

    private func shell(_ command: String, _ args: [String]) -> (output: String, status: Int32) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = shellEnvironment()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output, process.terminationStatus)
        } catch {
            return ("", -1)
        }
    }

    private func shellAsync(_ command: String, _ args: [String]) async -> (output: String, status: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = args
                process.standardOutput = pipe
                process.standardError = pipe
                process.environment = self.shellEnvironment()

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("Error: \(error)", -1))
                }
            }
        }
    }

    /// Include Homebrew paths so yt-dlp/ffmpeg are found
    private func shellEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let brewPaths = "/opt/homebrew/bin:/usr/local/bin"
        if let path = env["PATH"] {
            env["PATH"] = "\(brewPaths):\(path)"
        } else {
            env["PATH"] = brewPaths
        }
        return env
    }
}
