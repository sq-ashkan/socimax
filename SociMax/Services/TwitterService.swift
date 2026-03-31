import Foundation
import CommonCrypto

final class TwitterService {
    static let shared = TwitterService()
    private let tweetURL = "https://api.twitter.com/2/tweets"
    private let verifyURL = "https://api.twitter.com/2/users/me"
    private let mediaUploadURL = "https://upload.twitter.com/1.1/media/upload.json"

    /// Standard session for tweets & API calls (30s timeout)
    private let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Longer-timeout session for media uploads (5 min per request, 15 min total)
    private let mediaSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Max retries for media operations
    private let maxRetries = 3

    private init() {}

    // MARK: - Post Tweet

    func postTweet(
        text: String,
        mediaId: String? = nil,
        replyToTweetId: String? = nil,
        apiKey: String,
        apiSecret: String,
        accessToken: String,
        accessTokenSecret: String
    ) async throws -> String? {
        guard !text.isEmpty else { return nil }
        FileLogger.shared.log("[Twitter] Posting tweet (\(text.count) chars)\(replyToTweetId != nil ? " [reply]" : ""): \(String(text.prefix(120)))...")

        var payload: [String: Any] = ["text": text]
        if let mediaId {
            payload["media"] = ["media_ids": [mediaId]]
        }
        if let replyToTweetId {
            payload["reply"] = ["in_reply_to_tweet_id": replyToTweetId]
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: tweetURL)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let auth = oauthHeader(
            method: "POST",
            url: tweetURL,
            params: [:],
            apiKey: apiKey,
            apiSecret: apiSecret,
            accessToken: accessToken,
            accessTokenSecret: accessTokenSecret
        )
        request.setValue(auth, forHTTPHeaderField: "Authorization")

        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        if http.statusCode == 201 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tweetData = json["data"] as? [String: Any],
               let id = tweetData["id"] as? String {
                FileLogger.shared.log("[Twitter] Tweet posted: \(id)\(mediaId != nil ? " with media" : "")")
                return id
            }
            return nil
        } else if http.statusCode == 403 && mediaId != nil {
            // Media attachment might be blocked on this plan — retry without media
            FileLogger.shared.log("[Twitter] Post with media failed (403), retrying without media...")
            return try await postTweet(
                text: text,
                mediaId: nil,
                replyToTweetId: replyToTweetId,
                apiKey: apiKey, apiSecret: apiSecret,
                accessToken: accessToken, accessTokenSecret: accessTokenSecret
            )
        } else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            FileLogger.shared.log("[Twitter] Post failed (\(http.statusCode)): \(errorBody)")
            throw NetworkError.requestFailed(http.statusCode)
        }
    }

    // MARK: - Upload Image from URL

    func uploadImage(
        fromURL imageURL: String,
        apiKey: String,
        apiSecret: String,
        accessToken: String,
        accessTokenSecret: String
    ) async throws -> String? {
        guard let url = URL(string: imageURL) else { return nil }

        // Download image data with timeout
        let (imageData, _) = try await mediaSession.data(from: url)
        guard !imageData.isEmpty, imageData.count < 5_242_880 else {
            FileLogger.shared.log("[Twitter] Image too large or empty: \(imageData.count) bytes")
            return nil
        }
        FileLogger.shared.log("[Twitter] Image downloaded: \(imageData.count) bytes from \(imageURL)")

        // Retry loop for upload
        for attempt in 1...maxRetries {
            // Build multipart form (fresh boundary each attempt)
            let boundary = UUID().uuidString
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"media_data\"\r\n\r\n".data(using: .utf8)!)
            body.append(imageData.base64EncodedData())
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            var request = URLRequest(url: URL(string: mediaUploadURL)!)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = 300 // 5 min per image upload
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            // OAuth signature excludes body params for multipart
            let auth = oauthHeader(
                method: "POST", url: mediaUploadURL, params: [:],
                apiKey: apiKey, apiSecret: apiSecret,
                accessToken: accessToken, accessTokenSecret: accessTokenSecret
            )
            request.setValue(auth, forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await mediaSession.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }

                if http.statusCode == 200 || http.statusCode == 201 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let mediaId = json["media_id_string"] as? String {
                        FileLogger.shared.log("[Twitter] Image uploaded: \(mediaId) (attempt \(attempt))")
                        return mediaId
                    }
                }

                let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                FileLogger.shared.log("[Twitter] Image upload failed (\(http.statusCode), attempt \(attempt)/\(maxRetries)): \(errorBody)")

                // Don't retry on auth errors
                if http.statusCode == 401 || http.statusCode == 403 { break }

            } catch {
                FileLogger.shared.log("[Twitter] Image upload error (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription)")
            }

            // Exponential backoff before retry
            if attempt < maxRetries {
                let delay = Double(attempt * 2)
                FileLogger.shared.log("[Twitter] Retrying image upload in \(Int(delay))s...")
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        FileLogger.shared.log("[Twitter] Image upload failed after \(maxRetries) attempts")
        return nil
    }

    // MARK: - Upload Video (chunked)

    func uploadVideo(
        fileURL: URL,
        apiKey: String,
        apiSecret: String,
        accessToken: String,
        accessTokenSecret: String
    ) async throws -> String? {
        let fileData = try Data(contentsOf: fileURL)
        guard !fileData.isEmpty else { return nil }

        let totalBytes = fileData.count
        let ext = fileURL.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "mp4": mimeType = "video/mp4"
        case "mov": mimeType = "video/quicktime"
        case "gif": mimeType = "image/gif"
        default: mimeType = "video/mp4"
        }
        let creds = (apiKey: apiKey, apiSecret: apiSecret, accessToken: accessToken, accessTokenSecret: accessTokenSecret)

        FileLogger.shared.log("[Twitter] Video upload starting: \(totalBytes) bytes (\(ext))")

        // INIT
        let initParams = [
            "command": "INIT",
            "total_bytes": String(totalBytes),
            "media_type": mimeType,
            "media_category": "tweet_video"
        ]
        guard let initJson = try await mediaCommand(params: initParams, creds: creds),
              let mediaId = initJson["media_id_string"] as? String else {
            FileLogger.shared.log("[Twitter] Video INIT failed")
            return nil
        }
        FileLogger.shared.log("[Twitter] Video INIT: \(mediaId) (\(totalBytes) bytes)")

        // APPEND in 4MB chunks with retry per chunk
        let chunkSize = 4 * 1024 * 1024
        var segmentIndex = 0
        var offset = 0
        while offset < totalBytes {
            let end = min(offset + chunkSize, totalBytes)
            let chunk = fileData[offset..<end]
            var chunkSuccess = false

            for attempt in 1...maxRetries {
                let boundary = UUID().uuidString
                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"command\"\r\n\r\nAPPEND\r\n".data(using: .utf8)!)
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"media_id\"\r\n\r\n\(mediaId)\r\n".data(using: .utf8)!)
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"segment_index\"\r\n\r\n\(segmentIndex)\r\n".data(using: .utf8)!)
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"media_data\"\r\n\r\n".data(using: .utf8)!)
                body.append(chunk.base64EncodedData())
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

                var request = URLRequest(url: URL(string: mediaUploadURL)!)
                request.httpMethod = "POST"
                request.httpBody = body
                request.timeoutInterval = 300 // 5 min per chunk
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                let auth = oauthHeader(
                    method: "POST", url: mediaUploadURL, params: [:],
                    apiKey: creds.apiKey, apiSecret: creds.apiSecret,
                    accessToken: creds.accessToken, accessTokenSecret: creds.accessTokenSecret
                )
                request.setValue(auth, forHTTPHeaderField: "Authorization")

                do {
                    let (_, resp) = try await mediaSession.data(for: request)
                    if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                        chunkSuccess = true
                        break
                    }
                    FileLogger.shared.log("[Twitter] Video APPEND failed at segment \(segmentIndex) (attempt \(attempt)/\(maxRetries))")
                } catch {
                    FileLogger.shared.log("[Twitter] Video APPEND error at segment \(segmentIndex) (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription)")
                }

                if attempt < maxRetries {
                    let delay = Double(attempt * 3)
                    try? await Task.sleep(for: .seconds(delay))
                }
            }

            guard chunkSuccess else {
                FileLogger.shared.log("[Twitter] Video APPEND gave up at segment \(segmentIndex) after \(maxRetries) attempts")
                return nil
            }

            let progress = Int(Double(end) / Double(totalBytes) * 100)
            FileLogger.shared.log("[Twitter] Video APPEND segment \(segmentIndex) done (\(progress)%)")
            segmentIndex += 1
            offset = end
        }
        FileLogger.shared.log("[Twitter] Video APPEND complete: \(segmentIndex) segments")

        // FINALIZE
        let finalizeParams = ["command": "FINALIZE", "media_id": mediaId]
        guard let finalJson = try await mediaCommand(params: finalizeParams, creds: creds) else {
            FileLogger.shared.log("[Twitter] Video FINALIZE failed")
            return nil
        }

        // Check processing status
        if let processingInfo = finalJson["processing_info"] as? [String: Any] {
            let ok = try await waitForProcessing(mediaId: mediaId, info: processingInfo, creds: creds)
            if !ok {
                FileLogger.shared.log("[Twitter] Video processing failed")
                return nil
            }
        }

        FileLogger.shared.log("[Twitter] Video uploaded: \(mediaId)")
        return mediaId
    }

    // MARK: - Media helpers

    private func mediaCommand(
        params: [String: String],
        creds: (apiKey: String, apiSecret: String, accessToken: String, accessTokenSecret: String)
    ) async throws -> [String: Any]? {
        let bodyStr = params.map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }.joined(separator: "&")

        var request = URLRequest(url: URL(string: mediaUploadURL)!)
        request.httpMethod = "POST"
        request.httpBody = bodyStr.data(using: .utf8)
        request.timeoutInterval = 120 // 2 min for INIT/FINALIZE commands
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // For form-urlencoded, include params in signature
        let auth = oauthHeader(
            method: "POST", url: mediaUploadURL, params: params,
            apiKey: creds.apiKey, apiSecret: creds.apiSecret,
            accessToken: creds.accessToken, accessTokenSecret: creds.accessTokenSecret
        )
        request.setValue(auth, forHTTPHeaderField: "Authorization")

        let (data, response) = try await mediaSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        if (200...299).contains(http.statusCode) {
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
        FileLogger.shared.log("[Twitter] Media command '\(params["command"] ?? "?")' failed (\(http.statusCode)): \(errorBody)")
        return nil
    }

    private func waitForProcessing(
        mediaId: String,
        info: [String: Any],
        creds: (apiKey: String, apiSecret: String, accessToken: String, accessTokenSecret: String)
    ) async throws -> Bool {
        var processingInfo = info
        for _ in 0..<30 {
            let state = processingInfo["state"] as? String ?? ""
            if state == "succeeded" { return true }
            if state == "failed" { return false }

            let waitSecs = processingInfo["check_after_secs"] as? Int ?? 5
            try await Task.sleep(for: .seconds(waitSecs))

            // STATUS check
            let statusURL = "\(mediaUploadURL)?command=STATUS&media_id=\(mediaId)"
            var request = URLRequest(url: URL(string: statusURL)!)
            request.timeoutInterval = 30
            let auth = oauthHeader(
                method: "GET", url: mediaUploadURL,
                params: ["command": "STATUS", "media_id": mediaId],
                apiKey: creds.apiKey, apiSecret: creds.apiSecret,
                accessToken: creds.accessToken, accessTokenSecret: creds.accessTokenSecret
            )
            request.setValue(auth, forHTTPHeaderField: "Authorization")

            let (data, _) = try await apiSession.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let pi = json["processing_info"] as? [String: Any] {
                processingInfo = pi
            } else {
                return true // No processing_info means done
            }
        }
        return false
    }

    // MARK: - Test Connection

    func testConnection(
        apiKey: String,
        apiSecret: String,
        accessToken: String,
        accessTokenSecret: String
    ) async -> Bool {
        // Step 1: Verify credentials (READ)
        let auth = oauthHeader(
            method: "GET",
            url: verifyURL,
            params: [:],
            apiKey: apiKey,
            apiSecret: apiSecret,
            accessToken: accessToken,
            accessTokenSecret: accessTokenSecret
        )

        var request = URLRequest(url: URL(string: verifyURL)!)
        request.timeoutInterval = 15
        request.setValue(auth, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await apiSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let userData = json["data"] as? [String: Any],
                   let username = userData["username"] as? String {
                    FileLogger.shared.log("[Twitter] Connected as @\(username)")
                }
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                FileLogger.shared.log("[Twitter] Test failed (\(http.statusCode)): \(errorBody)")
                return false
            }
        } catch {
            FileLogger.shared.log("[Twitter] Test error: \(error.localizedDescription)")
            return false
        }

        // Step 2: Verify WRITE access by posting & deleting a test tweet
        do {
            let testText = "🔧 SociMax connection test — verifying write access for automated publishing. ID: \(UUID().uuidString.prefix(8))\n\nhttps://example.com/test"
            if let tweetId = try await postTweet(
                text: testText,
                apiKey: apiKey, apiSecret: apiSecret,
                accessToken: accessToken, accessTokenSecret: accessTokenSecret
            ) {
                // Delete the test tweet immediately
                await deleteTweet(
                    id: tweetId,
                    apiKey: apiKey, apiSecret: apiSecret,
                    accessToken: accessToken, accessTokenSecret: accessTokenSecret
                )
                FileLogger.shared.log("[Twitter] Write access verified ✓")
                return true
            } else {
                FileLogger.shared.log("[Twitter] Write test: post returned nil")
                return false
            }
        } catch {
            FileLogger.shared.log("[Twitter] Write access DENIED: \(error)")
            return false
        }
    }

    /// Delete a tweet by ID
    private func deleteTweet(
        id: String,
        apiKey: String,
        apiSecret: String,
        accessToken: String,
        accessTokenSecret: String
    ) async {
        let deleteURL = "https://api.twitter.com/2/tweets/\(id)"
        var request = URLRequest(url: URL(string: deleteURL)!)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        let auth = oauthHeader(
            method: "DELETE", url: deleteURL, params: [:],
            apiKey: apiKey, apiSecret: apiSecret,
            accessToken: accessToken, accessTokenSecret: accessTokenSecret
        )
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        _ = try? await apiSession.data(for: request)
    }

    // MARK: - OAuth 1.0a

    private func oauthHeader(
        method: String,
        url: String,
        params: [String: String],
        apiKey: String,
        apiSecret: String,
        accessToken: String,
        accessTokenSecret: String
    ) -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let timestamp = String(Int(Date().timeIntervalSince1970))

        var oauthParams: [String: String] = [
            "oauth_consumer_key": apiKey,
            "oauth_nonce": nonce,
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": timestamp,
            "oauth_token": accessToken,
            "oauth_version": "1.0"
        ]

        // Merge with any query params
        var allParams = oauthParams
        for (k, v) in params { allParams[k] = v }

        // Build parameter string (sorted)
        let paramString = allParams
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")

        // Build signature base string
        let baseString = "\(method)&\(percentEncode(url))&\(percentEncode(paramString))"

        // Signing key
        let signingKey = "\(percentEncode(apiSecret))&\(percentEncode(accessTokenSecret))"

        // HMAC-SHA1
        let signature = hmacSHA1(key: signingKey, data: baseString)
        oauthParams["oauth_signature"] = signature

        // Build Authorization header
        let headerParts = oauthParams
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\"\(percentEncode($0.value))\"" }
            .joined(separator: ", ")

        return "OAuth \(headerParts)"
    }

    private func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func hmacSHA1(key: String, data: String) -> String {
        let keyData = key.data(using: .utf8)!
        let dataData = data.data(using: .utf8)!

        var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBytes in
            dataData.withUnsafeBytes { dataBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyBytes.baseAddress, keyData.count,
                    dataBytes.baseAddress, dataData.count,
                    &result
                )
            }
        }
        return Data(result).base64EncodedString()
    }

    // MARK: - Format Tweet

    /// Format post content for Twitter's 280 char limit
    static func formatTweet(
        postContent: String,
        sourceURL: String,
        showSourceLink: Bool,
        showScores: Bool,
        viralityScore: Double,
        relevanceScore: Double,
        showHandle: Bool,
        handle: String,
        symbol: String = "none"
    ) -> String {
        // Build suffix first to know remaining space for text
        var suffix = ""
        if showSourceLink && !sourceURL.isEmpty {
            // Twitter auto-shortens URLs to 23 chars via t.co
            suffix += "\n\n\(sourceURL)"
        }
        if showScores {
            suffix += "\n\n📊 V:\(String(format: "%.1f", viralityScore)) R:\(String(format: "%.1f", relevanceScore))"
        }
        if showHandle && !handle.isEmpty {
            let h = handle.hasPrefix("@") ? handle : "@\(handle)"
            suffix += "\n\n\(h)"
        }

        // Strip HTML from post content
        var clean = postContent
        // Remove <a href="...">text</a> — keep just text
        if let regex = try? NSRegularExpression(pattern: "<a[^>]*>(.*?)</a>", options: .caseInsensitive) {
            clean = regex.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "$1")
        }
        // Remove remaining HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            clean = regex.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "")
        }
        // Remove HTML entities
        clean = clean.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        // Remove any pre-existing symbol emojis (will re-add based on symbol choice)
        for s in ["⭕️ ", "💠 ", "💢 ", "🟠 ", "🫧 ", "🔻 "] {
            clean = clean.replacingOccurrences(of: s, with: "")
        }

        // Remove source line (already in suffix) and channel handles
        let lines = clean.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return false }
                if trimmed.hasPrefix("@") { return false }  // Strip Telegram channel handles
                if trimmed.hasPrefix("📊") { return false }  // Strip embedded score lines from old posts
                // Remove lines that are just a source label
                let lower = trimmed.lowercased()
                if lower == "source" || lower == "quelle" || lower == "منبع" || lower == "المصدر" || lower == "fonte" || lower == "fuente" { return false }
                return true
            }

        let useSymbol = symbol != "none" && !symbol.isEmpty
        // Match Telegram format: title WITHOUT symbol, body paragraphs WITH symbol
        if useSymbol, let title = lines.first {
            var parts = [title.trimmingCharacters(in: .whitespaces)]
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                parts.append("\(symbol) \(trimmed)")
            }
            clean = parts.joined(separator: "\n\n")
        } else if let title = lines.first {
            var parts = [title.trimmingCharacters(in: .whitespaces)]
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                parts.append(trimmed)
            }
            clean = parts.joined(separator: "\n\n")
        }

        // Twitter counts URLs as 23 chars. Estimate suffix length accordingly.
        let urlCount = showSourceLink && !sourceURL.isEmpty ? 23 : 0
        let suffixWithoutURL = suffix.replacingOccurrences(of: sourceURL, with: "")
        let estimatedSuffixLen = suffixWithoutURL.count + urlCount

        let maxTextLen = 280 - estimatedSuffixLen
        if clean.count > maxTextLen {
            // Try to cut at last complete sentence that fits
            let candidate = String(clean.prefix(maxTextLen))
            let sentenceEnders: [Character] = [".", "!", "?", "。"]
            var bestCut = -1
            for (i, ch) in candidate.enumerated() {
                if sentenceEnders.contains(ch) {
                    bestCut = i
                }
            }
            // Use sentence boundary if it keeps at least 40% of available space
            if bestCut > maxTextLen * 40 / 100 {
                let trimmed = String(candidate.prefix(bestCut + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed + suffix
            }
            // Fallback: cut at last space to avoid breaking words
            if let lastSpace = candidate.lastIndex(of: " ") {
                let trimmed = String(candidate[candidate.startIndex..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed + suffix
            }
            let truncated = String(clean.prefix(max(0, maxTextLen - 1))) + "…"
            return truncated + suffix
        }
        return clean + suffix
    }
}
