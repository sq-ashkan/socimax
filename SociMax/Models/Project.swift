import Foundation
import SwiftData

let supportedLanguages = [
    "English", "Persian (فارسی)", "German (Deutsch)", "French (Français)",
    "Spanish (Español)", "Arabic (العربية)", "Turkish (Türkçe)",
    "Italian (Italiano)", "Portuguese (Português)", "Russian (Русский)",
    "Chinese (中文)", "Japanese (日本語)", "Korean (한국어)"
]

let supportedAIProviders = ["openai", "grok"]
let supportedPostLengths = ["short", "medium", "long"]

@Model
final class Project {
    var id: UUID = UUID()
    var name: String = ""
    var channelDescription: String = ""
    var targetAudience: String = ""
    var contentPriorities: String = ""
    var toneDescription: String = ""
    var avoidTopics: String = ""
    var refinedPrompt: String = ""
    var aiProvider: String = "openai"
    var telegramBotToken: String = ""
    var telegramChannelId: String = ""
    var crawlIntervalMinutes: Int = 30
    var publishIntervalMinutes: Int = 5
    var maxPostsPerDay: Int = 50
    var breakingThreshold: Double = 9.0
    var decayFactor: Double = 0.1
    var maxQueueAgeHours: Int = 24
    var minPublishScore: Double = 5.0
    var minRelevanceScore: Double = 5.0
    var minYoutubeScore: Double = 2.0
    var dedupThreshold: Double = 0.8
    var dedupYoutubeThreshold: Double = 0.95
    var requireMedia: Bool = true
    var useSymbolFormat: Bool = true
    var postLanguage: String = "English"
    var postLength: String = "short"           // legacy — kept for migration
    var telegramPostLength: String = "long"
    var twitterPostLength: String = "short"
    var breakingTelegram: Bool = true
    var breakingTwitter: Bool = true
    var isActive: Bool = false
    var createdAt: Date = Date()

    // Per-channel settings — Telegram
    var telegramShowChannelTag: Bool = true
    var telegramPublishIntervalMinutes: Int = 5
    var telegramMaxPostsPerDay: Int = 50
    var telegramShowScores: Bool = true
    var telegramSymbolFormat: Bool = true  // legacy — kept for migration
    var telegramSymbol: String = "⭕️"
    var telegramShowSourceLink: Bool = true

    // Per-channel settings — Twitter
    var twitterApiKey: String = ""
    var twitterApiSecret: String = ""
    var twitterAccessToken: String = ""
    var twitterAccessTokenSecret: String = ""
    var twitterEnabled: Bool = false
    var twitterPublishIntervalMinutes: Int = 15
    var twitterMaxPostsPerDay: Int = 48
    var twitterShowScores: Bool = false
    var twitterShowSourceLink: Bool = true
    var twitterShowHandle: Bool = true
    var twitterHandle: String = ""
    var twitterSymbolFormat: Bool = false  // legacy — kept for migration
    var twitterSymbol: String = "none"
    var twitterSourceAsReply: Bool = false
    var twitterRequireImage: Bool = true
    var twitterMaxAgeHours: Double = 24

