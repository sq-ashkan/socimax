import Foundation
import SwiftData

// MARK: - Source Backup

struct SourceBackup: Codable {
    let url: String
    let name: String
    let sourceType: String
    let youtubeChannelId: String
    let youtubeFilter: String
    let refinedYoutubeFilter: String?
    let youtubeDescription: String?
    let refinedYoutubeDescription: String?

    init(from source: Source) {
        self.url = source.url
        self.name = source.name
        self.sourceType = source.sourceType
        self.youtubeChannelId = source.youtubeChannelId
        self.youtubeFilter = source.youtubeFilter
        self.refinedYoutubeFilter = source.refinedYoutubeFilter.isEmpty ? nil : source.refinedYoutubeFilter
        self.youtubeDescription = source.youtubeDescription.isEmpty ? nil : source.youtubeDescription
        self.refinedYoutubeDescription = source.refinedYoutubeDescription.isEmpty ? nil : source.refinedYoutubeDescription
    }

    func toSource() -> Source {
        let source = Source(url: url, name: name, sourceType: sourceType)
        source.youtubeChannelId = youtubeChannelId
        source.youtubeFilter = youtubeFilter
        source.refinedYoutubeFilter = refinedYoutubeFilter ?? ""
        source.youtubeDescription = youtubeDescription ?? ""
        source.refinedYoutubeDescription = refinedYoutubeDescription ?? ""
        return source
    }
}

// MARK: - Article Backup

struct ArticleBackup: Codable {
    let title: String
    let content: String
    let sourceURL: String
    let mediaURL: String?
    let viralityScore: Double
    let relevanceScore: Double
    let isBreaking: Bool
    let fetchedAt: Date

    init(from article: FetchedArticle) {
        self.title = article.title
        self.content = article.content
        self.sourceURL = article.sourceURL
        self.mediaURL = article.mediaURL
        self.viralityScore = article.viralityScore
        self.relevanceScore = article.relevanceScore
        self.isBreaking = article.isBreaking
        self.fetchedAt = article.fetchedAt
    }
}

// MARK: - Post Backup

struct PostBackup: Codable {
    let content: String
    let status: String
    let publishedAt: Date?
    let createdAt: Date
    let telegramMessageId: Int?
    let articleTitle: String?

    init(from post: GeneratedPost) {
        self.content = post.content
        self.status = post.statusRaw
        self.publishedAt = post.publishedAt
        self.createdAt = post.createdAt
        self.telegramMessageId = post.telegramMessageId
        self.articleTitle = post.article?.title
    }
}

// MARK: - Performance Backup

struct PerformanceBackup: Codable {
    let views: Int
    let predictedScore: Double
    let checkedAt: Date

    init(from perf: PostPerformance) {
        self.views = perf.views
        self.predictedScore = perf.predictedScore
        self.checkedAt = perf.checkedAt
    }
}

// MARK: - Project Backup

struct ProjectBackup: Codable {
    let name: String
    let channelDescription: String
    let targetAudience: String
    let contentPriorities: String
    let toneDescription: String
    let avoidTopics: String
    let refinedPrompt: String
    let aiProvider: String
    let telegramBotToken: String
    let telegramChannelId: String
    let crawlIntervalMinutes: Int
    let maxPostsPerDay: Int
    let breakingThreshold: Double
    let decayFactor: Double
    let maxQueueAgeHours: Int
    let postLanguage: String
    let publishIntervalMinutes: Int?
    let minPublishScore: Double?
    let minRelevanceScore: Double?
    let minYoutubeScore: Double?
    let dedupThreshold: Double?
    let dedupYoutubeThreshold: Double?
    let requireMedia: Bool?
    let useSymbolFormat: Bool?
    let telegramShowChannelTag: Bool?
    let telegramPublishIntervalMinutes: Int?
    let telegramMaxPostsPerDay: Int?
    let telegramShowScores: Bool?
    let telegramSymbolFormat: Bool?  // legacy
    let telegramSymbol: String?
    let telegramShowSourceLink: Bool?
    let postLength: String?
    let telegramPostLength: String?
    let twitterPostLength: String?
    let breakingTelegram: Bool?
    let breakingTwitter: Bool?
    // Twitter
    let twitterApiKey: String?
    let twitterApiSecret: String?
    let twitterAccessToken: String?
    let twitterAccessTokenSecret: String?
    let twitterEnabled: Bool?
    let twitterPublishIntervalMinutes: Int?
    let twitterMaxPostsPerDay: Int?
    let twitterShowScores: Bool?
    let twitterShowSourceLink: Bool?
    let twitterShowHandle: Bool?
    let twitterHandle: String?
    let twitterSymbolFormat: Bool?  // legacy
    let twitterSymbol: String?
    let twitterSourceAsReply: Bool?
    let twitterRequireImage: Bool?
    let twitterMaxAgeHours: Double?
    // LinkedIn
    let linkedinAccessToken: String?
    let linkedinPersonId: String?
    let linkedinEnabled: Bool?
    let linkedinPublishIntervalMinutes: Int?
    let linkedinMaxPostsPerDay: Int?
    let linkedinShowScores: Bool?
    let linkedinShowSourceLink: Bool?
    let linkedinShowHandle: Bool?
    let linkedinHandle: String?
    let linkedinSymbol: String?
    let linkedinSourceAsComment: Bool?
    let linkedinRequireImage: Bool?
    let linkedinMaxAgeHours: Double?
    let linkedinPostLength: String?
    let breakingLinkedin: Bool?
    let sources: [SourceBackup]
    let articles: [ArticleBackup]?
    let posts: [PostBackup]?
    let performance: [PerformanceBackup]?
    // Legacy
    let sourceURLs: [String]?

