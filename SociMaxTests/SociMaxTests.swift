import XCTest
@testable import SociMax

final class PriorityQueueTests: XCTestCase {

    func testEffectiveScoreDecay() {
        let article = FetchedArticle(
            title: "Test",
            content: "Test content",
            sourceURL: "https://example.com",
            viralityScore: 9.0,
            relevanceScore: 8.0
        )

        // Raw score: 9*0.6 + 8*0.4 = 5.4 + 3.2 = 8.6
        let rawScore = article.rawScore
        XCTAssertEqual(rawScore, 8.6, accuracy: 0.01)

        // At time 0, effective should equal raw
        let effective = article.effectiveScore(decayFactor: 0.1)
        XCTAssertEqual(effective, rawScore, accuracy: 0.1) // Small tolerance for time
    }

    func testBreakingDetection() {
        let breaking = FetchedArticle(
            title: "Breaking",
            content: "Content",
            sourceURL: "https://example.com",
            viralityScore: 10.0,
            relevanceScore: 9.0,
            isBreaking: true
        )

        let normal = FetchedArticle(
            title: "Normal",
            content: "Content",
            sourceURL: "https://example.com",
            viralityScore: 6.0,
            relevanceScore: 7.0,
            isBreaking: false
        )

        let articles = [breaking, normal]
        let breakingResult = PriorityQueue.shared.breakingArticles(from: articles, threshold: 9.0)
        XCTAssertEqual(breakingResult.count, 1)
        XCTAssertEqual(breakingResult.first?.title, "Breaking")
    }
}
