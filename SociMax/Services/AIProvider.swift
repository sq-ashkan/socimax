import Foundation

struct ArticleScore: Decodable {
    let articleId: String
    let viralityScore: Double
    let relevanceScore: Double
    let isBreaking: Bool

    /// Direct init for index-to-UUID mapping
    init(articleId: String, viralityScore: Double, relevanceScore: Double, isBreaking: Bool) {
        self.articleId = articleId
        self.viralityScore = viralityScore
        self.relevanceScore = relevanceScore
        self.isBreaking = isBreaking
    }

    /// Decode both compact {"i":0,"v":8,"r":7,"b":false} and legacy format
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexKeys.self)

        // articleId: compact "i" (Int index) or legacy "article_id" (String)
        if let idx = try? container.decode(Int.self, forKey: .i) {
            articleId = String(idx)
        } else if let id = try? container.decode(String.self, forKey: .articleId) {
            articleId = id
        } else {
            articleId = ""
        }

        viralityScore = (try? container.decode(Double.self, forKey: .v))
            ?? (try? container.decode(Double.self, forKey: .viralityScore)) ?? 0
        relevanceScore = (try? container.decode(Double.self, forKey: .r))
            ?? (try? container.decode(Double.self, forKey: .relevanceScore)) ?? 0
        isBreaking = (try? container.decode(Bool.self, forKey: .b))
            ?? (try? container.decode(Bool.self, forKey: .isBreaking)) ?? false
    }

    private enum FlexKeys: String, CodingKey {
        case i, v, r, b
        case articleId = "article_id"
        case viralityScore = "virality_score"
        case relevanceScore = "relevance_score"
        case isBreaking = "is_breaking"
    }
}

struct ScoringResponse: Decodable {
    let articles: [ArticleScore]?
    let a: [ArticleScore]?

    /// Return whichever array exists (compact "a" or legacy "articles")
    var scores: [ArticleScore] { a ?? articles ?? [] }
}

protocol AIProvider {
    func testConnection() async -> Bool

    func scoreArticles(
        articles: [(id: String, title: String, content: String)],
        channelPrompt: String
    ) async throws -> [ArticleScore]

    func generatePost(
        article: (title: String, content: String, sourceURL: String),
        channelPrompt: String,
        language: String
    ) async throws -> String

    func refineChannelProfile(
        description: String,
        audience: String,
        priorities: String,
        tone: String,
        avoid: String
    ) async throws -> String
}

final class AIProviderFactory {
    static func provider(for project: Project) -> AIProvider {
        return provider(named: project.aiProvider)
    }

    static func provider(named name: String) -> AIProvider {
        // Return requested provider if its key exists, otherwise fallback to any available provider
        switch name {
        case "openai" where !OpenAIService.shared.apiKey.isEmpty:
            return OpenAIService.shared
        case "grok" where !GrokService.shared.apiKey.isEmpty:
            return GrokService.shared
        default:
            // Fallback: use whichever provider has a key
            if !OpenAIService.shared.apiKey.isEmpty { return OpenAIService.shared }
            if !GrokService.shared.apiKey.isEmpty { return GrokService.shared }
            // No keys at all — return OpenAI (will fail with auth error)
            return OpenAIService.shared
        }
    }
}
