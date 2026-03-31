import Foundation
import SwiftData

final class FeedbackCollector {
    static let shared = FeedbackCollector()

    private init() {}

    func collectPerformance(for project: Project, context: ModelContext) async {
        let recentPosts = project.posts.filter { post in
            post.status == .published &&
            post.telegramMessageId != nil &&
            post.publishedAt != nil &&
            Date().timeIntervalSince(post.publishedAt!) < 48 * 3600 // Last 48h
        }

        for post in recentPosts {
            guard let messageId = post.telegramMessageId else { continue }

            let views = await TelegramService.shared.getMessageViews(
                botToken: project.telegramBotToken,
                channelId: project.telegramChannelId,
                messageId: messageId
            )

            if let views = views {
                let perf = PostPerformance(
                    views: views,
                    predictedScore: post.article?.rawScore ?? 0
                )
                perf.post = post
                context.insert(perf)
            }
        }

        try? context.save()
    }
}
