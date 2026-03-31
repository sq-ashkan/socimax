import Foundation
import SwiftData

final class CacheManager {
    static let shared = CacheManager()

    private let videosDir: URL
    private let logFile: URL
    private let maxLogLines = 500
    private let usedArticleMaxAge: TimeInterval = 3 * 24 * 3600     // 3 days for used articles
    private let unusedArticleMaxAge: TimeInterval = 7 * 24 * 3600    // 7 days for unused articles
    private let performanceMaxAge: TimeInterval = 30 * 24 * 3600     // 30 days for performance records

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        videosDir = appSupport.appendingPathComponent("SociMax/videos")
        logFile = appSupport.appendingPathComponent("SociMax/socimax.log")
    }

    /// Run all cleanup tasks
    @MainActor
    func performCleanup(context: ModelContext) {
        cleanOldVideos()
        cleanOrphanedTempVideos()
        cleanOldArticles(context: context)
        cleanUnusedArticles(context: context)
        cleanOldPerformance(context: context)
        trimLog()
    }

    /// Delete video files older than 3 days
    func cleanOldVideos(olderThan maxAge: TimeInterval? = nil) {
        let cutoff = Date().addingTimeInterval(-(maxAge ?? usedArticleMaxAge))
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(
            at: videosDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var deletedCount = 0
        for file in files {
            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let modified = attrs[.modificationDate] as? Date else { continue }

            if modified < cutoff {
                try? fm.removeItem(at: file)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            FileLogger.shared.log("Cache: cleaned \(deletedCount) old video files")
        }
    }

    /// Delete orphaned temp video files (partial downloads, compression artifacts)
    func cleanOrphanedTempVideos() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: videosDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let oneHourAgo = Date().addingTimeInterval(-3600)
        var deletedCount = 0
        for file in files {
            let name = file.lastPathComponent
            // Clean temp files older than 1 hour
            let isTempFile = name.contains("_temp") || name.hasSuffix(".part") || name.hasSuffix(".ytdl")
            guard isTempFile else { continue }

            guard let attrs = try? fm.attributesOfItem(atPath: file.path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < oneHourAgo else { continue }

            try? fm.removeItem(at: file)
            deletedCount += 1
        }
        if deletedCount > 0 {
            FileLogger.shared.log("Cache: cleaned \(deletedCount) orphaned temp video files")
        }
    }

    /// Delete used FetchedArticle records older than 3 days
    @MainActor
    func cleanOldArticles(context: ModelContext, olderThan maxAge: TimeInterval? = nil) {
        let cutoff = Date().addingTimeInterval(-(maxAge ?? usedArticleMaxAge))

        let descriptor = FetchDescriptor<FetchedArticle>(
            predicate: #Predicate<FetchedArticle> { article in
                article.isUsed == true && article.fetchedAt < cutoff
            }
        )

        guard let oldArticles = try? context.fetch(descriptor) else { return }

        var deletedCount = 0
        for article in oldArticles {
            if let post = article.generatedPost {
                context.delete(post)
            }
            context.delete(article)
            deletedCount += 1
        }

        if deletedCount > 0 {
            try? context.save()
            FileLogger.shared.log("Cache: cleaned \(deletedCount) old used articles (>\(Int(usedArticleMaxAge / 86400))d)")
        }
    }

    /// Delete unused articles older than 7 days (never published, stale queue items)
    @MainActor
    func cleanUnusedArticles(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-unusedArticleMaxAge)

        let descriptor = FetchDescriptor<FetchedArticle>(
            predicate: #Predicate<FetchedArticle> { article in
                article.isUsed == false && article.fetchedAt < cutoff
            }
        )

        guard let oldArticles = try? context.fetch(descriptor) else { return }

        var deletedCount = 0
        for article in oldArticles {
            if let post = article.generatedPost {
                context.delete(post)
            }
            context.delete(article)
            deletedCount += 1
        }

        if deletedCount > 0 {
            try? context.save()
            FileLogger.shared.log("Cache: cleaned \(deletedCount) stale unused articles (>\(Int(unusedArticleMaxAge / 86400))d)")
        }
    }

    /// Delete PostPerformance records older than 30 days
    @MainActor
    func cleanOldPerformance(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-performanceMaxAge)

        let descriptor = FetchDescriptor<PostPerformance>(
            predicate: #Predicate<PostPerformance> { perf in
                perf.checkedAt < cutoff
            }
        )

        guard let oldPerf = try? context.fetch(descriptor) else { return }

        var deletedCount = 0
        for perf in oldPerf {
            context.delete(perf)
            deletedCount += 1
        }

        if deletedCount > 0 {
            try? context.save()
            FileLogger.shared.log("Cache: cleaned \(deletedCount) old performance records (>30d)")
        }
    }

    /// Trim log file to last N lines
    func trimLog(maxLines: Int? = nil) {
        let limit = maxLines ?? maxLogLines
        let fm = FileManager.default

        guard fm.fileExists(atPath: logFile.path),
              let content = try? String(contentsOf: logFile, encoding: .utf8) else { return }

        let lines = content.components(separatedBy: "\n")
        guard lines.count > limit else { return }

        let trimmed = lines.suffix(limit).joined(separator: "\n")
        try? trimmed.write(to: logFile, atomically: true, encoding: .utf8)
        FileLogger.shared.log("Cache: trimmed log from \(lines.count) to \(limit) lines")
    }
}