    // Per-channel settings — LinkedIn
    var linkedinAccessToken: String = ""
    var linkedinPersonId: String = ""
    var linkedinEnabled: Bool = false
    var linkedinPublishIntervalMinutes: Int = 15
    var linkedinMaxPostsPerDay: Int = 10
    var linkedinShowScores: Bool = false
    var linkedinShowSourceLink: Bool = true
    var linkedinShowHandle: Bool = false
    var linkedinHandle: String = ""
    var linkedinSymbol: String = "none"
    var linkedinSourceAsComment: Bool = false
    var linkedinRequireImage: Bool = true
    var linkedinPostLength: String = "short"
    var linkedinMaxAgeHours: Double = 48
    var breakingLinkedin: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \Source.project)
    var sources: [Source]

    @Relationship(deleteRule: .cascade, inverse: \GeneratedPost.project)
    var posts: [GeneratedPost]

    init(
        name: String,
        channelDescription: String = "",
        targetAudience: String = "",
        contentPriorities: String = "",
        toneDescription: String = "",
        avoidTopics: String = "",
        refinedPrompt: String = "",
        aiProvider: String = "openai",
        telegramBotToken: String = "",
        telegramChannelId: String = "",
        crawlIntervalMinutes: Int = 30,
        publishIntervalMinutes: Int = 5,
        maxPostsPerDay: Int = 50,
        breakingThreshold: Double = 9.0,
        decayFactor: Double = 0.1,
        maxQueueAgeHours: Int = 24,
        minPublishScore: Double = 5.0,
        minRelevanceScore: Double = 5.0,
        minYoutubeScore: Double = 5.0,
        dedupThreshold: Double = 0.8,
        dedupYoutubeThreshold: Double = 0.95,
        requireMedia: Bool = true,
        useSymbolFormat: Bool = true,
        postLanguage: String = "English",
        isActive: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.channelDescription = channelDescription
        self.targetAudience = targetAudience
        self.contentPriorities = contentPriorities
        self.toneDescription = toneDescription
        self.avoidTopics = avoidTopics
        self.refinedPrompt = refinedPrompt
        self.aiProvider = aiProvider
        self.telegramBotToken = telegramBotToken
        self.telegramChannelId = telegramChannelId
        self.crawlIntervalMinutes = crawlIntervalMinutes
        self.publishIntervalMinutes = publishIntervalMinutes
        self.maxPostsPerDay = maxPostsPerDay
        self.breakingThreshold = breakingThreshold
        self.decayFactor = decayFactor
        self.maxQueueAgeHours = maxQueueAgeHours
        self.minPublishScore = minPublishScore
        self.minRelevanceScore = minRelevanceScore
        self.minYoutubeScore = minYoutubeScore
        self.dedupThreshold = dedupThreshold
        self.dedupYoutubeThreshold = dedupYoutubeThreshold
        self.requireMedia = requireMedia
        self.useSymbolFormat = useSymbolFormat
        self.postLanguage = postLanguage
        self.isActive = isActive
        self.createdAt = Date()
        self.sources = []
        self.posts = []
    }

    /// The prompt to use for AI calls — refined if available, otherwise raw description
    var effectivePrompt: String {
        if !refinedPrompt.isEmpty { return refinedPrompt }
        return channelDescription
    }

    var postsPublishedToday: Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return posts.filter { post in
            post.status == .published &&
            post.publishedAt != nil &&
            post.publishedAt! >= startOfDay
        }.count
    }

    var canPublish: Bool {
        postsPublishedToday < telegramMaxPostsPerDay
    }

    var twitterPostsPublishedToday: Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return posts.filter { post in
            post.status == .published &&
            !post.twitterTweetId.isEmpty &&
            post.publishedAt != nil &&
            post.publishedAt! >= startOfDay
        }.count
    }

    var canPublishTwitter: Bool {
        twitterPostsPublishedToday < twitterMaxPostsPerDay
    }

    var linkedinPostsPublishedToday: Int {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return posts.filter { post in
            post.status == .published &&
            !post.linkedinPostId.isEmpty &&
            post.publishedAt != nil &&
            post.publishedAt! >= startOfDay
        }.count
    }

    var canPublishLinkedin: Bool {
        linkedinPostsPublishedToday < linkedinMaxPostsPerDay
    }

    /// AI generation config — always generates structured 3-section content
    var lengthConfig: PostLengthConfig { PostLengthConfig() }
}

// MARK: - Structured Post Length

struct PostLengthConfig: Sendable {
    let systemHint: String
    let userHint: String
    let maxTokens: Int
    let contentPrefix: Int

    /// Always generate all 3 sections; extraction per platform happens later
    init() {
        systemHint = """
        The body MUST have exactly 3 paragraphs. \
        Between each paragraph, put '---' alone on its own line (NOT inline, NOT inside a sentence). \
        NEVER write '---' inside a sentence. It must be on a separate line by itself.
        Paragraph 1 (HEADLINE): ONE short sentence only. Max 80 characters. Just the core news fact.
        Paragraph 2 (DETAIL): 2-3 sentences. Max 200 characters. Key details and context.
        Paragraph 3 (BACKGROUND): 2-3 sentences. Max 200 characters. Broader implications or background.
        IMPORTANT: The separator '---' must appear on its own line, never within text. \
        Each paragraph is separated by a line break, then '---', then another line break.
        """
        userHint = """
        Structure your response as:
        [title]

        [1 short sentence, max 80 chars — the key fact]
        ---
        [2-3 sentences, max 200 chars — details]
        ---
        [2-3 sentences, max 200 chars — background]

        CRITICAL: '---' must be on its own line between paragraphs. Never put --- inside a sentence.
        Paragraph 1 must be very short — ONE sentence, under 80 characters.

        Here are 3 examples of correct output format:

        Example 1:
        PS5 Price Increase Confirmed Globally

        Sony confirms global PS5 price hikes starting April.
        ---
        The increase affects PS5, PS5 Pro, and PlayStation Portal across all markets. European prices see the largest jump at roughly 10%.
        ---
        This marks Sony's second price adjustment since launch, following the 2022 increase attributed to inflation and supply chain pressures.

        Example 2:
        OpenAI Launches GPT-5 Model

        OpenAI officially releases GPT-5 with major upgrades.
        ---
        The new model features improved reasoning, native image generation, and 1M token context window. It is available to Plus and Enterprise users first.
        ---
        GPT-5 arrives amid fierce competition from Google Gemini and Anthropic Claude, as the AI industry races toward more capable foundation models.

        Example 3:
        Tesla Recalls 500K Vehicles Over Software Bug

        Tesla issues voluntary recall for half a million cars.
        ---
        The recall targets Model 3 and Model Y vehicles from 2022-2024. A software bug in the autopilot system may cause delayed braking response.
        ---
        NHTSA had been investigating the issue since January after receiving over 200 complaints. Tesla says an over-the-air update will fix the problem within days.
        """
        maxTokens = 300
        contentPrefix = 2000
    }