    init(from project: Project) {
        self.name = project.name
        self.channelDescription = project.channelDescription
        self.targetAudience = project.targetAudience
        self.contentPriorities = project.contentPriorities
        self.toneDescription = project.toneDescription
        self.avoidTopics = project.avoidTopics
        self.refinedPrompt = project.refinedPrompt
        self.aiProvider = project.aiProvider
        self.telegramBotToken = project.telegramBotToken
        self.telegramChannelId = project.telegramChannelId
        self.crawlIntervalMinutes = project.crawlIntervalMinutes
        self.maxPostsPerDay = project.maxPostsPerDay
        self.breakingThreshold = project.breakingThreshold
        self.decayFactor = project.decayFactor
        self.maxQueueAgeHours = project.maxQueueAgeHours
        self.postLanguage = project.postLanguage
        self.publishIntervalMinutes = project.publishIntervalMinutes
        self.minPublishScore = project.minPublishScore
        self.minRelevanceScore = project.minRelevanceScore
        self.minYoutubeScore = project.minYoutubeScore
        self.dedupThreshold = project.dedupThreshold
        self.dedupYoutubeThreshold = project.dedupYoutubeThreshold
        self.requireMedia = project.requireMedia
        self.useSymbolFormat = project.useSymbolFormat
        self.telegramShowChannelTag = project.telegramShowChannelTag
        self.telegramPublishIntervalMinutes = project.telegramPublishIntervalMinutes
        self.telegramMaxPostsPerDay = project.telegramMaxPostsPerDay
        self.telegramShowScores = project.telegramShowScores
        self.telegramSymbolFormat = nil  // legacy
        self.telegramSymbol = project.telegramSymbol == "⭕️" ? nil : project.telegramSymbol
        self.telegramShowSourceLink = project.telegramShowSourceLink ? nil : false
        self.postLength = project.postLength
        self.telegramPostLength = project.telegramPostLength
        self.twitterPostLength = project.twitterPostLength
        self.breakingTelegram = project.breakingTelegram ? nil : false
        self.breakingTwitter = project.breakingTwitter ? nil : false
        self.twitterApiKey = project.twitterApiKey.isEmpty ? nil : project.twitterApiKey
        self.twitterApiSecret = project.twitterApiSecret.isEmpty ? nil : project.twitterApiSecret
        self.twitterAccessToken = project.twitterAccessToken.isEmpty ? nil : project.twitterAccessToken
        self.twitterAccessTokenSecret = project.twitterAccessTokenSecret.isEmpty ? nil : project.twitterAccessTokenSecret
        self.twitterEnabled = project.twitterEnabled ? true : nil
        self.twitterPublishIntervalMinutes = project.twitterPublishIntervalMinutes != 15 ? project.twitterPublishIntervalMinutes : nil
        self.twitterMaxPostsPerDay = project.twitterMaxPostsPerDay != 48 ? project.twitterMaxPostsPerDay : nil
        self.twitterShowScores = project.twitterShowScores ? true : nil
        self.twitterShowSourceLink = project.twitterShowSourceLink ? nil : false
        self.twitterShowHandle = project.twitterShowHandle ? nil : false
        self.twitterHandle = project.twitterHandle.isEmpty ? nil : project.twitterHandle
        self.twitterSymbolFormat = nil  // legacy
        self.twitterSymbol = project.twitterSymbol == "none" ? nil : project.twitterSymbol
        self.twitterSourceAsReply = project.twitterSourceAsReply ? true : nil
        self.twitterRequireImage = project.twitterRequireImage ? nil : false
        self.twitterMaxAgeHours = project.twitterMaxAgeHours != 24 ? project.twitterMaxAgeHours : nil
        self.linkedinAccessToken = project.linkedinAccessToken.isEmpty ? nil : project.linkedinAccessToken
        self.linkedinPersonId = project.linkedinPersonId.isEmpty ? nil : project.linkedinPersonId
        self.linkedinEnabled = project.linkedinEnabled ? true : nil
        self.linkedinPublishIntervalMinutes = project.linkedinPublishIntervalMinutes != 15 ? project.linkedinPublishIntervalMinutes : nil
        self.linkedinMaxPostsPerDay = project.linkedinMaxPostsPerDay != 10 ? project.linkedinMaxPostsPerDay : nil
        self.linkedinShowScores = project.linkedinShowScores ? true : nil
        self.linkedinShowSourceLink = project.linkedinShowSourceLink ? nil : false
        self.linkedinShowHandle = project.linkedinShowHandle ? true : nil
        self.linkedinHandle = project.linkedinHandle.isEmpty ? nil : project.linkedinHandle
        self.linkedinSymbol = project.linkedinSymbol == "none" ? nil : project.linkedinSymbol
        self.linkedinSourceAsComment = project.linkedinSourceAsComment ? true : nil
        self.linkedinRequireImage = project.linkedinRequireImage ? nil : false
        self.linkedinMaxAgeHours = project.linkedinMaxAgeHours != 48 ? project.linkedinMaxAgeHours : nil
        self.linkedinPostLength = project.linkedinPostLength == "short" ? nil : project.linkedinPostLength
        self.breakingLinkedin = project.breakingLinkedin ? true : nil
        self.sources = project.sources.sorted(by: { $0.createdAt < $1.createdAt }).map { SourceBackup(from: $0) }
        self.sourceURLs = nil

        // Collect articles from all sources
        let allArticles = project.sources.flatMap(\.articles)
        self.articles = allArticles.isEmpty ? nil : allArticles
            .sorted(by: { $0.fetchedAt > $1.fetchedAt })
            .map { ArticleBackup(from: $0) }

        // Collect posts
        self.posts = project.posts.isEmpty ? nil : project.posts
            .sorted(by: { $0.createdAt > $1.createdAt })
            .map { PostBackup(from: $0) }

        // Collect performance
        let allPerf = project.posts.flatMap(\.performance)
        self.performance = allPerf.isEmpty ? nil : allPerf
            .sorted(by: { $0.checkedAt > $1.checkedAt })
            .map { PerformanceBackup(from: $0) }
    }

