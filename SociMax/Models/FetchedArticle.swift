import Foundation
import SwiftData

@Model
final class FetchedArticle {
    var id: UUID
    var title: String
    var content: String
    var sourceURL: String
    var mediaURL: String?
    var isUsed: Bool
    var viralityScore: Double
    var relevanceScore: Double
    var isBreaking: Bool
    var fetchedAt: Date

    var source: Source?

    @Relationship(deleteRule: .nullify, inverse: \GeneratedPost.article)
    var generatedPost: GeneratedPost?

    init(
        title: String,
        content: String,
        sourceURL: String,
        mediaURL: String? = nil,
        viralityScore: Double = 0,
        relevanceScore: Double = 0,
        isBreaking: Bool = false
    ) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.sourceURL = sourceURL
        self.mediaURL = mediaURL
        self.isUsed = false
        self.viralityScore = viralityScore
        self.relevanceScore = relevanceScore
        self.isBreaking = isBreaking
        self.fetchedAt = Date()
    }

    var hasMedia: Bool {
        guard let url = mediaURL else { return false }
        return !url.isEmpty
    }

    var rawScore: Double {
        viralityScore * 0.6 + relevanceScore * 0.4
    }

    func effectiveScore(decayFactor: Double) -> Double {
        let hoursOld = Date().timeIntervalSince(fetchedAt) / 3600.0
        let freshness = exp(-decayFactor * hoursOld)
        return rawScore * freshness
    }
}
