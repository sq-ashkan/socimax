import Foundation
import SwiftData
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.socimax.app", category: "Scheduler")

@MainActor
final class AutomationScheduler: ObservableObject {
    static let shared = AutomationScheduler()

    @Published var isRunning = false
    @Published var lastActivity: String = ""

    private var crawlTimers: [UUID: Timer] = [:]
    private var publishTimers: [UUID: Timer] = [:]
    private var twitterPublishTimers: [UUID: Timer] = [:]
    private var startupTasks: [UUID: Task<Void, Never>] = [:]
    private var feedbackTimer: Timer?
    private var modelContainer: ModelContainer?
    private var lastCleanup: Date = .distantPast
    private var sleepActivity: NSObjectProtocol?

    // Serial queues: projects line up, none get skipped
    private var crawlQueue: [UUID] = []
    private var currentCrawlId: UUID?
    private var publishQueue: [UUID] = []
    private var currentPublishId: UUID?
    private var twitterPublishQueue: [UUID] = []
    private var currentTwitterPublishId: UUID?
    private var linkedinPublishTimers: [UUID: Timer] = [:]
    private var linkedinPublishQueue: [UUID] = []
    private var currentLinkedinPublishId: UUID?

    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var activeIdsBeforeSleep: [UUID] = []

    private init() {}

    func configure(with container: ModelContainer) {
        self.modelContainer = container
        FileLogger.shared.log("Scheduler configured")
        if wakeObserver == nil {
            setupWakeHandler()
        }
    }