    func toProject() -> (Project, [Source]) {
        let project = Project(
            name: name,
            channelDescription: channelDescription,
            targetAudience: targetAudience,
            contentPriorities: contentPriorities,
            toneDescription: toneDescription,
            avoidTopics: avoidTopics,
            refinedPrompt: refinedPrompt,
            aiProvider: aiProvider,
            telegramBotToken: telegramBotToken,
            telegramChannelId: telegramChannelId,
            crawlIntervalMinutes: crawlIntervalMinutes,
            publishIntervalMinutes: publishIntervalMinutes ?? 5,
            maxPostsPerDay: maxPostsPerDay,
            breakingThreshold: breakingThreshold,
            decayFactor: decayFactor,
            maxQueueAgeHours: maxQueueAgeHours,
            minPublishScore: minPublishScore ?? 5.0,
            minRelevanceScore: minRelevanceScore ?? 5.0,
            minYoutubeScore: minYoutubeScore ?? 5.0,
            dedupThreshold: dedupThreshold ?? 0.8,
            dedupYoutubeThreshold: dedupYoutubeThreshold ?? 0.95,
            requireMedia: requireMedia ?? true,
            useSymbolFormat: useSymbolFormat ?? true,
            postLanguage: postLanguage
        )
        project.telegramShowChannelTag = telegramShowChannelTag ?? true
        project.telegramPublishIntervalMinutes = telegramPublishIntervalMinutes ?? 5
        project.telegramMaxPostsPerDay = telegramMaxPostsPerDay ?? 50
        project.telegramShowScores = telegramShowScores ?? true
        // Migrate legacy bool → new symbol string
        if let sym = telegramSymbol {
            project.telegramSymbol = sym
        } else if let legacy = telegramSymbolFormat ?? useSymbolFormat {
            project.telegramSymbol = legacy ? "⭕️" : "none"
        }
        project.telegramShowSourceLink = telegramShowSourceLink ?? true
        project.postLength = postLength ?? "short"
        project.telegramPostLength = telegramPostLength ?? "long"
        project.twitterPostLength = twitterPostLength ?? "short"
        project.breakingTelegram = breakingTelegram ?? true
        project.breakingTwitter = breakingTwitter ?? true
        project.twitterApiKey = twitterApiKey ?? ""
        project.twitterApiSecret = twitterApiSecret ?? ""
        project.twitterAccessToken = twitterAccessToken ?? ""
        project.twitterAccessTokenSecret = twitterAccessTokenSecret ?? ""
        project.twitterEnabled = twitterEnabled ?? false
        project.twitterPublishIntervalMinutes = twitterPublishIntervalMinutes ?? 15
        project.twitterMaxPostsPerDay = twitterMaxPostsPerDay ?? 48
        project.twitterShowScores = twitterShowScores ?? false
        project.twitterShowSourceLink = twitterShowSourceLink ?? true
        project.twitterShowHandle = twitterShowHandle ?? true
        project.twitterHandle = twitterHandle ?? ""
        if let sym = twitterSymbol {
            project.twitterSymbol = sym
        } else if let legacy = twitterSymbolFormat {
            project.twitterSymbol = legacy ? "⭕️" : "none"
        }
        project.twitterSourceAsReply = twitterSourceAsReply ?? false
        project.twitterRequireImage = twitterRequireImage ?? true
        project.twitterMaxAgeHours = twitterMaxAgeHours ?? 24
        project.linkedinAccessToken = linkedinAccessToken ?? ""
        project.linkedinPersonId = linkedinPersonId ?? ""
        project.linkedinEnabled = linkedinEnabled ?? false
        project.linkedinPublishIntervalMinutes = linkedinPublishIntervalMinutes ?? 15
        project.linkedinMaxPostsPerDay = linkedinMaxPostsPerDay ?? 10
        project.linkedinShowScores = linkedinShowScores ?? false
        project.linkedinShowSourceLink = linkedinShowSourceLink ?? true
        project.linkedinShowHandle = linkedinShowHandle ?? false
        project.linkedinHandle = linkedinHandle ?? ""
        if let sym = linkedinSymbol {
            project.linkedinSymbol = sym
        }
        project.linkedinSourceAsComment = linkedinSourceAsComment ?? false
        project.linkedinRequireImage = linkedinRequireImage ?? true
        project.linkedinMaxAgeHours = linkedinMaxAgeHours ?? 48
        project.linkedinPostLength = linkedinPostLength ?? "short"
        project.breakingLinkedin = breakingLinkedin ?? false
        let sourcesResult: [Source]
        if !sources.isEmpty {
            sourcesResult = sources.map { backup in
                let source = backup.toSource()
                source.project = project
                return source
            }
        } else if let urls = sourceURLs {
            sourcesResult = urls.map { url in
                let source = Source(url: url)
                source.project = project
                return source
            }
        } else {
            sourcesResult = []
        }
        return (project, sourcesResult)
    }
}

