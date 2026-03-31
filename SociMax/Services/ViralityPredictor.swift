import Foundation
import SwiftData
import AppKit

@MainActor
final class ViralityPredictor {
    static let shared = ViralityPredictor()

    /// Cache: project ID -> keyword sets of published article titles
    private var publishedKeywordsCache: [UUID: [Set<String>]] = [:]
    private var cacheTimestamps: [UUID: Date] = [:]
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    /// Minimum image dimensions to be considered publishable
    private let minImageWidth: CGFloat = 540
    private let minImageHeight: CGFloat = 360

    /// Ephemeral session for image validation — no caching
    private nonisolated static let imageSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Image Quality Check

    /// Downloads image and checks if it meets minimum quality (dimensions).
    /// Returns nil if the image is too small or cannot be loaded.
    nonisolated static func validatedImageURL(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await imageSession.data(from: url)
            // Check Content-Type is actually an image
            if let httpResponse = response as? HTTPURLResponse,
               let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
               !contentType.hasPrefix("image/") {
                FileLogger.shared.log("Image quality check: not an image (\(contentType))")
                return nil
            }
            // Check file size — skip tiny files (likely broken or placeholder)
            if data.count < 20_000 {
                FileLogger.shared.log("Image quality check: too small (\(data.count) bytes)")
                return nil
            }
            // Check pixel dimensions inside autoreleasepool to free NSImage immediately
            let dims: (Int, Int)? = autoreleasepool {
                guard let image = NSImage(data: data),
                      let rep = image.representations.first else { return nil }
                return (rep.pixelsWide, rep.pixelsHigh)
            }
            guard let (w, h) = dims else {
                FileLogger.shared.log("Image quality check: cannot decode image")
                return nil
            }
            if w < 600 || h < 400 {
                FileLogger.shared.log("Image quality check: too small (\(w)x\(h))")
                return nil
            }
            FileLogger.shared.log("Image quality OK: \(w)x\(h), \(data.count / 1024)KB")
            return urlString
        } catch {
            FileLogger.shared.log("Image quality check failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Dedup with cached keywords

    /// Build or return cached published article keywords using FetchDescriptor
    private func publishedKeywords(for project: Project, context: ModelContext) -> [Set<String>] {
        let projectId = project.id
        if let cached = publishedKeywordsCache[projectId],
           let ts = cacheTimestamps[projectId],
           Date().timeIntervalSince(ts) < cacheTTL {
            return cached
        }

        // Only use ACTUALLY PUBLISHED articles for dedup (those with a generated post),
        // not articles merely marked isUsed by previous dedup cycles — avoids cascade effect
        // Limit to last 14 days to avoid loading entire DB into memory
        let dedupCutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        let descriptor = FetchDescriptor<FetchedArticle>(
            predicate: #Predicate<FetchedArticle> { article in
                article.isUsed == true && article.fetchedAt >= dedupCutoff
            }
        )
        let allUsed = (try? context.fetch(descriptor)) ?? []
        let projectArticles = allUsed.filter {
            $0.source?.project?.id == projectId && $0.generatedPost != nil
        }

        // Only keep last 500 articles for dedup — prevents unbounded memory growth
        let recentArticles = projectArticles.count > 500 ? Array(projectArticles.suffix(500)) : projectArticles
        let keywords = recentArticles.map { Self.titleKeywords($0.title) }
        publishedKeywordsCache[projectId] = keywords
        cacheTimestamps[projectId] = Date()
        return keywords
    }

    /// Invalidate cache after publishing
    private func invalidateCache(for projectId: UUID) {
        publishedKeywordsCache.removeValue(forKey: projectId)
        cacheTimestamps.removeValue(forKey: projectId)
    }

    /// Check if a similar article was already published (fuzzy title match)
    /// YouTube uses a separate (higher) threshold since trailers share common words
    private func isDuplicate(
        _ article: FetchedArticle,
        in project: Project,
        publishedKeywords keywords: [Set<String>]
    ) -> Bool {
        let candidateWords = Self.titleKeywords(article.title)
        guard candidateWords.count >= 3 else { return false }

        let isYT = VideoDownloader.isYouTubeVideo(article.sourceURL)
        let threshold: Double
        if isYT {
            threshold = project.dedupYoutubeThreshold > 0 ? project.dedupYoutubeThreshold : 0.95
        } else {
            threshold = project.dedupThreshold > 0 ? project.dedupThreshold : 0.8
        }

        for publishedWords in keywords {
            let common = candidateWords.intersection(publishedWords)
            let denominator = min(candidateWords.count, publishedWords.count)
            guard denominator > 0 else { continue }
            let similarity = Double(common.count) / Double(denominator)
            if similarity >= threshold {
                FileLogger.shared.log("Dedup: '\(article.title)' matched (\(Int(similarity * 100))%)")
                return true
            }
        }
        return false
    }

    /// Extract meaningful keywords from a title (lowercase, no stopwords)
    private static func titleKeywords(_ title: String) -> Set<String> {
        let stopwords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "in", "on", "at", "to", "for",
            "of", "and", "or", "but", "with", "has", "have", "had", "its", "it", "this",
            "that", "from", "by", "as", "be", "been", "will", "would", "could", "should",
            "not", "no", "new", "just", "more", "most", "after", "into", "up", "out",
            "der", "die", "das", "und", "ist", "ein", "eine", "für", "mit", "von", "den",
            "el", "la", "los", "las", "un", "una", "de", "del", "en", "con", "por", "que",
        ]
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopwords.contains($0) }
        return Set(words)
    }

    // MARK: - canPublish helper using FetchDescriptor

    /// Check if project can publish more today (uses FetchDescriptor instead of relationship traversal)
    private func canPublish(project: Project, context: ModelContext) -> Bool {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let publishedStatus = PostStatus.published.rawValue
        var descriptor = FetchDescriptor<GeneratedPost>(
            predicate: #Predicate<GeneratedPost> { post in
                post.statusRaw == publishedStatus &&
                post.publishedAt != nil &&
                post.publishedAt! >= startOfDay
            }
        )
        descriptor.propertiesToFetch = [\.statusRaw] // Only need count, minimize memory
        let allToday = (try? context.fetch(descriptor)) ?? []
        let count = allToday.filter { $0.project?.id == project.id }.count
        return count < project.telegramMaxPostsPerDay
    }

    // MARK: - Score new articles

    func processNewArticles(
        _ articles: [FetchedArticle],
        for project: Project,
        context: ModelContext
    ) async -> (breaking: [FetchedArticle], queued: [FetchedArticle]) {
        // Filter articles: require media unless project allows text-only
        // YouTube videos ARE media — never filter them out
        let scorable = project.requireMedia
            ? articles.filter { $0.hasMedia || VideoDownloader.isYouTubeVideo($0.sourceURL) }
            : articles
        FileLogger.shared.log("Scoring \(scorable.count) articles with Grok")

        // Extract ALL plain data from SwiftData models on MainActor
        let plainData = scorable.map { article in
            let refined = article.source?.refinedYoutubeDescription ?? ""
            let sourceHint = refined.isEmpty ? (article.source?.youtubeDescription ?? "") : refined
            return (id: article.id.uuidString, title: article.title, content: article.content, sourceHint: sourceHint)
        }
        let channelPrompt = project.effectivePrompt

        // Scoring ALWAYS uses Grok — read key on MainActor
        let grokKey = GrokService.shared.apiKey

        // Copy to dictionary arrays for Sendable transfer to detached task
        let articlesCopy: [[String: String]] = plainData.map {
            var dict = ["id": $0.id, "title": $0.title, "content": $0.content]
            if !$0.sourceHint.isEmpty { dict["sourceHint"] = $0.sourceHint }
            return dict
        }
        let prompt = channelPrompt
        let key = grokKey

        // Score on detached task (avoids MainActor deadlock + Keychain blocking)
        let scores: [String: ArticleScore] = await Task.detached {
            var results: [String: ArticleScore] = [:]
            let batchSize = 15
            let totalBatches = (articlesCopy.count + batchSize - 1) / batchSize
            FileLogger.shared.log("Scoring \(totalBatches) batches (grok)")

            for batchStart in stride(from: 0, to: articlesCopy.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, articlesCopy.count)
                let batchDicts = Array(articlesCopy[batchStart..<batchEnd])
                let batch = batchDicts.map {
                    (id: $0["id"]!, title: $0["title"]!, content: $0["content"]!, sourceHint: $0["sourceHint"] ?? "")
                }
                let batchNum = batchStart / batchSize + 1

                do {
                    let batchScores = try await GrokService.shared.scoreArticles(
                        articles: batch, channelPrompt: prompt, withKey: key
                    )
                    FileLogger.shared.log("Scored batch \(batchNum)/\(totalBatches): \(batchScores.count) results")
                    for score in batchScores {
                        results[score.articleId] = score
                    }
                } catch {
                    FileLogger.shared.log("Failed batch \(batchNum)/\(totalBatches): \(error)")
                }
            }
            FileLogger.shared.log("Scoring complete: \(results.count) total")
            return results
        }.value

        // Apply scores back to SwiftData models
        for article in scorable {
            if let score = scores[article.id.uuidString] {
                article.viralityScore = score.viralityScore
                article.relevanceScore = score.relevanceScore
                article.isBreaking = score.isBreaking
                let isYT = VideoDownloader.isYouTubeVideo(article.sourceURL)
                FileLogger.shared.log("Scored \(isYT ? "YT" : "web"): '\(String(article.title.prefix(40)))' v:\(score.viralityScore) r:\(score.relevanceScore)")
            } else {
                FileLogger.shared.log("NO SCORE for: '\(String(article.title.prefix(40)))' id:\(article.id.uuidString)")
            }
            // Priority sources: boost score by +1 and lower breaking threshold
            if let source = article.source, source.isPriority {
                article.viralityScore = min(10, article.viralityScore + 1)
                if article.viralityScore >= project.breakingThreshold - 1 {
                    article.isBreaking = true
                }
            }
            // Unfiltered sources: always mark as breaking for immediate publish
            if let source = article.source, source.isUnfiltered {
                article.isBreaking = true
                article.viralityScore = max(article.viralityScore, 9)
            }
        }

        let breaking = PriorityQueue.shared.breakingArticles(
            from: articles,
            threshold: project.breakingThreshold
        )
        let queued = articles.filter { !$0.isBreaking && !$0.isUsed }

        return (breaking: breaking, queued: queued)
    }

    // MARK: - Publish breaking news

    func generateAndPublishBreaking(
        _ article: FetchedArticle,
        for project: Project,
        context: ModelContext
    ) async {
        guard canPublish(project: project, context: context) else { return }
        guard project.breakingTelegram || project.breakingTwitter || project.breakingLinkedin else {
            FileLogger.shared.log("Breaking disabled for \(project.name) — queueing '\(article.title)' instead")
            return
        }
        if project.requireMedia && !article.hasMedia && !VideoDownloader.isYouTubeVideo(article.sourceURL) {
            FileLogger.shared.log("Skipping breaking '\(article.title)' — no media")
            return
        }
        // Skip if article already has a linked post (previous cycle)
        if article.generatedPost != nil {
            FileLogger.shared.log("Skipping '\(article.title)' — already has a post")
            article.isUsed = true
            return
        }
        // Dedup check: skip if similar article already published
        let keywords = publishedKeywords(for: project, context: context)
        if isDuplicate(article, in: project, publishedKeywords: keywords) {
            article.isUsed = true
            return
        }

        // Extract plain data + API key on MainActor BEFORE any await
        let channelPrompt = project.effectivePrompt
        let language = project.postLanguage
        let tgSymbol = project.telegramSymbol
        let tgShowSourceLink = project.telegramShowSourceLink
        let showChannelTag = project.telegramShowChannelTag
        let channelTag = project.telegramChannelId
        let showScores = project.telegramShowScores
        let botToken = project.telegramBotToken
        let channelId = project.telegramChannelId
        let articleData = (title: article.title, content: article.content, sourceURL: article.sourceURL)
        let articleViralityScore = article.viralityScore
        let articleRelevanceScore = article.relevanceScore
        let lengthCfg = project.lengthConfig
        let tgPostLength = project.telegramPostLength
        let twPostLength = project.twitterPostLength
        // Breaking platform flags
        let breakTelegram = project.breakingTelegram
        let breakTwitter = project.breakingTwitter
        // Twitter config
        let twEnabled = project.twitterEnabled
        let twApiKey = project.twitterApiKey
        let twApiSecret = project.twitterApiSecret
        let twAccessToken = project.twitterAccessToken
        let twAccessTokenSecret = project.twitterAccessTokenSecret
        let twShowSourceLink = project.twitterShowSourceLink
        let twShowScores = project.twitterShowScores
        let twShowHandle = project.twitterShowHandle
        let twHandle = project.twitterHandle
        let twCanPublish = project.canPublishTwitter
        let twSymbol = project.twitterSymbol
        let twSourceAsReply = project.twitterSourceAsReply
        let twRequireImage = project.twitterRequireImage
        // LinkedIn config
        let breakLinkedin = project.breakingLinkedin
        let lnEnabled = project.linkedinEnabled
        let lnAccessToken = project.linkedinAccessToken
        let lnPersonId = project.linkedinPersonId
        let lnShowSourceLink = project.linkedinShowSourceLink
        let lnShowScores = project.linkedinShowScores
        let lnShowHandle = project.linkedinShowHandle
        let lnHandle = project.linkedinHandle
        let lnCanPublish = project.canPublishLinkedin
        let lnSymbol = project.linkedinSymbol
        let lnSourceAsComment = project.linkedinSourceAsComment
        let lnRequireImage = project.linkedinRequireImage
        let lnPostLength = project.linkedinPostLength
        let openAIKey = OpenAIService.shared.apiKey

        do {
            // Generate post with OpenAI (always gpt-4.1-mini)
            let postContent = try await Task.detached {
                return try await OpenAIService.shared.generatePost(
                    article: articleData, channelPrompt: channelPrompt, language: language, withKey: openAIKey, lengthConfig: lengthCfg
                )
            }.value

            // Quality gate: reject posts where total text content is too short
            let breakingTextOnly = postContent.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .filter { !$0.contains("🔻") && !$0.contains("Source") }
                .joined(separator: " ")
            let breakingAlphanumeric = breakingTextOnly.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            let breakingCleanLength = breakingAlphanumeric.count
            if breakingCleanLength < 20 {
                FileLogger.shared.log("REJECTED breaking '\(article.title)' — post too short (\(breakingCleanLength) alphanumeric chars)")
                article.isUsed = true
                try? context.save()
                return
            }

            // Extract sections per platform, then format for Telegram
            let tgSections = PostLengthConfig.extractSections(postContent, for: tgPostLength)
            var telegramContent = PostLengthConfig.formatForTelegram(
                sections: tgSections,
                sourceURL: articleData.sourceURL,
                language: language,
                symbol: tgSymbol,
                showSourceLink: tgShowSourceLink
            )
            // Append Telegram-specific tags (NOT stored in post record)
            if showChannelTag {
                telegramContent += "\n\n\(channelTag)"
            }
            if showScores {
                telegramContent += "\n\n\u{1f4ca} V:\(String(format: "%.1f", articleViralityScore)) R:\(String(format: "%.1f", articleRelevanceScore))"
            }

            // Download media once (shared between platforms)
            let isYouTube = VideoDownloader.isYouTubeVideo(article.sourceURL)
            let breakingMediaURL = article.mediaURL
            var downloadedVideo: URL? = nil
            var messageId: Int? = nil

            if isYouTube && VideoDownloader.shared.isAvailable {
                FileLogger.shared.log("Downloading YouTube video: \(article.sourceURL)")
                if let result = await VideoDownloader.shared.downloadVideo(url: article.sourceURL) {
                    downloadedVideo = result.video

                    if breakTelegram {
                        FileLogger.shared.log("Uploading video to Telegram: \(result.video.lastPathComponent)")
                        messageId = try await TelegramService.shared.sendVideo(
                            botToken: botToken, channelId: channelId,
                            videoFile: result.video, caption: telegramContent, thumbnail: result.thumbnail
                        )
                    }
                } else if breakTelegram {
                    let text = telegramContent + "\n\n\(article.sourceURL)"
                    FileLogger.shared.log("Video download failed, sending URL instead")
                    messageId = try await TelegramService.shared.sendMessage(
                        botToken: botToken, channelId: channelId, text: text
                    )
                }
            } else if isYouTube && breakTelegram {
                let text = telegramContent + "\n\n\(article.sourceURL)"
                FileLogger.shared.log("Sending YouTube URL (yt-dlp not installed): \(article.sourceURL)")
                messageId = try await TelegramService.shared.sendMessage(
                    botToken: botToken, channelId: channelId, text: text
                )
            } else if breakTelegram {
                if let mediaURL = breakingMediaURL, !mediaURL.isEmpty {
                    FileLogger.shared.log("Sending photo: \(mediaURL)")
                    do {
                        messageId = try await TelegramService.shared.sendPhoto(
                            botToken: botToken, channelId: channelId, photoURL: mediaURL, caption: telegramContent
                        )
                    } catch {
                        if project.requireMedia {
                            FileLogger.shared.log("Photo failed (\(error)), skipping (media required)")
                            article.isUsed = true
                            try? context.save()
                            return
                        }
                        FileLogger.shared.log("Photo failed (\(error)), falling back to text-only")
                        messageId = try await TelegramService.shared.sendMessage(
                            botToken: botToken, channelId: channelId, text: telegramContent
                        )
                    }
                } else if !project.requireMedia {
                    FileLogger.shared.log("Sending text-only: \(articleData.title)")
                    messageId = try await TelegramService.shared.sendMessage(
                        botToken: botToken, channelId: channelId, text: telegramContent
                    )
                } else {
                    FileLogger.shared.log("Skipping breaking '\(articleData.title)' — no media URL")
                    article.isUsed = true
                    try? context.save()
                    return
                }
            }

            // Create the post record — store FULL content (all sections, NO telegram tags)
            if let existingPost = article.generatedPost {
                existingPost.article = nil
            }

            let post = GeneratedPost(content: postContent, status: .published)
            post.publishedAt = Date()
            post.telegramMessageId = messageId
            post.telegramText = telegramContent
            context.insert(post)
            post.article = article
            post.project = project
            article.isUsed = true

            try context.save()
            invalidateCache(for: project.id)
            FileLogger.shared.log("Published breaking: \(article.title) [telegram:\(breakTelegram) twitter:\(breakTwitter) linkedin:\(breakLinkedin)]")

            // Twitter publish — extract sections for Twitter separately
            if breakTwitter && twEnabled && twCanPublish && !twApiKey.isEmpty {
                do {
                    let twitterContent = PostLengthConfig.extractSections(postContent, for: twPostLength)
                    let tweet = TwitterService.formatTweet(
                        postContent: twitterContent,
                        sourceURL: articleData.sourceURL,
                        showSourceLink: twShowSourceLink,
                        showScores: twShowScores,
                        viralityScore: articleViralityScore,
                        relevanceScore: articleRelevanceScore,
                        showHandle: twShowHandle,
                        handle: twHandle,
                        symbol: twSymbol
                    )
                    var twMediaId: String? = nil
                    if let videoFile = downloadedVideo {
                        twMediaId = try? await TwitterService.shared.uploadVideo(
                            fileURL: videoFile,
                            apiKey: twApiKey, apiSecret: twApiSecret,
                            accessToken: twAccessToken, accessTokenSecret: twAccessTokenSecret
                        )
                    } else if let imgURL = breakingMediaURL, !imgURL.isEmpty,
                              let validImg = await Self.validatedImageURL(imgURL) {
                        twMediaId = try? await TwitterService.shared.uploadImage(
                            fromURL: validImg,
                            apiKey: twApiKey, apiSecret: twApiSecret,
                            accessToken: twAccessToken, accessTokenSecret: twAccessTokenSecret
                        )
                    }
                    // Skip tweet if image is required but not available
                    if twRequireImage && twMediaId == nil {
                        FileLogger.shared.log("[Twitter] Skipping breaking '\(articleData.title)' — no valid media (require media enabled)")
                    } else if let tweetId = try await TwitterService.shared.postTweet(
                        text: tweet,
                        mediaId: twMediaId,
                        apiKey: twApiKey,
                        apiSecret: twApiSecret,
                        accessToken: twAccessToken,
                        accessTokenSecret: twAccessTokenSecret
                    ) {
                        post.twitterTweetId = tweetId
                        try? context.save()
                        FileLogger.shared.log("[Twitter] Breaking posted: \(tweetId)\(twMediaId != nil ? " +media" : "") for '\(articleData.title)'")

                        // Post source link as reply if enabled
                        if twSourceAsReply && !articleData.sourceURL.isEmpty {
                            let _ = try? await TwitterService.shared.postTweet(
                                text: articleData.sourceURL,
                                replyToTweetId: tweetId,
                                apiKey: twApiKey, apiSecret: twApiSecret,
                                accessToken: twAccessToken, accessTokenSecret: twAccessTokenSecret
                            )
                            FileLogger.shared.log("[Twitter] Source reply posted for breaking \(tweetId)")
                        }

                        // Edit Telegram message to add tweet link
                        if let msgId = post.telegramMessageId, !post.telegramText.isEmpty {
                            let tweetHandle = twHandle.hasPrefix("@") ? String(twHandle.dropFirst()) : twHandle
                            let tweetURL = "https://x.com/\(tweetHandle)/status/\(tweetId)"
                            let newText = post.telegramText + "\n\n🐦 \(tweetURL)"
                            let hasMedia = !(article.mediaURL ?? "").isEmpty || VideoDownloader.isYouTubeVideo(article.sourceURL)
                            let editOk: Bool
                            if hasMedia {
                                editOk = await TelegramService.shared.editMessageCaption(
                                    botToken: botToken, channelId: channelId, messageId: msgId, caption: newText
                                )
                            } else {
                                editOk = await TelegramService.shared.editMessageText(
                                    botToken: botToken, channelId: channelId, messageId: msgId, text: newText
                                )
                            }
                            if editOk {
                                post.telegramText = newText
                                try? context.save()
                            }
                        }
                    }
                } catch {
                    FileLogger.shared.log("[Twitter] Breaking failed for '\(articleData.title)': \(error)")
                    if case NetworkError.requestFailed(403) = error {
                        post.twitterTweetId = "skipped_403"
                        try? context.save()
                    }
                }
            }
            // LinkedIn publish — extract sections for LinkedIn separately
            if breakLinkedin && lnEnabled && lnCanPublish && !lnAccessToken.isEmpty {
                do {
                    let linkedinContent = PostLengthConfig.extractSections(postContent, for: lnPostLength)
                    let lnText = LinkedInService.formatLinkedInPost(
                        postContent: linkedinContent,
                        sourceURL: articleData.sourceURL,
                        showSourceLink: false,
                        showScores: lnShowScores,
                        viralityScore: articleViralityScore,
                        relevanceScore: articleRelevanceScore,
                        showHandle: lnShowHandle,
                        handle: lnHandle,
                        symbol: lnSymbol
                    )
                    var lnImageURN: String? = nil
                    if let imgURL = breakingMediaURL, !imgURL.isEmpty,
                       let validImg = await Self.validatedImageURL(imgURL) {
                        lnImageURN = try? await LinkedInService.shared.uploadImage(
                            fromURL: validImg,
                            accessToken: lnAccessToken,
                            personId: lnPersonId
                        )
                    }
                    if lnRequireImage && lnImageURN == nil {
                        FileLogger.shared.log("[LinkedIn] Skipping breaking '\(articleData.title)' — no valid media")
                    } else if let postId = try await LinkedInService.shared.postToLinkedIn(
                        text: lnText,
                        sourceURL: lnShowSourceLink ? articleData.sourceURL : nil,
                        sourceTitle: articleData.title,
                        imageURN: lnImageURN,
                        accessToken: lnAccessToken,
                        personId: lnPersonId
                    ) {
                        post.linkedinPostId = postId
                        try? context.save()
                        FileLogger.shared.log("[LinkedIn] Breaking posted: \(postId)\(lnImageURN != nil ? " +img" : "") for '\(articleData.title)'")

                        if lnSourceAsComment && !articleData.sourceURL.isEmpty {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            let ok = (try? await LinkedInService.shared.postComment(
                                postURN: postId,
                                text: articleData.sourceURL,
                                accessToken: lnAccessToken,
                                personId: lnPersonId
                            )) ?? false
                            FileLogger.shared.log("[LinkedIn] Source comment \(ok ? "posted" : "FAILED") for breaking \(postId)")
                        }

                        // Edit Telegram message to add LinkedIn link
                        if let msgId = post.telegramMessageId, !post.telegramText.isEmpty {
                            let linkedinURL = "https://www.linkedin.com/feed/update/\(postId)"
                            let newText = post.telegramText + "\n\n💼 \(linkedinURL)"
                            let hasMedia = !(article.mediaURL ?? "").isEmpty || VideoDownloader.isYouTubeVideo(article.sourceURL)
                            let editOk: Bool
                            if hasMedia {
                                editOk = await TelegramService.shared.editMessageCaption(
                                    botToken: botToken, channelId: channelId, messageId: msgId, caption: newText
                                )
                            } else {
                                editOk = await TelegramService.shared.editMessageText(
                                    botToken: botToken, channelId: channelId, messageId: msgId, text: newText
                                )
                            }
                            if editOk {
                                post.telegramText = newText
                                try? context.save()
                            }
                        }
                    }
                } catch {
                    FileLogger.shared.log("[LinkedIn] Breaking failed for '\(articleData.title)': \(error)")
                    if case NetworkError.requestFailed(403) = error {
                        post.linkedinPostId = "skipped_403"
                        try? context.save()
                    }
                }
            }
            // Cleanup downloaded video to free disk/memory
            if let videoFile = downloadedVideo {
                try? FileManager.default.removeItem(at: videoFile)
            }
        } catch {
            FileLogger.shared.log("Breaking publish failed: \(error)")
        }
    }

    // MARK: - Publish from queue

    func publishTopFromQueue(
        for project: Project,
        context: ModelContext
    ) async {
        guard canPublish(project: project, context: context) else { return }

        let projectId = project.id
        let cutoff = Date().addingTimeInterval(-Double(project.maxQueueAgeHours) * 3600)

        // Self-heal removed — it was resurrecting articles that were legitimately skipped
        // (e.g. low quality image, no media) causing infinite retry loops.

        // FetchDescriptor: direct SQLite query instead of N+1 relationship traversal
        var descriptor = FetchDescriptor<FetchedArticle>(
            predicate: #Predicate<FetchedArticle> { article in
                article.isUsed == false &&
                article.viralityScore > 0 &&
                article.fetchedAt >= cutoff
            }
        )
        descriptor.fetchLimit = 500 // Limit to avoid loading thousands of objects into memory
        guard let allCandidates = try? context.fetch(descriptor) else { return }
        let projectCandidates = allCandidates.filter { $0.source?.project?.id == projectId }

        // Filter by media requirement — YouTube videos ARE media, never filter them
        let publishable = project.requireMedia
            ? projectCandidates.filter { $0.hasMedia || VideoDownloader.isYouTubeVideo($0.sourceURL) }
            : projectCandidates

        // Debug: log candidate counts and YouTube article status
        let ytDebug = publishable.filter { VideoDownloader.isYouTubeVideo($0.sourceURL) }
        let webDebug = publishable.filter { !VideoDownloader.isYouTubeVideo($0.sourceURL) }
        FileLogger.shared.log("Queue: \(allCandidates.count) total, \(projectCandidates.count) project, \(publishable.count) publishable (web:\(webDebug.count) yt:\(ytDebug.count))")
        for yt in ytDebug.prefix(5) {
            FileLogger.shared.log("  YT candidate: '\(String(yt.title.prefix(50)))' v:\(yt.viralityScore) r:\(yt.relevanceScore) post:\(yt.generatedPost != nil)")
        }
        // (Removed heavy debug fetch that loaded all used YT articles — was causing memory bloat)

        // Sort by effective score
        let sorted = PriorityQueue.shared.sortedByEffectiveScore(
            articles: publishable,
            decayFactor: project.decayFactor
        )

        let minWebV = project.minPublishScore > 0 ? project.minPublishScore : 5.0
        let minWebR = project.minRelevanceScore > 0 ? project.minRelevanceScore : 5.0
        let minYTScore = project.minYoutubeScore > 0 ? project.minYoutubeScore : 5.0

        // Build dedup keywords ONCE for entire publish cycle
        let keywords = publishedKeywords(for: project, context: context)

        // Build candidate lists sorted by score — web and YouTube separately
        var webCandidates: [FetchedArticle] = []
        var ytCandidates: [FetchedArticle] = []
        for candidate in sorted {
            if candidate.generatedPost != nil {
                candidate.isUsed = true
                continue
            }
            let isYT = VideoDownloader.isYouTubeVideo(candidate.sourceURL)
            let passesScore = isYT
                ? candidate.relevanceScore >= minYTScore
                : (candidate.viralityScore >= minWebV || candidate.relevanceScore >= minWebR)
            if !passesScore {
                if isYT && ytCandidates.isEmpty {
                    FileLogger.shared.log("  YT skip (score): '\(String(candidate.title.prefix(40)))' r:\(candidate.relevanceScore) < min:\(minYTScore)")
                }
                continue
            }
            if isDuplicate(candidate, in: project, publishedKeywords: keywords) {
                if isYT && ytCandidates.isEmpty {
                    FileLogger.shared.log("  YT skip (dedup): '\(String(candidate.title.prefix(40)))'")
                }
                continue
            }
            if isYT {
                if ytCandidates.isEmpty {
                    FileLogger.shared.log("  YT selected: '\(String(candidate.title.prefix(40)))' r:\(candidate.relevanceScore)")
                }
                ytCandidates.append(candidate)
            } else {
                webCandidates.append(candidate)
            }
        }

        if webCandidates.isEmpty && ytCandidates.isEmpty {
            var belowScore = 0, dupCount = 0, hasPostCount = 0
            for candidate in sorted {
                if candidate.generatedPost != nil { hasPostCount += 1; continue }
                let isYT = VideoDownloader.isYouTubeVideo(candidate.sourceURL)
                let passes = isYT
                    ? candidate.relevanceScore >= minYTScore
                    : (candidate.viralityScore >= minWebV || candidate.relevanceScore >= minWebR)
                if !passes { belowScore += 1; continue }
                if isDuplicate(candidate, in: project, publishedKeywords: keywords) { dupCount += 1 }
            }
            FileLogger.shared.log("No publishable articles in queue for \(project.name) — belowScore:\(belowScore) dup:\(dupCount) hasPost:\(hasPostCount) minV:\(minWebV) minR:\(minWebR) minYT:\(minYTScore)")
            return
        }

        // Try web candidates in order — skip to next if image fails
        for article in webCandidates {
            let published = await publishSingleArticle(article, for: project, context: context)
            if published { break }
        }

        // Try YouTube candidates in their own slot
        if let article = ytCandidates.first, canPublish(project: project, context: context) {
            await publishSingleArticle(article, for: project, context: context)
        }
    }

    // MARK: - Publish single article

    /// Publish a single article to Telegram and save the post record.
    /// Returns true if published, false if skipped (e.g. bad image).
    @discardableResult
    private func publishSingleArticle(
        _ article: FetchedArticle,
        for project: Project,
        context: ModelContext
    ) async -> Bool {
        FileLogger.shared.log("Publishing: '\(article.title)' | media: \(article.mediaURL ?? "none") | score: \(article.viralityScore)")

        // Check if this exact URL was already published (prevents duplicate articles from concurrent crawls)
        // Use FetchDescriptor instead of traversing project.posts (which loads ALL posts into memory)
        let sourceURL = article.sourceURL
        let publishedStatus = PostStatus.published.rawValue
        var dupDescriptor = FetchDescriptor<GeneratedPost>(
            predicate: #Predicate<GeneratedPost> { post in
                post.statusRaw == publishedStatus
            }
        )
        dupDescriptor.fetchLimit = 500
        let recentPublished = (try? context.fetch(dupDescriptor)) ?? []
        let alreadyPublished = recentPublished.contains {
            $0.project?.id == project.id && $0.article?.sourceURL == sourceURL
        }
        if alreadyPublished {
            FileLogger.shared.log("SKIP duplicate: '\(article.title)' — URL already published")
            article.isUsed = true
            try? context.save()
            return true // don't retry this one
        }

        // Pre-check image quality BEFORE generating post (avoids wasting API call)
        let isYouTube = VideoDownloader.isYouTubeVideo(article.sourceURL)
        if !isYouTube, project.requireMedia {
            if let mediaURL = article.mediaURL, !mediaURL.isEmpty {
                let validURL = await Self.validatedImageURL(mediaURL)
                if validURL == nil {
                    FileLogger.shared.log("Skipping '\(article.title)' — image too low quality, trying next")
                    article.isUsed = true
                    try? context.save()
                    return false // try next candidate
                }
            } else {
                FileLogger.shared.log("Skipping '\(article.title)' — no media URL, trying next")
                article.isUsed = true
                try? context.save()
                return false // try next candidate
            }
        }

        // Mark as used IMMEDIATELY to prevent duplicate publishing from concurrent cycles
        article.isUsed = true
        try? context.save()

        // Extract ALL plain data + API key on MainActor BEFORE any await
        let channelPrompt = project.effectivePrompt
        let language = project.postLanguage
        let tgSymbol = project.telegramSymbol
        let tgShowSourceLink = project.telegramShowSourceLink
        let showChannelTag = project.telegramShowChannelTag
        let channelTag = project.telegramChannelId
        let showScores = project.telegramShowScores
        let botToken = project.telegramBotToken
        let channelId = project.telegramChannelId
        let articleData = (title: article.title, content: article.content, sourceURL: article.sourceURL)
        let articleMediaURL = article.mediaURL
        let articleViralityScore = article.viralityScore
        let articleRelevanceScore = article.relevanceScore
        let lengthCfg = project.lengthConfig
        let tgPostLength = project.telegramPostLength
        let openAIKey = OpenAIService.shared.apiKey

        do {
            // Generate post with OpenAI (always gpt-4.1-mini)
            let postContent = try await Task.detached {
                return try await OpenAIService.shared.generatePost(
                    article: articleData, channelPrompt: channelPrompt, language: language, withKey: openAIKey, lengthConfig: lengthCfg
                )
            }.value

            // Quality gate: reject posts where total text content is too short
            let textOnly = postContent.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .filter { !$0.contains("🔻") && !$0.contains("Source") }
                .joined(separator: " ")
            let alphanumericOnly = textOnly.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            let cleanLength = alphanumericOnly.count
            FileLogger.shared.log("Quality gate: '\(String(articleData.title.prefix(40)))' content=\(cleanLength) chars, lines=\(postContent.components(separatedBy: "\n").count)")
            if cleanLength < 20 {
                FileLogger.shared.log("REJECTED '\(articleData.title)' — post too short (\(cleanLength) alphanumeric chars)")
                article.isUsed = true
                try? context.save()
                return true // don't retry
            }

            // Extract sections for Telegram, then format with optional ⭕️ + source link
            let tgSections = PostLengthConfig.extractSections(postContent, for: tgPostLength)
            var telegramContent = PostLengthConfig.formatForTelegram(
                sections: tgSections,
                sourceURL: articleData.sourceURL,
                language: language,
                symbol: tgSymbol,
                showSourceLink: tgShowSourceLink
            )
            // Append Telegram-specific tags (NOT stored in post record)
            if showChannelTag {
                telegramContent += "\n\n\(channelTag)"
            }
            if showScores {
                telegramContent += "\n\n\u{1f4ca} V:\(String(format: "%.1f", articleViralityScore)) R:\(String(format: "%.1f", articleRelevanceScore))"
            }

            // Send to Telegram using extracted content
            let isYouTube = VideoDownloader.isYouTubeVideo(articleData.sourceURL)
            let messageId: Int?

            if isYouTube && VideoDownloader.shared.isAvailable {
                FileLogger.shared.log("Downloading YouTube video: \(articleData.sourceURL)")
                if let result = await VideoDownloader.shared.downloadVideo(url: articleData.sourceURL) {
                    FileLogger.shared.log("Uploading video to Telegram: \(result.video.lastPathComponent)")
                    messageId = try await TelegramService.shared.sendVideo(
                        botToken: botToken, channelId: channelId,
                        videoFile: result.video, caption: telegramContent, thumbnail: result.thumbnail
                    )
                    // Cleanup downloaded video to free disk/memory
                    try? FileManager.default.removeItem(at: result.video)
                } else {
                    let text = telegramContent + "\n\n\(articleData.sourceURL)"
                    FileLogger.shared.log("Video download failed, sending URL instead")
                    messageId = try await TelegramService.shared.sendMessage(
                        botToken: botToken, channelId: channelId, text: text
                    )
                }
            } else if isYouTube {
                let text = telegramContent + "\n\n\(articleData.sourceURL)"
                FileLogger.shared.log("Sending YouTube URL (yt-dlp not installed): \(articleData.sourceURL)")
                messageId = try await TelegramService.shared.sendMessage(
                    botToken: botToken, channelId: channelId, text: text
                )
            } else if let mediaURL = articleMediaURL, !mediaURL.isEmpty {
                let validURL = await Self.validatedImageURL(mediaURL)
                if let validURL {
                    FileLogger.shared.log("Sending photo: \(validURL)")
                    do {
                        messageId = try await TelegramService.shared.sendPhoto(
                            botToken: botToken, channelId: channelId, photoURL: validURL, caption: telegramContent
                        )
                    } catch {
                        if project.requireMedia {
                            FileLogger.shared.log("Photo failed (\(error)), skipping (media required)")
                            article.isUsed = true
                            try? context.save()
                            return true
                        }
                        FileLogger.shared.log("Photo failed (\(error)), falling back to text-only")
                        messageId = try await TelegramService.shared.sendMessage(
                            botToken: botToken, channelId: channelId, text: telegramContent
                        )
                    }
                } else if project.requireMedia {
                    FileLogger.shared.log("Skipping '\(articleData.title)' — image too low quality")
                    article.isUsed = true
                    try? context.save()
                    return true
                } else {
                    FileLogger.shared.log("Image low quality, falling back to text-only")
                    messageId = try await TelegramService.shared.sendMessage(
                        botToken: botToken, channelId: channelId, text: telegramContent
                    )
                }
            } else if !project.requireMedia {
                FileLogger.shared.log("Sending text-only: \(articleData.title)")
                messageId = try await TelegramService.shared.sendMessage(
                    botToken: botToken, channelId: channelId, text: telegramContent
                )
            } else {
                FileLogger.shared.log("Skipping '\(articleData.title)' — no media URL")
                article.isUsed = true
                try? context.save()
                return true
            }

            // Store FULL content (all sections, NO telegram tags/scores) in post record
            if let existingPost = article.generatedPost {
                existingPost.article = nil
            }

            let post = GeneratedPost(content: postContent, status: .published)
            post.publishedAt = Date()
            post.telegramMessageId = messageId
            post.telegramText = telegramContent
            context.insert(post)
            post.article = article
            post.project = project
            article.isUsed = true

            try context.save()
            invalidateCache(for: project.id)
            FileLogger.shared.log("Published from queue: \(article.title)")
            return true
        } catch {
            // Distinguish between Telegram config errors (retry) and other errors (skip)
            let isTelegramConfigError: Bool
            if case NetworkError.requestFailed(let code) = error, (400...499).contains(code) {
                isTelegramConfigError = true
            } else {
                isTelegramConfigError = false
            }

            if isTelegramConfigError {
                FileLogger.shared.log("Publish failed for '\(article.title)': \(error) — will retry (Telegram config issue)")
                return true // config error — other candidates will fail too
            } else {
                FileLogger.shared.log("Publish failed for '\(article.title)': \(error) — skipping")
                article.isUsed = true
                try? context.save()
                return true
            }
        }
    }
}