    /// Extract sections from AI-generated content based on platform length setting.
    /// The content may be raw AI text OR formatted (with ⭕️, HTML source link, etc.).
    /// Clean all --- delimiters from final content (both line-based and inline)
    static func cleanDelimiters(_ text: String) -> String {
        var result = text
        // Remove --- on its own line
        result = result.replacingOccurrences(of: "\n---\n", with: "\n\n")
        // Remove inline " --- " within sentences
        result = result.replacingOccurrences(of: " --- ", with: " ")
        // Remove leftover standalone --- lines
        let lines = result.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != "---" }
        return lines.joined(separator: "\n")
    }

    static func extractSections(_ content: String, for length: String) -> String {
        guard length != "long" else {
            return cleanDelimiters(content)
        }

        // Separate trailing source link / footer from body
        let lines = content.components(separatedBy: "\n")
        var bodyLines: [String] = []
        var footerLines: [String] = []
        var inFooter = false
        for line in lines.reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !inFooter && (t.hasPrefix("<a href") || t.hasPrefix("🔻") || (t.isEmpty && footerLines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.contains("<a href") || $0.contains("🔻") })) {
                footerLines.insert(line, at: 0)
            } else {
                inFooter = true
                bodyLines.insert(line, at: 0)
            }
        }

        let body = bodyLines.joined(separator: "\n")
        let footer = footerLines.joined(separator: "\n")

        // Split by --- delimiter (line-based or inline)
        var sections: [String]
        if body.contains("\n---\n") {
            sections = body.components(separatedBy: "\n---\n")
        } else {
            // Fallback: AI put --- inline — split by " --- "
            sections = body.components(separatedBy: " --- ")
        }

        let count: Int
        switch length {
        case "short": count = 1
        case "medium": count = 2
        default: count = sections.count
        }

        var result = sections.prefix(count)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Clean any remaining --- artifacts
        result = cleanDelimiters(result)
        if !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result += "\n" + footer
        }
        return result
    }

    // MARK: - Telegram formatting (applied AFTER section extraction)

    static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func sourceLabel(for language: String) -> String {
        let lang = language.lowercased()
        if lang.contains("persian") || lang.contains("فارسی") { return "منبع" }
        if lang.contains("arabic") || lang.contains("العربية") { return "المصدر" }
        if lang.contains("german") || lang.contains("deutsch") { return "Quelle" }
        if lang.contains("french") || lang.contains("français") { return "Source" }
        if lang.contains("spanish") || lang.contains("español") { return "Fuente" }
        if lang.contains("turkish") || lang.contains("türkçe") { return "Kaynak" }
        if lang.contains("italian") || lang.contains("italiano") { return "Fonte" }
        if lang.contains("portuguese") || lang.contains("português") { return "Fonte" }
        if lang.contains("russian") || lang.contains("русский") { return "Источник" }
        if lang.contains("chinese") || lang.contains("中文") { return "来源" }
        if lang.contains("japanese") || lang.contains("日本語") { return "出典" }
        if lang.contains("korean") || lang.contains("한국어") { return "출처" }
        return "Source"
    }

    /// Format extracted sections for Telegram with optional symbol and source link.
    /// Called AFTER extractSections — content has no --- delimiters.
    /// symbol: emoji string like "⭕️", "💠", etc. or "none" for no symbol.
    static func formatForTelegram(
        sections: String,
        sourceURL: String,
        language: String,
        symbol: String,
        showSourceLink: Bool = true
    ) -> String {
        let lines = sections.components(separatedBy: "\n")
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let title = nonEmpty.first else { return htmlEscape(sections) }

        let sourceLink = "<a href=\"\(sourceURL)\">\(sourceLabel(for: language))</a>"
        let bodyParagraphs = Array(nonEmpty.dropFirst())
        let useSymbol = symbol != "none" && !symbol.isEmpty

        if useSymbol {
            var result = "\(htmlEscape(title))\n\n"
            for paragraph in bodyParagraphs {
                let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                result += "\(symbol) \(htmlEscape(trimmed))\n\n"
            }
            if showSourceLink {
                result += "\n🔻 \(sourceLink)"
            }
            return result
        } else {
            var result = "\(htmlEscape(title))\n\n"
            if !bodyParagraphs.isEmpty {
                let body = bodyParagraphs.joined(separator: "\n\n")
                result += "\(htmlEscape(body))\n"
            }
            if showSourceLink {
                result += "\n\(sourceLink)"
            }
            return result
        }
    }
}
