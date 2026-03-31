import Foundation

private struct GrokChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

final class GrokService: AIProvider {
    static let shared = GrokService()
    private let baseURL = "https://api.x.ai/v1/chat/completions"
    private let model = "grok-4.20-0309-non-reasoning"

    private init() {}

    /// Read API key from Keychain. Call from MainActor only (blocks on background threads).
    var apiKey: String {
        KeychainService.shared.get(key: "grok_api_key") ?? ""
    }

    func testConnection() async -> Bool {
        guard !apiKey.isEmpty else { return false }
        do {
            let _: GrokChatResponse = try await NetworkClient.shared.postJSON(
                url: baseURL,
                headers: ["Authorization": "Bearer \(apiKey)"],
                body: [
                    "model": model,
                    "messages": [
                        ["role": "user", "content": "Say OK"]
                    ],
                    "max_tokens": 5
                ]
            )
            return true
        } catch {
            print("Grok test failed: \(error)")
            return false
        }
    }

    // MARK: - Protocol conformance (reads key from Keychain — MainActor only)

    func scoreArticles(
        articles: [(id: String, title: String, content: String)],
        channelPrompt: String
    ) async throws -> [ArticleScore] {
        let withHint = articles.map { (id: $0.id, title: $0.title, content: $0.content, sourceHint: "") }
        return try await scoreArticles(articles: withHint, channelPrompt: channelPrompt, withKey: apiKey)
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
        articles: [(id: String, title: String, content: String, sourceHint: String)],
        channelPrompt: String,
        withKey key: String
    ) async throws -> [ArticleScore] {
        guard !key.isEmpty else {
            FileLogger.shared.log("Grok: NO API KEY — skipping")
            return []
        }

        // Build compact article list: "0: Title | snippet [WANT: source hint]"
        let articlesText = articles.enumerated().map { i, a in
            var line = "\(i): \(a.title) | \(String(a.content.prefix(300)))"
            if !a.sourceHint.isEmpty {
                line += " [WANT: \(a.sourceHint)]"
            }
            return line
        }.joined(separator: "\n")

        let systemPrompt = "You score news articles for virality on social media. Be concise."

        let userPrompt = """
        Channel: \(channelPrompt)

        Articles:
        \(articlesText)

        Return JSON: {"a":[{"i":0,"v":8,"r":7,"b":false},...]}\
        Keys: i=index, v=virality(1-10), r=relevance(1-10), b=breaking(bool).\
        v: 10=once-a-month event, 8-9=major, 6-7=moderate, 4-5=standard, 1-3=low.\
        r: score based on channel description AND [WANT] hint if present. 10=exactly what's wanted, 1=irrelevant.\
        IMPORTANT: Non-English sources (German, Japanese, Chinese, etc.) often break stories before English media. Give them HIGHER relevance if the topic fits the channel.\
        b=true ONLY if v>=9 AND officially confirmed (not rumors/leaks).
        """

        let response: GrokChatResponse = try await NetworkClient.shared.postJSON(
            url: baseURL,
            headers: ["Authorization": "Bearer \(key)"],
            body: [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "response_format": ["type": "json_object"],
                "max_tokens": 500
            ]
        )

        guard let content = response.choices.first?.message.content,
              let data = content.data(using: .utf8) else {
            FileLogger.shared.log("Grok: empty response")
            return []
        }

        let scoring = try JSONDecoder().decode(ScoringResponse.self, from: data)

        // Map compact index-based IDs back to real article UUIDs
        return scoring.scores.compactMap { score in
            guard let idx = Int(score.articleId), idx >= 0, idx < articles.count else {
                return score // already has a real ID (legacy format)
            }
            return ArticleScore(
                articleId: articles[idx].id,
                viralityScore: score.viralityScore,
                relevanceScore: score.relevanceScore,
                isBreaking: score.isBreaking
            )
        }
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

        let response: GrokChatResponse = try await NetworkClient.shared.postJSON(
            url: baseURL,
            headers: ["Authorization": "Bearer \(key)"],
            body: [
                "model": model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "max_tokens": lengthConfig.maxTokens
            ]
        )

        let content = response.choices.first?.message.content ?? ""
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

        let response: GrokChatResponse = try await NetworkClient.shared.postJSON(
            url: baseURL,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: [
                "model": model,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ],
                "max_tokens": 500
            ]
        )

        return response.choices.first?.message.content ?? ""
    }
}
