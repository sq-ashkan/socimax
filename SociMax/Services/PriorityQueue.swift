import Foundation

final class PriorityQueue {
    static let shared = PriorityQueue()

    private init() {}

    func topArticle(
        from articles: [FetchedArticle],
        decayFactor: Double
    ) -> FetchedArticle? {
        let unused = articles.filter { !$0.isUsed && $0.viralityScore > 0 }
        return unused.max { a, b in
            a.effectiveScore(decayFactor: decayFactor) < b.effectiveScore(decayFactor: decayFactor)
        }
    }

    func breakingArticles(
        from articles: [FetchedArticle],
        threshold: Double
    ) -> [FetchedArticle] {
        articles.filter { $0.isBreaking && $0.rawScore >= threshold && !$0.isUsed }
    }

    func cleanExpired(
        articles: [FetchedArticle],
        maxAgeHours: Int
    ) -> [FetchedArticle] {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeHours) * 3600)
        return articles.filter { $0.fetchedAt >= cutoff && !$0.isUsed }
    }

    func sortedByEffectiveScore(
        articles: [FetchedArticle],
        decayFactor: Double
    ) -> [FetchedArticle] {
        articles
            .filter { !$0.isUsed && $0.viralityScore > 0 }
            .sorted { a, b in
                a.effectiveScore(decayFactor: decayFactor) > b.effectiveScore(decayFactor: decayFactor)
            }
    }
}
