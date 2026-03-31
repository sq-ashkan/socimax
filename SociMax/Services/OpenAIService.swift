import Foundation

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

final class OpenAIService: AIProvider {
    static let shared = OpenAIService()
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private let model = "gpt-4.1-mini"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    var apiKey: String {
        KeychainService.shared.get(key: "openai_api_key") ?? ""
    }

    func testConnection() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        do {
            _ = try await callOpenAI(userMessage: "Say OK", maxTokens: 5)
            return true
        } catch {
            print("OpenAI test failed: \(error)")
            return false
        }
    }

    // MARK: - Core API call with retry

    private func callOpenAI(
        system: String? = nil,
        userMessage: String,
        maxTokens: Int = 300,
        key: String? = nil,
        jsonMode: Bool = false
    ) async throws -> String {
        let effectiveKey = key ?? apiKey
        guard let url = URL(string: baseURL) else { throw NetworkError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(effectiveKey)", forHTTPHeaderField: "Authorization")

        var messages: [[String: String]] = []
        if let system = system {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": userMessage])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens
        ]
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
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
                    let chatResponse = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
                    return chatResponse.choices.first?.message.content ?? ""
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
                    FileLogger.shared.log("OpenAI HTTP \(httpResponse.statusCode), retry in \(String(format: "%.1f", delay))s (\(attempt+1)/\(retryPolicy.maxAttempts))")
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                let responseBody = String(data: data, encoding: .utf8) ?? "no body"
                FileLogger.shared.log("OpenAI HTTP \(httpResponse.statusCode): \(responseBody)")
                throw NetworkError.requestFailed(httpResponse.statusCode)
            } catch let error as NetworkError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < retryPolicy.maxAttempts - 1 {
                    let delay = retryPolicy.delay(for: attempt)
                    FileLogger.shared.log("OpenAI error: \(error.localizedDescription), retry in \(String(format: "%.1f", delay))s")
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw NetworkError.unknown(lastError)
    }

    // MARK: - Protocol conformance

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
        guard !key.isEmpty else {
            FileLogger.shared.log("OpenAI: NO API KEY — skipping")
            return []
        }

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

        let systemPrompt = """
        You are a senior news editor with 20 years of experience. \
        You predict which stories will go viral on social media.
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
          10 = Once-a-month level event, everyone will talk about it
          8-9 = Major news, high engagement expected
          6-7 = Interesting, moderate engagement
          4-5 = Standard news
          1-3 = Low interest
        - relevance_score: How relevant is this to the channel topic?
          IMPORTANT: Non-English sources (German, Japanese, Chinese, etc.) often break stories before English media. Give them HIGHER relevance if the topic fits the channel.
        - is_breaking: TRUE only if ALL of these conditions are met:
          1. Score >= 9
          2. It is OFFICIALLY CONFIRMED news (NOT rumors, leaks, or speculation)
          3. It has broad impact and high urgency
          4. It is a first-party announcement, official reveal, or confirmed major event
          NEVER mark rumors, leaks, unverified reports, or speculation as breaking.
        """

        let content = try await callOpenAI(
            system: systemPrompt,
            userMessage: userPrompt,
            maxTokens: 2000,
            key: key,
            jsonMode: true
        )

        guard let data = content.data(using: .utf8) else { return [] }
        let scoring = try JSONDecoder().decode(ScoringResponse.self, from: data)
        return scoring.scores
    }

    func generatePost(
        article: (title: String, content: String, sourceURL: String),
        channelPrompt: String,
        language: String,
        withKey key: String,
        symbolFormat: Bool = false,
        lengthConfig: PostLengthConfig = PostLengthConfig()
    ) async throws -> String {
        let systemPrompt = """
        Telegram news editor. Write in \(language). Plain text only. \
        Line 1: short title. Empty line. Then body in 3 sections separated by '---' on its own line. \
        \(lengthConfig.systemHint) \
        Specific names, no filler. No emojis/hashtags/markdown/HTML/source URL.
        """

        let userPrompt = """
        Channel: \(channelPrompt)
        Article: \(article.title)
        Content: \(String(article.content.prefix(lengthConfig.contentPrefix)))

        \(lengthConfig.userHint) Write in \(language). Plain text.
        """

        let content = try await callOpenAI(
            system: systemPrompt,
            userMessage: userPrompt,
            maxTokens: lengthConfig.maxTokens,
            key: key
        )

        return Self.cleanContent(content)
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

        return try await callOpenAI(userMessage: userPrompt, maxTokens: 500)
    }

    // MARK: - Clean AI content (strip markdown/HTML, preserve --- structure)

    static func cleanContent(_ content: String) -> String {
        var cleaned = content
        cleaned = cleaned.replacingOccurrences(of: "**", with: "")
        cleaned = cleaned.replacingOccurrences(of: "__", with: "")
        if let regex = try? NSRegularExpression(pattern: "[*_]([^*_]+)[*_]") {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "$1"
            )
        }
        if let htmlRegex = try? NSRegularExpression(pattern: "<[^>]+>") {
            cleaned = htmlRegex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
            )
        }
        cleaned = cleaned.replacingOccurrences(of: "### ", with: "")
        cleaned = cleaned.replacingOccurrences(of: "## ", with: "")
        cleaned = cleaned.replacingOccurrences(of: "# ", with: "")
        let lines = cleaned.components(separatedBy: "\n").filter {
            !$0.lowercased().hasPrefix("src:") && !$0.lowercased().hasPrefix("source:")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
