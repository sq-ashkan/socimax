import Foundation
import SwiftData

@MainActor
final class ContentFetcher {
    static let shared = ContentFetcher()

    private let maxConcurrentFetches = 3  // Reduced from 5 to limit concurrent memory pressure

    private init() {}

    /// Track which sources were crawled last — rotate through all sources across cycles
    private var lastSourceIndex: [UUID: Int] = [:]
    private let maxSourcesPerCycle = 50  // Process sources in rotating batches to limit memory

    func fetchSources(for project: Project, context: ModelContext) async -> [FetchedArticle] {
        let allSources = project.sources.sorted(by: { $0.createdAt < $1.createdAt })

        // Rotate through sources: each cycle processes the next batch
        let startIndex = lastSourceIndex[project.id] ?? 0
        let endIndex = min(startIndex + maxSourcesPerCycle, allSources.count)
        let sources: [Source]
        if startIndex >= allSources.count {
            // Wrapped around — start from beginning
            sources = Array(allSources.prefix(maxSourcesPerCycle))
            lastSourceIndex[project.id] = min(maxSourcesPerCycle, allSources.count)
        } else {
            sources = Array(allSources[startIndex..<endIndex])
            lastSourceIndex[project.id] = endIndex >= allSources.count ? 0 : endIndex
        }
        FileLogger.shared.log("Crawling batch \(startIndex)-\(endIndex) of \(allSources.count) sources for \(project.name)")

        // Bounded concurrent fetching: max 10 at a time via sliding window
        let results = await withTaskGroup(of: [(Source, ParsedArticle)].self) { group in
            var allParsed: [(Source, ParsedArticle)] = []
            var sourceIndex = 0
            var activeTasks = 0

            // Helper to add next source to group
            func addNextSource() {
                guard sourceIndex < sources.count else { return }
                let source = sources[sourceIndex]
                let ytChannelId = source.youtubeChannelId
                let ytFilter = source.refinedYoutubeFilter.isEmpty ? source.youtubeFilter : source.refinedYoutubeFilter
                group.addTask {
                    do {
                        if !ytChannelId.isEmpty {
                            // YouTube source: fetch RSS feed
                            let rssURL = "https://www.youtube.com/feeds/videos.xml?channel_id=\(ytChannelId)"
                            FileLogger.shared.log("Fetching YouTube RSS: \(ytChannelId)")
                            let xml = try await NetworkClient.shared.fetch(url: rssURL)
                            var parsed = HTMLParser.parseYouTubeRSS(xml, channelId: ytChannelId)
                            FileLogger.shared.log("YouTube RSS parsed: \(parsed.count) videos from \(ytChannelId)")
                            // Apply YouTube filter keywords if set
                            if !ytFilter.isEmpty {
                                let beforeCount = parsed.count
                                let keywords = ytFilter.lowercased()
                                    .components(separatedBy: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                                if !keywords.isEmpty {
                                    parsed = parsed.filter { article in
                                        let lower = (article.title + " " + article.content).lowercased()
                                        return keywords.contains { lower.contains($0) }
                                    }
                                    FileLogger.shared.log("YouTube filter: \(parsed.count)/\(beforeCount) matched keywords")
                                }
                            }
                            // YouTube: keep all videos from RSS (curated channel, no need to limit)
                            return parsed.map { (source, $0) }
                        } else {
                            // Regular web source — parse inside autoreleasepool to free SwiftSoup DOM immediately
                            let html = try await NetworkClient.shared.fetch(url: source.url)
                            let parsed: [ParsedArticle] = autoreleasepool {
                                HTMLParser.extractArticlesSync(from: html, sourceURL: source.url)
                            }
                            return Array(parsed.prefix(3)).map { (source, $0) }
                        }
                    } catch {
                        FileLogger.shared.log("Failed to fetch \(source.url): \(error)")
                        return []
                    }
                }
                sourceIndex += 1
                activeTasks += 1
            }

            // Launch initial batch (up to maxConcurrentFetches)
            while sourceIndex < sources.count && activeTasks < maxConcurrentFetches {
                addNextSource()
            }

            // Process results and add more tasks as slots open
            for await result in group {
                allParsed.append(contentsOf: result)
                activeTasks -= 1
                // Fill the slot with next source
                if sourceIndex < sources.count {
                    addNextSource()
                }
            }
            return allParsed
        }

        // Process results on main context (SwiftData not thread-safe)
        // Only dedup against recent articles (14 days) to avoid loading entire DB into memory
        let allExistingURLs: Set<String> = {
            let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
            var descriptor = FetchDescriptor<FetchedArticle>(
                predicate: #Predicate<FetchedArticle> { article in
                    article.fetchedAt >= cutoff
                }
            )
            descriptor.propertiesToFetch = [\.sourceURL]
            guard let all = try? context.fetch(descriptor) else { return [] }
            let urls = Set(all.map(\.sourceURL))
            return urls
        }()
        var insertedURLs = Set<String>() // track URLs inserted this batch
        var allArticles: [FetchedArticle] = []
        for (source, article) in results {
            guard !allExistingURLs.contains(article.url) else { continue }
            guard !insertedURLs.contains(article.url) else { continue }
            insertedURLs.insert(article.url)

            // Use image from HTML only (og:image fallback is too slow for many sources)
            var imageURL = article.imageURL
            if let url = imageURL {
                imageURL = HTMLParser.fullSizeImageURL(url)
            }

            // Truncate content to 2000 chars — AI scoring only needs summary, not full text
            let truncatedContent = article.content.count > 2000
                ? String(article.content.prefix(2000))
                : article.content
            let fetched = FetchedArticle(
                title: article.title,
                content: truncatedContent,
                sourceURL: article.url,
                mediaURL: imageURL
            )
            fetched.source = source
            context.insert(fetched)
            allArticles.append(fetched)
        }

        return allArticles
    }
}
