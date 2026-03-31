import Foundation
import SwiftData

enum PostStatus: String, Codable {
    case queued
    case published
    case failed
    case expired
}

@Model
final class GeneratedPost {
    var id: UUID
    var content: String
    var statusRaw: String
    var telegramMessageId: Int?
    var twitterTweetId: String = ""
    var linkedinPostId: String = ""
    var telegramText: String = ""
    var publishedAt: Date?
    var createdAt: Date

    var project: Project?
    var article: FetchedArticle?

    @Relationship(deleteRule: .cascade, inverse: \PostPerformance.post)
    var performance: [PostPerformance]

    var status: PostStatus {
        get { PostStatus(rawValue: statusRaw) ?? .queued }
        set { statusRaw = newValue.rawValue }
    }

    init(content: String, status: PostStatus = .queued) {
        self.id = UUID()
        self.content = content
        self.statusRaw = status.rawValue
        self.createdAt = Date()
        self.performance = []
    }
}
