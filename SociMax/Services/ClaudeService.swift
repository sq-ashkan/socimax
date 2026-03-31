import Foundation

private struct ClaudeResponse: Decodable {
    struct Content: Decodable {
        let text: String
    }
    let content: [Content]
}

final class ClaudeService: AIProvider {
    static let shared = ClaudeService()
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-4-6"
    private let apiVersion = "2023-06-01"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    /// Read API key from Keychain. Call from MainActor only (blocks on background threads).
    var apiKey: String {
        KeychainService.shared.get(key: "claude_api_key") ?? ""
    }

    private func callClaude(
        system: String? = nil,
        userMessage: String,
        maxTokens: Int = 300,
        key: String? = nil
    ) async throws -> String {
        let effectiveKey = key ?? apiKey
        guard let url = URL(string: baseURL) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(effectiveKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        if let system = system {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let retryPolicy = RetryPolicy.aggressive
        var lastError: Error = NetworkError.noData
        for attempt in 0..<retryPolicy.maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.noData
                }
                if (200...299).contains(httpResponse.statusCode) {
                    let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)
                    return claudeResponse.content.first?.text ?? ""
                }
                if retryPolicy.shouldRetry(statusCode: httpResponse.statusCode, attempt: attempt) {
                    let delay: TimeInterval
                    if httpResponse.statusCode == 429,
                       let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after"),
                       let seconds = Double(retryAfter) {
                        delay = seconds + Double.random(in: 0...1)
                    } else {
                        delay = retryPolicy.delay(for: attempt)
                    }
                    FileLogger.shared.log("Claude HTTP \(httpResponse.statusCode), retry in \(String(format: "%.1f", delay))s (\(attempt+1)/\(retryPolicy.maxAttempts))")
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                FileLogger.shared.log("Claude HTTP \(httpResponse.statusCode): \(responseBody)")
                throw NetworkError.requestFailed(httpResponse.statusCode)
            } catch let error as NetworkError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < retryPolicy.maxAttempts - 1 {
                    let delay = retryPolicy.delay(for: attempt)
                    FileLogger.shared.log("Claude error: \(error.localizedDescription), retry in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw NetworkError.unknown(lastError)
    }

    func testConnection() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        do {
            _ = try await callClaude(userMessage: "Say OK", maxTokens: 5)
            return true
        } catch {
            print("Claude test failed: \(error)")
            return false
        }
    }

    // MARK: - Protocol conformance (reads key from Keychain — MainActor only)

    func scoreArticles(
        articles: [(id: String, title: String, content: String)],
        channelPrompt: String
    ) async throws -> [ArticleScore] {
        try await scoreArticles(articles: articles, channelPrompt: channelPrompt, withKey: apiKey)
    }

    func generatePost(
        article: (title: String, content: String, sourceURL: String),
        channelPrompt: String,
        language: String
    ) async throws -> String {
        try await generatePost(article: article, channelPrompt: channelPrompt, language: language, withKey: apiKey)
    }

    // MARK: - Key-passing variants (safe for background threads)

    func scoreArticles(
        articles: [(id: String, title: String, content: String)],
        channelPrompt: String,
        withKey key: String
    ) async throws -> [ArticleScore] {
        let articlesJSON = articles.map { article in
            ["id": article.id, "title": article.title, "content": String(article.content.prefix(500))]
        }

        let articlesString: String
        if let data = try? JSONSerialization.data(withJSONObject: articlesJSON),
           let str = String(data: data, encoding: .utf8) {
            articlesString = str
        } else {
            articlesString = "[]"
        }

        let system = """
        You are a senior news editor with 20 years of experience. \
        You predict which stories will go viral on social media. \
        Always respond with valid JSON only.
        """

        let userPrompt = """
        Channel context: \(channelPrompt)

        Evaluate these articles:
        \(articlesString)

        For EACH article, respond in JSON with this exact format:
        {
          "articles": [
            {
              "article_id": "...",
              "virality_score": 1-10,
              "relevance_score": 1-10,
              "is_breaking": true/false,
              "reasoning": "brief explanation"
            }
          ]
        }

        Scoring guide:
        - virality_score: How likely is this to go viral on social media?
          10 = Once-a-month level event
          8-9 = Major news
          6-7 = Interesting
          4-5 = Standard
          1-3 = Low interest
        - relevance_score: How relevant to the channel?
        - is_breaking: TRUE only if ALL conditions met:
          1. Score >= 9
          2. OFFICIALLY CONFIRMED (NOT rumors/leaks/speculation)
          3. Broad impact and high urgency
          4. First-party announcement or confirmed major event
          NEVER mark rumors or unverified reports as breaking.

        Respond with JSON only, no other text.
        """

        let content = try await callClaude(
            system: system,
            userMessage: userPrompt,
            maxTokens: 1000,
            key: key
        )

        // Extract JSON from response (Claude may wrap in markdown)
        let jsonString: String
        if let start = content.range(of: "{"), let end = content.range(of: "}", options: .backwards) {
            jsonString = String(content[start.lowerBound...end.upperBound])
        } else {
            jsonString = content
        }

        guard let data = jsonString.data(using: .utf8) else { return [] }
        let scoring = try JSONDecoder().decode(ScoringResponse.self, from: data)
        return scoring.scores
    }

    func generatePost(
        article: (title: String, content: String, sourceURL: String),
        channelPrompt: String,
        language: String,
        withKey key: String,
        lengthConfig: PostLengthConfig = PostLengthConfig()
    ) async throws -> String {
        let system = """
        You are a professional news editor for a Telegram channel.

        LANGUAGE REQUIREMENT (MANDATORY): \
        You MUST write the ENTIRE post in \(language). \
        Even if the source article is in another language, you MUST translate and write in \(language). \
        Every single word of your output must be in \(language).

        FORMAT (strict — plain text, NO markdown, NO HTML): \
        Line 1: A short headline/title (plain text, no formatting, no ** or <b> tags). \
        Line 2: Empty line. \
        Line 3+: The body text in 3 sections separated by a line containing ONLY '---'. \
        \(lengthConfig.systemHint)

        RULES: \
        1. The post MUST be self-contained. The reader must understand the full story WITHOUT clicking any link. \
        2. Always mention specific names: company names, people, game titles, platforms — never be vague. \
        3. Include the WHO, WHAT, and WHY across the sections. \
        4. Do NOT use emojis, hashtags, markdown, or HTML tags. Plain text only. \
        5. Do NOT add src or source URL — it will be added automatically.
        """

        let userPrompt = """
        Channel context: \(channelPrompt)

        Article: \(article.title)
        Content: \(String(article.content.prefix(lengthConfig.contentPrefix)))

        Write a Telegram post. IMPORTANT: Write ENTIRELY in \(language). \
        Translate everything to \(language). \
        Line 1: plain title. Empty line. Then body in 3 sections: \
        \(lengthConfig.userHint) \
        No emojis, no markdown, no HTML, no ** symbols. Plain text only.
        """

        let content = try await callClaude(
            system: system,
            userMessage: userPrompt,
            maxTokens: lengthConfig.maxTokens,
            key: key
        )

        return OpenAIService.cleanContent(content)
    }

    func refineChannelProfile(
        description: String,
        audience: String,
        priorities: String,
        tone: String,
        avoid: String
    ) async throws -> String {
        let userPrompt = """
        I'm setting up an automated content channel. Help me create a clear, structured \
        editorial brief in English that an AI can use to score and write posts.

        Here's what the user provided (may be in any language):
        - Channel description: \(description)
        - Target audience: \(audience)
        - Content priorities: \(priorities)
        - Tone & style: \(tone)
        - Topics to avoid: \(avoid)

        Create a concise editorial brief (max 300 words) in English that covers:
        1. What this channel is about
        2. Who the audience is
        3. What content to prioritize (and what to skip)
        4. The writing tone and style
        5. Any restrictions

        Write it as a direct instruction to an AI editor. Be specific and actionable.
        """

        return try await callClaude(userMessage: userPrompt, maxTokens: 500)
    }
}
