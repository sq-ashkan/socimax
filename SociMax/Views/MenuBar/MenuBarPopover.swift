import SwiftUI
import SwiftData

struct MenuBarPopover: View {
    @Query(sort: \GeneratedPost.publishedAt, order: .reverse)
    private var recentPosts: [GeneratedPost]
    @Query private var projects: [Project]
    @ObservedObject private var scheduler = AutomationScheduler.shared

    @State private var showSettings = false
    @State private var showDashboard = false
    @State private var selectedProjectId: UUID?
    @State private var settingsHover = false
    @State private var dashboardHover = false
    @State private var closeHover = false
    @State private var pulseRunning = false

    // Computed stats
    private var activeProject: Project? {
        if let id = selectedProjectId { return projects.first { $0.id == id } }
        return projects.first(where: \.isActive) ?? projects.first
    }

    private var projectPosts: [GeneratedPost] {
        guard let id = activeProject?.id else { return recentPosts }
        return recentPosts.filter { $0.project?.id == id }
    }

    private var todayPublished: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return projectPosts.filter {
            $0.status == .published && ($0.publishedAt ?? .distantPast) >= start
        }.count
    }

    private var queueCount: Int {
        projectPosts.filter { $0.status == .queued }.count
    }

    private var videoCount: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return projectPosts.filter {
            $0.status == .published &&
            ($0.publishedAt ?? .distantPast) >= start &&
            $0.article?.source?.isYouTube == true
        }.count
    }

    private var recentPublished: [GeneratedPost] {
        Array(projectPosts.filter { $0.status == .published }.prefix(5))
    }

    private var nextPublishText: String {
        guard let project = activeProject, project.isActive else { return "---" }
        return "\(project.telegramPublishIntervalMinutes)m"
    }

    var body: some View {
        ZStack {
            VisualEffectBackground()

            VStack(spacing: 0) {
                // Header
                header

                DarkDivider()

                if projects.isEmpty {
                    emptyState
                } else {
                    mainContent
                }

                DarkDivider()

                // Action bar
                actionBar
            }
        }
        .frame(width: 420)
        .clipShape(RoundedRectangle(cornerRadius: Theme.popoverRadius))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: $showDashboard) {
            DashboardSheet()
        }
        .onAppear {
            if selectedProjectId == nil {
                selectedProjectId = (projects.first(where: \.isActive) ?? projects.first)?.id
            }
            if scheduler.isRunning {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseRunning = true
                }
            }
        }
        .onChange(of: scheduler.isRunning) { _, running in
            if running {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseRunning = true
                }
            } else {
                pulseRunning = false
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.accentColor)
            Text("SociMax v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(Theme.titleFont)
                .foregroundStyle(Theme.primaryText)

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.subheadline)
                    .foregroundStyle(settingsHover ? Theme.primaryText : Theme.secondaryText)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(settingsHover ? Theme.buttonHover : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(Anim.fast) { settingsHover = h } }

            Button { showDashboard = true } label: {
                Image(systemName: "chart.bar.fill")
                    .font(.subheadline)
                    .foregroundStyle(dashboardHover ? Theme.primaryText : Theme.secondaryText)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(dashboardHover ? Theme.buttonHover : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(Anim.fast) { dashboardHover = h } }

            Button { closePanel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(closeHover ? Theme.primaryText : Theme.tertiaryText)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(closeHover ? Theme.error.opacity(0.3) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { h in withAnimation(Anim.fast) { closeHover = h } }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)

        // Project picker + status
        HStack(spacing: 8) {
            if projects.count > 1 {
                Picker("", selection: $selectedProjectId) {
                    ForEach(projects) { project in
                        Text(project.name).tag(project.id as UUID?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .controlSize(.small)
                .tint(Theme.accentColor)
            } else if let project = projects.first {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
            }

            HStack(spacing: 5) {
                ZStack {
                    if scheduler.isRunning {
                        Circle()
                            .fill(Theme.success.opacity(0.3))
                            .frame(width: 14, height: 14)
                            .scaleEffect(pulseRunning ? 1.3 : 1.0)
                    }
                    Circle()
                        .fill(scheduler.isRunning ? Theme.success : Theme.tertiaryText)
                        .frame(width: 8, height: 8)
                }
                Text(scheduler.isRunning ? "Running" : "Paused")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(Theme.tertiaryText)
            Text("No projects yet")
                .font(Theme.bodyFont)
                .foregroundStyle(Theme.secondaryText)
            Button("Create Project") {
                showSettings = true
            }
            .font(Theme.buttonFont)
            .foregroundStyle(Theme.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 10) {
            // Stats row
            HStack(spacing: 8) {
                miniStat(icon: "arrow.up.circle.fill", value: "\(todayPublished)", label: "Published", color: Theme.success)
                miniStat(icon: "list.bullet", value: "\(queueCount)", label: "Queue", color: Theme.accentColor)
                miniStat(icon: "play.rectangle.fill", value: "\(videoCount)", label: "Videos", color: Theme.error)
                miniStat(icon: "clock", value: nextPublishText, label: "Interval", color: Theme.warning)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            // Last activity
            if !scheduler.lastActivity.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                    Text(scheduler.lastActivity)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
            }

            // Recent posts
            if recentPublished.isEmpty {
                Text("No posts published yet")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentPublished) { post in
                        recentPostRow(post)
                        if post.id != recentPublished.last?.id {
                            DarkDivider()
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Mini Stat

    @ViewBuilder
    private func miniStat(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.primaryText)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .strokeBorder(Theme.borderColor, lineWidth: 0.5)
        )
    }

    // MARK: - Recent Post Row

    @ViewBuilder
    private func recentPostRow(_ post: GeneratedPost) -> some View {
        HStack(spacing: 8) {
            if post.article?.source?.isYouTube == true {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.error)
            }
            Text(post.content)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let date = post.publishedAt {
                Text(date, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    // MARK: - Action Bar

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 8) {
            HoverButton(
                icon: scheduler.isRunning ? "pause.fill" : "play.fill",
                label: scheduler.isRunning ? "Pause" : "Start",
                color: scheduler.isRunning ? Theme.warning : Theme.success
            ) {
                toggleAutomation()
            }

            HoverButton(
                icon: "arrow.clockwise",
                label: "Crawl Now",
                color: Theme.accentColor
            ) {
                triggerCrawl()
            }

            Spacer()

            HoverButton(
                icon: "power",
                label: "Quit",
                color: Theme.tertiaryText
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func toggleAutomation() {
        if scheduler.isRunning {
            AutomationScheduler.shared.stopAll()
        } else {
            AutomationScheduler.shared.configure(with: sharedModelContainer)
            // Use fresh context to ensure we get latest projects
            let context = ModelContext(sharedModelContainer)
            let descriptor = FetchDescriptor<Project>()
            let allProjects = (try? context.fetch(descriptor)) ?? []
            let activeProjects = allProjects.filter(\.isActive)
            guard !activeProjects.isEmpty else { return }
            AutomationScheduler.shared.startAll(projects: activeProjects)
        }
    }

    private func triggerCrawl() {
        guard let project = activeProject else { return }
        Task {
            await AutomationScheduler.shared.triggerCrawl(for: project)
        }
    }

    private func closePanel() {
        NSApp.keyWindow?.close()
    }
}