// MARK: - Full Backup (all projects + API keys)

struct FullBackup: Codable {
    let version: Int
    let exportedAt: Date
    let apiKeys: APIKeysBackup?
    let projects: [ProjectBackup]

    struct APIKeysBackup: Codable {
        let openai: String?
        let grok: String?
        let claude: String?
    }
}

// MARK: - Exporter

final class ProjectExporter {

    static func exportJSON(project: Project) throws -> Data {
        let backup = ProjectBackup(from: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func importJSON(data: Data) throws -> (Project, [Source]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(ProjectBackup.self, from: data)
        return backup.toProject()
    }

    // MARK: - Full Export/Import

    static func exportAll(projects: [Project]) throws -> Data {
        let apiKeys = FullBackup.APIKeysBackup(
            openai: KeychainService.shared.get(key: "openai_api_key"),
            grok: KeychainService.shared.get(key: "grok_api_key"),
            claude: KeychainService.shared.get(key: "claude_api_key")
        )
        let backup = FullBackup(
            version: 1,
            exportedAt: Date(),
            apiKeys: apiKeys,
            projects: projects.map { ProjectBackup(from: $0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func importAll(data: Data) throws -> (apiKeys: FullBackup.APIKeysBackup?, projects: [(Project, [Source])]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(FullBackup.self, from: data)
        let projects = backup.projects.map { $0.toProject() }
        return (apiKeys: backup.apiKeys, projects: projects)
    }
}