    /// Stop timers BEFORE system sleeps to prevent stale contexts on wake.
    /// Restart automation with fresh contexts AFTER wake.
    private func setupWakeHandler() {
        // SLEEP: stop all timers SYNCHRONOUSLY before system sleeps.
        // Must NOT use Task{} — system may sleep before async task executes.
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                FileLogger.shared.log("System going to sleep — stopping all timers to prevent stale contexts")

                // Remember which projects were active before stopping
                self.activeIdsBeforeSleep = Array(self.crawlTimers.keys)

                // Stop everything (invalidates timers so nothing fires with stale contexts)
                self.stopAll()

                // Flush data to disk before sleep
                walCheckpoint()
            }
        }

        // WAKE: restart automation with fresh contexts
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let container = self.modelContainer else { return }

                let savedIds = self.activeIdsBeforeSleep
                self.activeIdsBeforeSleep = []

                // If sleep handler ran, stopAll() already cleared timers.
                // If not (forced sleep), stop stale timers now.
                if self.isRunning {
                    self.stopAll()
                }

                FileLogger.shared.log("System woke from sleep — restarting automation with fresh contexts")

                // Wait for system to stabilize after wake
                try? await Task.sleep(for: .seconds(5))

                // Restart with fresh contexts
                let context = ModelContext(container); context.autosaveEnabled = false
                let descriptor = FetchDescriptor<Project>()
                guard let projects = try? context.fetch(descriptor) else { return }

                let activeProjects: [Project]
                if !savedIds.isEmpty {
                    // Sleep handler ran — use remembered project IDs
                    activeProjects = projects.filter { savedIds.contains($0.id) && $0.isActive }
                } else {
                    // Sleep handler didn't run (forced sleep) — restart all active projects
                    activeProjects = projects.filter(\.isActive)
                }

                if !activeProjects.isEmpty {
                    self.startAll(projects: activeProjects)
                    FileLogger.shared.log("Automation restarted for \(activeProjects.count) projects after wake")
                }
            }
        }
    }

    func startAll(projects: [Project]) {
        isRunning = true
        preventSystemSleep()
        FileLogger.shared.log("Starting automation for \(projects.count) projects")
        for project in projects where project.isActive {
            startProject(project)
        }
        startFeedbackLoop()
    }

    func stopAll() {
        isRunning = false
        allowSystemSleep()
        crawlTimers.values.forEach { $0.invalidate() }
        publishTimers.values.forEach { $0.invalidate() }
        twitterPublishTimers.values.forEach { $0.invalidate() }
        linkedinPublishTimers.values.forEach { $0.invalidate() }
        startupTasks.values.forEach { $0.cancel() }
        feedbackTimer?.invalidate()
        crawlTimers.removeAll()
        publishTimers.removeAll()
        twitterPublishTimers.removeAll()
        linkedinPublishTimers.removeAll()
        startupTasks.removeAll()
        feedbackTimer = nil
        crawlQueue.removeAll()
        publishQueue.removeAll()
        twitterPublishQueue.removeAll()
        linkedinPublishQueue.removeAll()
        lastActivity = "Stopped"
        logger.info("All automation stopped")
    }

    func startProject(_ project: Project) {
        guard let container = modelContainer else {
            logger.error("No model container configured!")
            lastActivity = "Error: No database connection"
            return
        }

        // Stop existing timers for this project first (prevent duplicate starts)
        stopProject(project.id)

        // Mark as running and ensure feedback loop is active
        if !isRunning {
            isRunning = true
            preventSystemSleep()
            startFeedbackLoop()
        }

        FileLogger.shared.log("Starting project: \(project.name) (crawl: \(project.crawlIntervalMinutes)m, telegram: \(project.telegramPublishIntervalMinutes)m, max: \(project.telegramMaxPostsPerDay) posts/day\(project.twitterEnabled ? ", twitter: \(project.twitterPublishIntervalMinutes)m" : "")\(project.linkedinEnabled ? ", linkedin: \(project.linkedinPublishIntervalMinutes)m" : ""))")

        // Crawl timer
        let crawlInterval = TimeInterval(project.crawlIntervalMinutes * 60)
        let crawlTimer = Timer.scheduledTimer(withTimeInterval: crawlInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.enqueueCrawl(for: project.id, container: container)
            }
        }
        crawlTimers[project.id] = crawlTimer

        // Publish timer: configurable per project
        let publishMinutes = max(1, project.telegramPublishIntervalMinutes > 0 ? project.telegramPublishIntervalMinutes : 5)
        let publishInterval = TimeInterval(publishMinutes * 60)
        logger.info("Publish interval: \(publishMinutes)m")
        let publishTimer = Timer.scheduledTimer(withTimeInterval: publishInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.enqueuePublish(for: project.id, container: container)
            }
        }
        publishTimers[project.id] = publishTimer

        // Twitter publish timer (independent interval)
        if project.twitterEnabled && !project.twitterApiKey.isEmpty {
            let twMinutes = max(1, project.twitterPublishIntervalMinutes)
            let twInterval = TimeInterval(twMinutes * 60)
            let twTimer = Timer.scheduledTimer(withTimeInterval: twInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.enqueueTwitterPublish(for: project.id, container: container)
                }
            }
            twitterPublishTimers[project.id] = twTimer
            FileLogger.shared.log("[Twitter] Timer started: every \(twMinutes)m for \(project.name)")
        }

        // LinkedIn publish timer (independent interval)
        if project.linkedinEnabled && !project.linkedinAccessToken.isEmpty {
            let lnMinutes = max(1, project.linkedinPublishIntervalMinutes)
            let lnInterval = TimeInterval(lnMinutes * 60)
            let lnTimer = Timer.scheduledTimer(withTimeInterval: lnInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.enqueueLinkedinPublish(for: project.id, container: container)
                }
            }
            linkedinPublishTimers[project.id] = lnTimer
            FileLogger.shared.log("[LinkedIn] Timer started: every \(lnMinutes)m for \(project.name)")
        }

        // Run first crawl + publish immediately via queue
        lastActivity = "Starting first crawl for \(project.name)..."
        let projectId = project.id
        startupTasks[projectId] = Task {
            enqueueCrawl(for: projectId, container: container)
            // First publish after crawl completes (handled by queue processor)
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            enqueuePublish(for: projectId, container: container)
            // Twitter: do NOT fire immediately — let the timer handle it
            // This prevents duplicate tweets when project restarts on settings change
        }
    }

    func stopProject(_ projectId: UUID) {
        crawlTimers[projectId]?.invalidate()
        publishTimers[projectId]?.invalidate()
        twitterPublishTimers[projectId]?.invalidate()
        linkedinPublishTimers[projectId]?.invalidate()
        startupTasks[projectId]?.cancel()
        crawlTimers.removeValue(forKey: projectId)
        publishTimers.removeValue(forKey: projectId)
        twitterPublishTimers.removeValue(forKey: projectId)
        linkedinPublishTimers.removeValue(forKey: projectId)
        startupTasks.removeValue(forKey: projectId)
        crawlQueue.removeAll { $0 == projectId }
        publishQueue.removeAll { $0 == projectId }
        twitterPublishQueue.removeAll { $0 == projectId }
        linkedinPublishQueue.removeAll { $0 == projectId }

        // If no more active projects, stop everything
        if crawlTimers.isEmpty {
            isRunning = false
            allowSystemSleep()
            feedbackTimer?.invalidate()
            feedbackTimer = nil
            lastActivity = "Stopped"
        }
    }

    func triggerCrawl(for project: Project) async {
        guard let container = modelContainer else { return }
        lastActivity = "Manual crawl for \(project.name)..."
        enqueueCrawl(for: project.id, container: container)
    }

    // MARK: - Queue management

    private func enqueueCrawl(for projectId: UUID, container: ModelContainer) {
        // Don't add if already queued or currently crawling
        guard !crawlQueue.contains(projectId), currentCrawlId != projectId else { return }
        crawlQueue.append(projectId)
        processCrawlQueue(container: container)
    }

    private func processCrawlQueue(container: ModelContainer) {
        guard currentCrawlId == nil, let nextId = crawlQueue.first else { return }
        crawlQueue.removeFirst()
        currentCrawlId = nextId

        Task {
            await runCrawlCycle(for: nextId, container: container)
            currentCrawlId = nil
            // Process pending publishes FIRST (before next crawl takes over)
            processPublishQueue(container: container)
            processTwitterPublishQueue(container: container)
            processLinkedinPublishQueue(container: container)
            // Then process next crawl
            processCrawlQueue(container: container)
        }
    }

    private func enqueuePublish(for projectId: UUID, container: ModelContainer) {
        guard !publishQueue.contains(projectId), currentPublishId != projectId else { return }
        publishQueue.append(projectId)
        processPublishQueue(container: container)
    }

    private func processPublishQueue(container: ModelContainer) {
        guard currentCrawlId == nil, currentPublishId == nil, let nextId = publishQueue.first else { return }
        publishQueue.removeFirst()
        currentPublishId = nextId

        Task {
            await runPublishCycle(for: nextId, container: container)
            currentPublishId = nil
            processPublishQueue(container: container)
        }
    }

    // MARK: - Twitter publish queue

    private func enqueueTwitterPublish(for projectId: UUID, container: ModelContainer) {
        guard !twitterPublishQueue.contains(projectId), currentTwitterPublishId != projectId else { return }
        twitterPublishQueue.append(projectId)
        processTwitterPublishQueue(container: container)
    }

    private func processTwitterPublishQueue(container: ModelContainer) {
        guard currentCrawlId == nil, currentTwitterPublishId == nil, let nextId = twitterPublishQueue.first else { return }
        twitterPublishQueue.removeFirst()
        currentTwitterPublishId = nextId

        Task {
            await runTwitterPublishCycle(for: nextId, container: container)
            currentTwitterPublishId = nil
            processTwitterPublishQueue(container: container)
        }
    }

    private func runTwitterPublishCycle(for projectId: UUID, container: ModelContainer) async {
        let context = ModelContext(container); context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try? context.fetch(descriptor).first,
              project.isActive, project.twitterEnabled else {
            return
        }

        guard project.canPublishTwitter else {
            FileLogger.shared.log("[Twitter] Daily limit reached for \(project.name)")
            return
        }

        // Find published posts without a tweet ID, pick HIGHEST scoring (not oldest)
        var postDescriptor = FetchDescriptor<GeneratedPost>(
            predicate: #Predicate<GeneratedPost> { post in
                post.statusRaw == "published" && post.twitterTweetId == ""
            }
        )
        postDescriptor.fetchLimit = 200 // Limit to avoid loading thousands of posts into memory
        guard let allCandidates = try? context.fetch(postDescriptor) else {
            FileLogger.shared.log("[Twitter] No untweeted posts for \(project.name)")
            return
        }
        let projectCandidates = allCandidates.filter { $0.project?.id == projectId }

        // Filter by maxAge, then sort by effective score (virality * decay)
        let decayFactor = project.decayFactor
        let maxAge = project.twitterMaxAgeHours > 0 ? project.twitterMaxAgeHours : 24
        let now = Date()
        let sorted = projectCandidates.filter { post in
            let age = now.timeIntervalSince(post.article?.fetchedAt ?? now) / 3600
            return age <= maxAge
        }.sorted { a, b in
            let aScore = a.article?.viralityScore ?? 0
            let bScore = b.article?.viralityScore ?? 0
            let aAge = now.timeIntervalSince(a.article?.fetchedAt ?? now) / 3600
            let bAge = now.timeIntervalSince(b.article?.fetchedAt ?? now) / 3600
            let aEffective = aScore * exp(-decayFactor * aAge)
            let bEffective = bScore * exp(-decayFactor * bAge)
            return aEffective > bEffective
        }
        guard !sorted.isEmpty else {
            FileLogger.shared.log("[Twitter] No untweeted posts for \(project.name)")
            return
        }

        // Extract config (shared across all candidates)
        let apiKey = project.twitterApiKey
        let apiSecret = project.twitterApiSecret
        let accessToken = project.twitterAccessToken
        let accessTokenSecret = project.twitterAccessTokenSecret
        let showSourceLink = project.twitterShowSourceLink
        let showScores = project.twitterShowScores
        let showHandle = project.twitterShowHandle
        let handle = project.twitterHandle
        let twSymbol = project.twitterSymbol
        let twSourceAsReply = project.twitterSourceAsReply
        let twRequireImage = project.twitterRequireImage
        let twPostLength = project.twitterPostLength

        // Try candidates in score order — skip to next if image fails
        for post in sorted {
            let fullContent = post.content
            let twitterContent = PostLengthConfig.extractSections(fullContent, for: twPostLength)
            let sourceURL = post.article?.sourceURL ?? ""
            let mediaURL = post.article?.mediaURL ?? ""
            let isYouTube = VideoDownloader.isYouTubeVideo(sourceURL)
            let viralityScore = post.article?.viralityScore ?? 0
            let relevanceScore = post.article?.relevanceScore ?? 0

            // Pre-check: if image required, validate before doing anything else
            if twRequireImage && !isYouTube {
                if mediaURL.isEmpty {
                    FileLogger.shared.log("[Twitter] Skipping '\(post.article?.title ?? "unknown")' — no media URL, trying next")
                    post.twitterTweetId = "skipped_no_image"
                    try? context.save()
                    continue
                }
                let validImg = await ViralityPredictor.validatedImageURL(mediaURL)
                if validImg == nil {
                    FileLogger.shared.log("[Twitter] Skipping '\(post.article?.title ?? "unknown")' — image too low quality, trying next")
                    post.twitterTweetId = "skipped_no_image"
                    try? context.save()
                    continue
                }
            }

            let tweet = TwitterService.formatTweet(
                postContent: twitterContent,
                sourceURL: sourceURL,
                showSourceLink: showSourceLink,
                showScores: showScores,
                viralityScore: viralityScore,
                relevanceScore: relevanceScore,
                showHandle: showHandle,
                handle: handle,
                symbol: twSymbol
            )

            do {
                // Upload media if available
                var mediaId: String? = nil
                if !mediaURL.isEmpty && !isYouTube,
                   let validImg = await ViralityPredictor.validatedImageURL(mediaURL) {
                    mediaId = try? await TwitterService.shared.uploadImage(
                        fromURL: validImg,
                        apiKey: apiKey, apiSecret: apiSecret,
                        accessToken: accessToken, accessTokenSecret: accessTokenSecret
                    )
                }

                // Final check: skip if image required but upload failed
                if twRequireImage && mediaId == nil && !isYouTube {
                    FileLogger.shared.log("[Twitter] Skipping '\(post.article?.title ?? "unknown")' — media upload failed, trying next")
                    post.twitterTweetId = "skipped_no_image"
                    try? context.save()
                    continue
                }

                if let tweetId = try await TwitterService.shared.postTweet(
                    text: tweet,
                    mediaId: mediaId,
                    apiKey: apiKey,
                    apiSecret: apiSecret,
                    accessToken: accessToken,
                    accessTokenSecret: accessTokenSecret
                ) {
                    post.twitterTweetId = tweetId
                    try? context.save()
                    FileLogger.shared.log("[Twitter] Published: \(tweetId)\(mediaId != nil ? " +img" : "") — '\(post.article?.title ?? "unknown")'")
                    lastActivity = "[Twitter] Published for \(project.name)"

                    // Post source link as reply if enabled
                    if twSourceAsReply && !sourceURL.isEmpty {
                        let _ = try? await TwitterService.shared.postTweet(
                            text: sourceURL,
                            replyToTweetId: tweetId,
                            apiKey: apiKey, apiSecret: apiSecret,
                            accessToken: accessToken, accessTokenSecret: accessTokenSecret
                        )
                        FileLogger.shared.log("[Twitter] Source reply posted for \(tweetId)")
                    }

                    // Edit Telegram message to add tweet link
                    let tweetHandle = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
                    let tweetURL = "https://x.com/\(tweetHandle)/status/\(tweetId)"
                    await appendLinkToTelegramMessage(post: post, project: project, link: "🐦 \(tweetURL)", context: context)
                }
                break // successfully published — stop trying candidates
            } catch {
                FileLogger.shared.log("[Twitter] Publish failed for '\(post.article?.title ?? "unknown")': \(error)")
                if case NetworkError.requestFailed(403) = error {
                    post.twitterTweetId = "skipped_403"
                    try? context.save()
                    FileLogger.shared.log("[Twitter] Marked as skipped (403) — trying next candidate")
                    continue // try next candidate
                }
                break // other errors (rate limit, config) — stop trying
            }
        }
    }

    // MARK: - LinkedIn publish queue

    private func enqueueLinkedinPublish(for projectId: UUID, container: ModelContainer) {
        guard !linkedinPublishQueue.contains(projectId), currentLinkedinPublishId != projectId else { return }
        linkedinPublishQueue.append(projectId)
        processLinkedinPublishQueue(container: container)
    }

    private func processLinkedinPublishQueue(container: ModelContainer) {
        guard currentCrawlId == nil, currentLinkedinPublishId == nil, let nextId = linkedinPublishQueue.first else { return }
        linkedinPublishQueue.removeFirst()
        currentLinkedinPublishId = nextId

        Task {
            await runLinkedinPublishCycle(for: nextId, container: container)
            currentLinkedinPublishId = nil
            processLinkedinPublishQueue(container: container)
        }
    }

    private func runLinkedinPublishCycle(for projectId: UUID, container: ModelContainer) async {
        let context = ModelContext(container); context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try? context.fetch(descriptor).first,
              project.isActive, project.linkedinEnabled else {
            return
        }

        guard project.canPublishLinkedin else {
            FileLogger.shared.log("[LinkedIn] Daily limit reached for \(project.name)")
            return
        }

        // Find published posts without a LinkedIn post ID
        var postDescriptor = FetchDescriptor<GeneratedPost>(
            predicate: #Predicate<GeneratedPost> { post in
                post.statusRaw == "published" && post.linkedinPostId == ""
            }
        )
        postDescriptor.fetchLimit = 200
        guard let allCandidates = try? context.fetch(postDescriptor) else {
            FileLogger.shared.log("[LinkedIn] No unposted posts for \(project.name)")
            return
        }
        let projectCandidates = allCandidates.filter { $0.project?.id == projectId }

        // Filter by maxAge, then sort by effective score
        let decayFactor = project.decayFactor
        let maxAge = project.linkedinMaxAgeHours > 0 ? project.linkedinMaxAgeHours : 48
        let now = Date()
        let sorted = projectCandidates.filter { post in
            let age = now.timeIntervalSince(post.article?.fetchedAt ?? now) / 3600
            return age <= maxAge
        }.sorted { a, b in
            let aScore = a.article?.viralityScore ?? 0
            let bScore = b.article?.viralityScore ?? 0
            let aAge = now.timeIntervalSince(a.article?.fetchedAt ?? now) / 3600
            let bAge = now.timeIntervalSince(b.article?.fetchedAt ?? now) / 3600
            let aEffective = aScore * exp(-decayFactor * aAge)
            let bEffective = bScore * exp(-decayFactor * bAge)
            return aEffective > bEffective
        }
        guard !sorted.isEmpty else {
            FileLogger.shared.log("[LinkedIn] No unposted posts for \(project.name)")
            return
        }

        let lnAccessToken = project.linkedinAccessToken
        let lnPersonId = project.linkedinPersonId
        let showSourceLink = project.linkedinShowSourceLink
        let showScores = project.linkedinShowScores
        let showHandle = project.linkedinShowHandle
        let handle = project.linkedinHandle
        let lnSymbol = project.linkedinSymbol
        let lnSourceAsComment = project.linkedinSourceAsComment
        let lnRequireImage = project.linkedinRequireImage
        let lnPostLength = project.linkedinPostLength

        for post in sorted {
            let fullContent = post.content
            let lnContent = PostLengthConfig.extractSections(fullContent, for: lnPostLength)
            let sourceURL = post.article?.sourceURL ?? ""
            let mediaURL = post.article?.mediaURL ?? ""
            let title = post.article?.title ?? ""
            let viralityScore = post.article?.viralityScore ?? 0
            let relevanceScore = post.article?.relevanceScore ?? 0

            // Pre-check: require image
            if lnRequireImage {
                if mediaURL.isEmpty {
                    post.linkedinPostId = "skipped_no_image"
                    try? context.save()
                    continue
                }
                let validImg = await ViralityPredictor.validatedImageURL(mediaURL)
                if validImg == nil {
                    post.linkedinPostId = "skipped_no_image"
                    try? context.save()
                    continue
                }
            }

            let text = LinkedInService.formatLinkedInPost(
                postContent: lnContent,
                sourceURL: showSourceLink ? sourceURL : "",
                showSourceLink: false,  // URL goes in article content, not text suffix
                showScores: showScores,
                viralityScore: viralityScore,
                relevanceScore: relevanceScore,
                showHandle: showHandle,
                handle: handle,
                symbol: lnSymbol
            )

            do {
                // Upload image if available
                var imageURN: String? = nil
                if !mediaURL.isEmpty,
                   let validImg = await ViralityPredictor.validatedImageURL(mediaURL) {
                    imageURN = try? await LinkedInService.shared.uploadImage(
                        fromURL: validImg,
                        accessToken: lnAccessToken,
                        personId: lnPersonId
                    )
                }

                if lnRequireImage && imageURN == nil {
                    post.linkedinPostId = "skipped_no_image"
                    try? context.save()
                    continue
                }

                if let postId = try await LinkedInService.shared.postToLinkedIn(
                    text: text,
                    sourceURL: showSourceLink ? sourceURL : nil,
                    sourceTitle: title,
                    imageURN: imageURN,
                    accessToken: lnAccessToken,
                    personId: lnPersonId
                ) {
                    post.linkedinPostId = postId
                    try? context.save()
                    lastActivity = "[LinkedIn] Published for \(project.name)"

                    // Post source as comment if enabled
                    if lnSourceAsComment && !sourceURL.isEmpty {
                        // Wait for LinkedIn to index the post before commenting
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                        let ok = (try? await LinkedInService.shared.postComment(
                            postURN: postId,
                            text: sourceURL,
                            accessToken: lnAccessToken,
                            personId: lnPersonId
                        )) ?? false
                        FileLogger.shared.log("[LinkedIn] Source comment \(ok ? "posted" : "FAILED") for \(postId)")
                    }

                    // Edit Telegram message to add LinkedIn link
                    let linkedinURL = "https://www.linkedin.com/feed/update/\(postId)"
                    await appendLinkToTelegramMessage(post: post, project: project, link: "💼 \(linkedinURL)", context: context)
                }
                break
            } catch {
                FileLogger.shared.log("[LinkedIn] Publish failed for '\(title)': \(error)")
                if case NetworkError.requestFailed(403) = error {
                    post.linkedinPostId = "skipped_403"
                    try? context.save()
                    continue
                }
                break
            }
        }
    }

    // MARK: - Telegram cross-link editing

    private func appendLinkToTelegramMessage(post: GeneratedPost, project: Project, link: String, context: ModelContext) async {
        guard let messageId = post.telegramMessageId, !post.telegramText.isEmpty else { return }
        let botToken = project.telegramBotToken
        let channelId = project.telegramChannelId
        guard !botToken.isEmpty, !channelId.isEmpty else { return }

        let newText = post.telegramText + "\n\n" + link
        let hasMedia = !(post.article?.mediaURL ?? "").isEmpty || VideoDownloader.isYouTubeVideo(post.article?.sourceURL ?? "")

        let ok: Bool
        if hasMedia {
            ok = await TelegramService.shared.editMessageCaption(
                botToken: botToken, channelId: channelId, messageId: messageId, caption: newText
            )
        } else {
            ok = await TelegramService.shared.editMessageText(
                botToken: botToken, channelId: channelId, messageId: messageId, text: newText
            )
        }

        if ok {
            post.telegramText = newText
            try? context.save()
            FileLogger.shared.log("[Telegram] Edited message \(messageId) — added cross-link")
        } else {
            FileLogger.shared.log("[Telegram] Failed to edit message \(messageId)")
        }
    }

    // MARK: - Prevent system sleep while automation is active

    private func preventSystemSleep() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "SociMax automation is running"
        )
        FileLogger.shared.log("System sleep disabled — automation active")
    }

    private func allowSystemSleep() {
        guard let activity = sleepActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        sleepActivity = nil
        FileLogger.shared.log("System sleep re-enabled — automation stopped")
    }

    private func runCrawlCycle(for projectId: UUID, container: ModelContainer) async {
        let context = ModelContext(container); context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try? context.fetch(descriptor).first,
              project.isActive else {
            logger.warning("Project not found or inactive — stopping stale timers")
            stopProject(projectId)
            return
        }

        lastActivity = "Crawling \(project.sources.count) sources for \(project.name)..."
        FileLogger.shared.log("Crawling \(project.sources.count) sources for \(project.name)")

        // Fetch new articles (already limited to 3 per source by ContentFetcher)
        let newArticles = await ContentFetcher.shared.fetchSources(for: project, context: context)

        guard !newArticles.isEmpty else {
            lastActivity = "No new articles from \(project.name)"
            FileLogger.shared.log("No new articles found")
            return
        }

        lastActivity = "Scoring \(newArticles.count) articles with AI..."
        FileLogger.shared.log("Scoring \(newArticles.count) articles with \(project.aiProvider)")

        // Score and categorize
        let result = await ViralityPredictor.shared.processNewArticles(
            newArticles,
            for: project,
            context: context
        )

        // Publish breaking news immediately
        for article in result.breaking {
            lastActivity = "BREAKING: \(article.title)"
            logger.info("BREAKING NEWS: \(article.title)")
            await ViralityPredictor.shared.generateAndPublishBreaking(
                article,
                for: project,
                context: context
            )
        }

        try? context.save()

        // Run cleanup every hour (was 6 hours — too infrequent, DB grows unbounded)
        if Date().timeIntervalSince(lastCleanup) > 3600 {
            lastCleanup = Date()
            // Use a separate short-lived context for cleanup to avoid bloating the crawl context
            let cleanupContext = ModelContext(container); cleanupContext.autosaveEnabled = false
            CacheManager.shared.performCleanup(context: cleanupContext)
        }

        // Flush WAL to main DB file to prevent data loss on standby/crash
        walCheckpoint()

        lastActivity = "Done: \(newArticles.count) new articles, \(result.breaking.count) breaking"
        FileLogger.shared.log("Crawl complete: \(newArticles.count) new, \(result.breaking.count) breaking")
    }

    private func runPublishCycle(for projectId: UUID, container: ModelContainer) async {
        let context = ModelContext(container); context.autosaveEnabled = false

        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectId }
        )
        guard let project = try? context.fetch(descriptor).first,
              project.isActive else {
            stopProject(projectId)
            return
        }

        lastActivity = "Publishing top article for \(project.name)..."
        FileLogger.shared.log("Publish cycle starting for \(project.name)")
        await ViralityPredictor.shared.publishTopFromQueue(for: project, context: context)
        lastActivity = "Published for \(project.name)"
    }

    private func startFeedbackLoop() {
        guard let container = modelContainer else { return }

        feedbackTimer = Timer.scheduledTimer(withTimeInterval: 7200, repeats: true) { _ in
            Task { @MainActor in
                let context = ModelContext(container); context.autosaveEnabled = false
                let descriptor = FetchDescriptor<Project>()
                guard let projects = try? context.fetch(descriptor) else { return }
                for project in projects where project.isActive {
                    await FeedbackCollector.shared.collectPerformance(
                        for: project,
                        context: context
                    )
                }
            }
        }
    }
}
