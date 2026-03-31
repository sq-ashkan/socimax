import Foundation

final class LinkedInService {
    static let shared = LinkedInService()
    private let postURL = "https://api.linkedin.com/rest/posts"
    private let imageInitURL = "https://api.linkedin.com/rest/images?action=initializeUpload"
    private let userInfoURL = "https://api.linkedin.com/v2/userinfo"
    private let apiVersion = "202603"

    private let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private let mediaSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private let maxRetries = 3

    private init() {}

    // MARK: - Common Headers

    private func authHeaders(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "LinkedIn-Version": apiVersion,
            "Content-Type": "application/json",
            "X-Restli-Protocol-Version": "2.0.0"
        ]
    }

    // MARK: - Post to LinkedIn

    func postToLinkedIn(
        text: String,
        sourceURL: String? = nil,
        sourceTitle: String? = nil,
        imageURN: String? = nil,
        accessToken: String,
        personId: String
    ) async throws -> String? {
        guard !text.isEmpty else { return nil }
        FileLogger.shared.log("[LinkedIn] Posting (\(text.count) chars): \(String(text.prefix(120)))...")

        let authorURN = "urn:li:person:\(personId)"

        var payload: [String: Any] = [
            "author": authorURN,
            "commentary": text,
            "visibility": "PUBLIC",
            "distribution": [
                "feedDistribution": "MAIN_FEED",
                "targetEntities": [],
                "thirdPartyDistributionChannels": []
            ],
            "lifecycleState": "PUBLISHED"
        ]

        // Add article with optional image
        if let url = sourceURL, !url.isEmpty {
            var article: [String: Any] = [
                "source": url
            ]
            if let title = sourceTitle, !title.isEmpty {
                article["title"] = title
            }
            if let urn = imageURN, !urn.isEmpty {
                article["thumbnail"] = urn
            }
            payload["content"] = ["article": article]
        } else if let urn = imageURN, !urn.isEmpty {
            // Image-only post (no article link)
            payload["content"] = [
                "media": [
                    "id": urn
                ]
            ]
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: postURL)!)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in authHeaders(token: accessToken) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }

        if http.statusCode == 201 {
            // LinkedIn returns post URN in x-restli-id header
            if let postId = http.value(forHTTPHeaderField: "x-restli-id") {
                FileLogger.shared.log("[LinkedIn] Published: \(postId)\(imageURN != nil ? " +img" : "")")
                return postId
            }
            // Fallback: try response body
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = json["id"] as? String {
                FileLogger.shared.log("[LinkedIn] Published: \(id)")
                return id
            }
            FileLogger.shared.log("[LinkedIn] Published (no ID returned)")
            return "published"
        } else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            FileLogger.shared.log("[LinkedIn] Post failed (\(http.statusCode)): \(errorBody)")
            throw NetworkError.requestFailed(http.statusCode)
        }
    }

    // MARK: - Post Comment (source as comment)

    @discardableResult
    func postComment(
        postURN: String,
        text: String,
        accessToken: String,
        personId: String
    ) async throws -> Bool {
        // Fully percent-encode colons in URN — LinkedIn v2 API requires it
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encodedURN = postURN.addingPercentEncoding(withAllowedCharacters: allowed) ?? postURN
        let commentURL = "https://api.linkedin.com/v2/socialActions/\(encodedURN)/comments"
        let authorURN = "urn:li:person:\(personId)"

        let payload: [String: Any] = [
            "actor": authorURN,
            "message": ["text": text]
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: commentURL)!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await apiSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            FileLogger.shared.log("[LinkedIn] Comment failed (\(http.statusCode)): \(errorBody)")
            return false
        }
        return true
    }

    // MARK: - Upload Image

    func uploadImage(
        fromURL imageURL: String,
        accessToken: String,
        personId: String
    ) async throws -> String? {
        guard let url = URL(string: imageURL) else { return nil }

        // Download image
        let (imageData, _) = try await mediaSession.data(from: url)
        guard !imageData.isEmpty, imageData.count < 10_000_000 else {
            FileLogger.shared.log("[LinkedIn] Image too large or empty: \(imageData.count) bytes")
            return nil
        }
        FileLogger.shared.log("[LinkedIn] Image downloaded: \(imageData.count) bytes from \(imageURL)")

        // Step 1: Initialize upload
        let ownerURN = "urn:li:person:\(personId)"
        let initPayload: [String: Any] = [
            "initializeUploadRequest": [
                "owner": ownerURN
            ]
        ]
        let initBody = try JSONSerialization.data(withJSONObject: initPayload)
        var initRequest = URLRequest(url: URL(string: imageInitURL)!)
        initRequest.httpMethod = "POST"
        initRequest.httpBody = initBody
        for (key, value) in authHeaders(token: accessToken) {
            initRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (initData, initResponse) = try await apiSession.data(for: initRequest)
        guard let initHttp = initResponse as? HTTPURLResponse, initHttp.statusCode == 200 else {
            let errorBody = String(data: initData, encoding: .utf8) ?? "unknown"
            FileLogger.shared.log("[LinkedIn] Image init failed: \(errorBody)")
            return nil
        }

        guard let initJson = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
              let value = initJson["value"] as? [String: Any],
              let uploadUrl = value["uploadUrl"] as? String,
              let imageURN = value["image"] as? String else {
            FileLogger.shared.log("[LinkedIn] Image init: bad response")
            return nil
        }

        // Step 2: Upload binary data
        for attempt in 1...maxRetries {
            var uploadRequest = URLRequest(url: URL(string: uploadUrl)!)
            uploadRequest.httpMethod = "PUT"
            uploadRequest.httpBody = imageData
            uploadRequest.timeoutInterval = 300
            uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            do {
                let (_, uploadResponse) = try await mediaSession.data(for: uploadRequest)
                if let uploadHttp = uploadResponse as? HTTPURLResponse, (200...299).contains(uploadHttp.statusCode) {
                    FileLogger.shared.log("[LinkedIn] Image uploaded: \(imageURN) (attempt \(attempt))")
                    return imageURN
                }
                FileLogger.shared.log("[LinkedIn] Image upload failed (attempt \(attempt)/\(maxRetries))")
            } catch {
                FileLogger.shared.log("[LinkedIn] Image upload error (attempt \(attempt)/\(maxRetries)): \(error.localizedDescription)")
            }

            if attempt < maxRetries {
                let delay = Double(attempt * 2)
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        FileLogger.shared.log("[LinkedIn] Image upload failed after \(maxRetries) attempts")
        return nil
    }

    // MARK: - Test Connection

    func testConnection(accessToken: String, personId: String) async -> Bool {
        var request = URLRequest(url: URL(string: userInfoURL)!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await apiSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = json["name"] as? String {
                    FileLogger.shared.log("[LinkedIn] Connected as \(name) (person:\(personId))")
                }
                return true
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                FileLogger.shared.log("[LinkedIn] Test failed (\(http.statusCode)): \(errorBody)")
                return false
            }
        } catch {
            FileLogger.shared.log("[LinkedIn] Test error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Format LinkedIn Post

    /// Format post content for LinkedIn (~3000 char limit). Same logic as formatTweet but more space.
    static func formatLinkedInPost(
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
        var suffix = ""
        if showSourceLink && !sourceURL.isEmpty {
            suffix += "\n\n\(sourceURL)"
        }
        if showScores {
            suffix += "\n\n📊 V:\(String(format: "%.1f", viralityScore)) R:\(String(format: "%.1f", relevanceScore))"
        }
        if showHandle && !handle.isEmpty {
            suffix += "\n\n\(handle)"
        }

        // Strip HTML
        var clean = postContent
        if let regex = try? NSRegularExpression(pattern: "<a[^>]*>(.*?)</a>", options: .caseInsensitive) {
            clean = regex.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "$1")
        }
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            clean = regex.stringByReplacingMatches(in: clean, range: NSRange(clean.startIndex..., in: clean), withTemplate: "")
        }
        clean = clean.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        for s in ["⭕️ ", "💠 ", "💢 ", "🟠 ", "🫧 ", "🔻 "] {
            clean = clean.replacingOccurrences(of: s, with: "")
        }

        // Remove source lines and channel handles
        let lines = clean.components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return false }
                if trimmed.hasPrefix("@") { return false }  // Strip Telegram channel handles
                if trimmed.hasPrefix("📊") { return false }  // Strip embedded score lines from old posts
                let lower = trimmed.lowercased()
                if lower == "source" || lower == "quelle" || lower == "منبع" || lower == "المصدر" || lower == "fonte" || lower == "fuente" { return false }
                return true
            }

        let useSymbol = symbol != "none" && !symbol.isEmpty
        // Title without symbol, body with symbol (same as Twitter/Telegram)
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

        // LinkedIn limit ~3000 chars
        let maxTextLen = 3000 - suffix.count
        if clean.count > maxTextLen {
            let candidate = String(clean.prefix(maxTextLen))
            let sentenceEnders: [Character] = [".", "!", "?", "。"]
            var bestCut = -1
            for (i, ch) in candidate.enumerated() {
                if sentenceEnders.contains(ch) { bestCut = i }
            }
            if bestCut > maxTextLen * 40 / 100 {
                return String(candidate.prefix(bestCut + 1)).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
            }
            if let lastSpace = candidate.lastIndex(of: " ") {
                return String(candidate[candidate.startIndex..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + suffix
            }
            return String(clean.prefix(max(0, maxTextLen - 1))) + "…" + suffix
        }
        return clean + suffix
    }
}
