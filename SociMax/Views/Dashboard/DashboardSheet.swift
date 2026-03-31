import SwiftUI
import SwiftData

// MARK: - Dashboard Tabs

enum DashboardTab: String, CaseIterable {
    case history = "History"
    case queue = "Queue"
    case log = "Log"
}

// MARK: - Sort Options

enum PostSortField: String, CaseIterable {
    case time = "Time"
    case score = "Score"
    case views = "Views"
}

// MARK: - Main Dashboard Sheet

struct DashboardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Query(sort: \GeneratedPost.createdAt, order: .reverse) private var allPosts: [GeneratedPost]
    @State private var selectedProjectId: UUID?
    @State private var selectedTab: DashboardTab = .history
    @State private var sortField: PostSortField = .time
    @State private var sortAscending = false
    @State private var currentPage = 0
    @State private var expandedPostId: UUID?
    @State private var closeHover = false

    private let pageSize = 20

    private var filteredPosts: [GeneratedPost] {
        guard let id = selectedProjectId else { return allPosts }
        return allPosts.filter { $0.project?.id == id }
    }

    private var publishedPosts: [GeneratedPost] {
        sortPosts(filteredPosts.filter { $0.status == .published })
    }

    private var queuedPosts: [GeneratedPost] {
        sortPosts(filteredPosts.filter { $0.status == .queued })
    }

    private var publishedToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return filteredPosts.filter {
            $0.status == .published && ($0.publishedAt ?? .distantPast) >= start
        }.count
    }

    private var queuedCount: Int {
        filteredPosts.filter { $0.status == .queued }.count
    }

    private var videoCount: Int {
        filteredPosts.filter {
            $0.status == .published && $0.article?.source?.isYouTube == true
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Dashboard")
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.primaryText)

                if let name = projects.first(where: { $0.id == selectedProjectId })?.name {
                    Text("— \(name)")
                        .font(Theme.titleFont)
                        .foregroundStyle(Theme.tertiaryText)
                }

                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(closeHover ? Theme.primaryText : Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(Anim.fast) { closeHover = h } }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Project picker
            HStack {
                Picker("Project", selection: $selectedProjectId) {
                    Text("All Projects").tag(nil as UUID?)
                    ForEach(projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                .frame(width: 200)
                .tint(Theme.accentColor)
                .onChange(of: selectedProjectId) { _, _ in currentPage = 0 }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            // Stats cards
            HStack(spacing: 10) {
                StatCard(title: "Published", value: "\(publishedToday)", icon: "arrow.up.circle.fill", color: Theme.success)
                StatCard(title: "Queue", value: "\(queuedCount)", icon: "list.bullet", color: Theme.accentColor)
                StatCard(title: "Videos", value: "\(videoCount)", icon: "play.rectangle.fill", color: Theme.error)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            DarkDivider()

            // Tab picker
            TabSelector(selection: $selectedTab)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

            // Content
            switch selectedTab {
            case .history:
                historyTab
            case .queue:
                queueTab
            case .log:
                logTab
            }
        }
        .frame(width: 650, height: 520)
        .background(Theme.backgroundColor)
        .preferredColorScheme(.dark)
    }

    // MARK: - History Tab

    @ViewBuilder
    private var historyTab: some View {
        if publishedPosts.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.tertiaryText)
                Text("No Posts Yet")
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.secondaryText)
                Text("Published posts will appear here.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
        } else {
            VStack(spacing: 0) {
                sortableHeader

                DarkDivider()

                let pagedPosts = paginatedPosts(from: publishedPosts)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pagedPosts) { post in
                            postRow(post, showViews: true)
                            DarkDivider().padding(.horizontal, 12)
                        }
                    }
                }

                DarkDivider()

                paginationBar(total: publishedPosts.count)
            }
        }
    }

    // MARK: - Queue Tab

    @ViewBuilder
    private var queueTab: some View {
        if queuedPosts.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.tertiaryText)
                Text("Queue Empty")
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.secondaryText)
                Text("Articles waiting to be published will appear here.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queuedPosts) { post in
                        postRow(post, showViews: false)
                        DarkDivider().padding(.horizontal, 12)
                    }
                }
            }
        }
    }

    // MARK: - Log Tab

    @ViewBuilder
    private var logTab: some View {
        LogViewer()
    }

    // MARK: - Sortable Header

    @ViewBuilder
    private var sortableHeader: some View {
        HStack(spacing: 0) {
            sortButton("Time", field: .time, width: 60)
            sortButton("Post", field: .score, width: nil)
            sortButton("Score", field: .score, width: 55)
            sortButton("Views", field: .views, width: 55)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.secondaryText)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Theme.cardBackgroundColor)
    }

    @ViewBuilder
    private func sortButton(_ label: String, field: PostSortField, width: CGFloat?) -> some View {
        Button {
            if sortField == field {
                sortAscending.toggle()
            } else {
                sortField = field
                sortAscending = false
            }
            currentPage = 0
        } label: {
            HStack(spacing: 2) {
                Text(label)
                if sortField == field {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .leading)
        if width != nil {
            Spacer().frame(width: 0)
        } else {
            Spacer()
        }
    }

    // MARK: - Post Row

    @ViewBuilder
    private func postRow(_ post: GeneratedPost, showViews: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Anim.fast) {
                    expandedPostId = expandedPostId == post.id ? nil : post.id
                }
            } label: {
                HStack(spacing: 0) {
                    // Time
                    Group {
                        if let date = post.publishedAt ?? Optional(post.createdAt) {
                            Text(date, style: .time)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 60, alignment: .leading)

                    // Content preview
                    HStack(spacing: 6) {
                        if post.article?.source?.isYouTube == true {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.error)
                        }
                        Text(post.content)
                            .lineLimit(1)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.primaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Score
                    if let article = post.article {
                        Text(String(format: "%.1f", article.rawScore))
                            .font(Theme.captionFont)
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 55, alignment: .leading)
                    } else {
                        Text("-")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(width: 55, alignment: .leading)
                    }

                    // Views
                    if showViews {
                        if let perf = post.performance.last {
                            Text(formatViews(perf.views))
                                .font(Theme.captionFont)
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 55, alignment: .leading)
                        } else {
                            Text("-")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.tertiaryText)
                                .frame(width: 55, alignment: .leading)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded detail
            if expandedPostId == post.id {
                VStack(alignment: .leading, spacing: 6) {
                    Text(post.content)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.primaryText)
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        if let article = post.article {
                            Label("V: \(String(format: "%.1f", article.viralityScore))", systemImage: "flame")
                                .foregroundStyle(Theme.warning)
                            Label("R: \(String(format: "%.1f", article.relevanceScore))", systemImage: "target")
                                .foregroundStyle(Theme.accentColor)
                            if let source = article.source {
                                Label(source.name, systemImage: source.isYouTube ? "play.rectangle" : "globe")
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        if let date = post.publishedAt {
                            Text(date, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .font(.system(size: 10))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .background(expandedPostId == post.id ? Theme.accentColor.opacity(0.06) : .clear)
    }

    // MARK: - Pagination

    @ViewBuilder
    private func paginationBar(total: Int) -> some View {
        let totalPages = max(1, (total + pageSize - 1) / pageSize)
        HStack {
            Text("Showing \(currentPage * pageSize + 1)-\(min((currentPage + 1) * pageSize, total)) of \(total)")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
            Spacer()

            HoverButton(icon: "chevron.left", color: Theme.secondaryText) {
                currentPage = max(0, currentPage - 1)
            }

            Text("\(currentPage + 1)/\(totalPages)")
                .font(Theme.captionFont)
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)

            HoverButton(icon: "chevron.right", color: Theme.secondaryText) {
                currentPage = min(totalPages - 1, currentPage + 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func sortPosts(_ posts: [GeneratedPost]) -> [GeneratedPost] {
        posts.sorted { a, b in
            let result: Bool
            switch sortField {
            case .time:
                result = (a.publishedAt ?? a.createdAt) > (b.publishedAt ?? b.createdAt)
            case .score:
                result = (a.article?.rawScore ?? 0) > (b.article?.rawScore ?? 0)
            case .views:
                result = (a.performance.last?.views ?? 0) > (b.performance.last?.views ?? 0)
            }
            return sortAscending ? !result : result
        }
    }

    private func paginatedPosts(from posts: [GeneratedPost]) -> [GeneratedPost] {
        let start = currentPage * pageSize
        let end = min(start + pageSize, posts.count)
        guard start < posts.count else { return [] }
        return Array(posts[start..<end])
    }

    private func formatViews(_ views: Int) -> String {
        if views >= 1_000_000 { return String(format: "%.1fM", Double(views) / 1_000_000) }
        if views >= 1_000 { return String(format: "%.1fK", Double(views) / 1_000) }
        return "\(views)"
    }
}

// MARK: - Log Viewer

private struct LogViewer: View {
    @State private var logLines: [String] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Loading log...")
                    .tint(Theme.accentColor)
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            } else if logLines.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.tertiaryText)
                    Text("No Log Data")
                        .font(Theme.titleFont)
                        .foregroundStyle(Theme.secondaryText)
                    Text("Activity will appear here once automation starts.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logLines.indices.reversed(), id: \.self) { index in
                            Text(logLines[index])
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(colorForLine(logLines[index]))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                }

                DarkDivider()

                HStack {
                    Text("\(logLines.count) entries")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    HoverButton(icon: "arrow.clockwise", label: "Refresh", color: Theme.accentColor) {
                        loadLog()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .onAppear { loadLog() }
    }

    private func loadLog() {
        isLoading = true
        Task.detached {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let logURL = appSupport.appendingPathComponent("SociMax").appendingPathComponent("socimax.log")
            let lines: [String]
            if let data = try? Data(contentsOf: logURL),
               let text = String(data: data, encoding: .utf8) {
                let allLines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                lines = Array(allLines.suffix(500))
            } else {
                lines = []
            }
            await MainActor.run {
                logLines = lines
                isLoading = false
            }
        }
    }

    private func colorForLine(_ line: String) -> Color {
        if line.contains("ERROR") || line.contains("CRITICAL") || line.contains("Failed") { return Theme.error }
        if line.contains("published") || line.contains("Published") { return Theme.success }
        if line.contains("crawl") || line.contains("Crawl") { return Theme.warning }
        return Theme.primaryText
    }
}
