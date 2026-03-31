import Foundation
import SwiftData

/// Source types: normal (scored normally), priority (boosted for breaking), unfiltered (bypass scoring, always publish)
let sourceTypes = ["normal", "priority", "unfiltered"]

@Model
final class Source {
    var id: UUID
    var url: String
    var name: String
    var sourceType: String       // "normal", "priority", "unfiltered"
    var youtubeChannelId: String // YouTube channel ID (empty = not a YT source)
    var youtubeFilter: String    // User description: "trailers, gameplay, demos" → AI refines
    var refinedYoutubeFilter: String // AI-refined filter keywords
    var youtubeDescription: String   // What user wants from this channel (e.g. "AAA game trailers")
    var refinedYoutubeDescription: String // AI-refined version for scoring
    var createdAt: Date

    var project: Project?

    @Relationship(deleteRule: .cascade, inverse: \FetchedArticle.source)
    var articles: [FetchedArticle]

    init(url: String, name: String = "", sourceType: String = "normal") {
        self.id = UUID()
        self.url = url
        self.name = name.isEmpty ? Self.extractDomain(from: url) : name
        self.sourceType = sourceType
        self.youtubeChannelId = ""
        self.youtubeFilter = ""
        self.refinedYoutubeFilter = ""
        self.youtubeDescription = ""
        self.refinedYoutubeDescription = ""
        self.createdAt = Date()
        self.articles = []
    }

    var isPriority: Bool { sourceType == "priority" }
    var isUnfiltered: Bool { sourceType == "unfiltered" }
    var isYouTube: Bool { !youtubeChannelId.isEmpty }

    static func extractDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else {
            return urlString
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}
