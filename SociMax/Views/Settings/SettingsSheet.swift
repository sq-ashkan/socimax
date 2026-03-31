import SwiftUI
import SwiftData
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Settings Tabs

enum SettingsSheetTab: String, CaseIterable {
    case projects = "Projects"
    case apiKeys = "API Keys"
    case general = "General"
}

// MARK: - Main Settings Sheet

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @State private var selectedTab: SettingsSheetTab = .projects
    @State private var selectedProject: Project?
    @State private var showingCreateProject = false
    @State private var importError: String?
    @State private var closeHover = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Settings")
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.primaryText)
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

            // Tab picker
            TabSelector(selection: $selectedTab)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            DarkDivider()

            // Content
            switch selectedTab {
            case .projects:
                ProjectsTab(
                    selectedProject: $selectedProject,
                    showingCreateProject: $showingCreateProject,
                    importError: $importError
                )
            case .apiKeys:
                APIKeysTab()
            case .general:
                GeneralTab()
            }
        }
        .frame(width: 620, height: 560)
        .background(Theme.backgroundColor)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingCreateProject) {
            CreateProjectSheet { project in
                modelContext.insert(project)
                selectedProject = project
            }
        }
    }
}

// MARK: - Projects Tab

private struct ProjectsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.createdAt) private var projects: [Project]
    @Binding var selectedProject: Project?
    @Binding var showingCreateProject: Bool
    @Binding var importError: String?

    var body: some View {
        if let project = selectedProject {
            ProjectDetailView(
                project: project,
                onBack: { selectedProject = nil },
                onDelete: {
                    modelContext.delete(project)
                    selectedProject = nil
                }
            )
        } else {
            projectList
        }
    }

    private var projectList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(projects) { project in
                    ProjectListCard(project: project) {
                        selectedProject = project
                    }
                }

                if let error = importError {
                    Text(error)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.error)
                        .padding(.top, 4)
                }

                HStack(spacing: 12) {
                    HoverButton(icon: "plus.circle.fill", label: "New Project", color: Theme.accentColor) {
                        showingCreateProject = true
                    }
                    HoverButton(icon: "square.and.arrow.down", label: "Import", color: Theme.secondaryText) {
                        importProject()
                    }
                }
                .padding(.top, 12)

                DarkDivider()
                    .padding(.vertical, 8)

                HStack(spacing: 12) {
                    HoverButton(icon: "square.and.arrow.up.on.square", label: "Export All", color: Theme.accentColor) {
                        exportAll()
                    }
                    HoverButton(icon: "square.and.arrow.down.on.square", label: "Import All", color: Theme.accentColor) {
                        importAll()
                    }
                }
            }
            .padding(20)
        }
    }

    private func importProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Select a SociMax project backup (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let (project, sources) = try ProjectExporter.importJSON(data: data)
            modelContext.insert(project)
            for source in sources {
                modelContext.insert(source)
            }
            selectedProject = project
            importError = nil
            FileLogger.shared.log("Imported project: \(project.name) with \(sources.count) sources")
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportAll() {
        do {
            let data = try ProjectExporter.exportAll(projects: projects)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "SociMax-Full-Backup.json"
            panel.message = "Export all projects, API keys & settings"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
            FileLogger.shared.log("Full export: \(projects.count) projects")
        } catch {
            FileLogger.shared.log("Full export failed: \(error)")
        }
    }

    private func importAll() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Select a SociMax full backup (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let result = try ProjectExporter.importAll(data: data)

            // Restore API keys
            if let keys = result.apiKeys {
                if let k = keys.openai, !k.isEmpty { KeychainService.shared.set(key: "openai_api_key", value: k) }
                if let k = keys.grok, !k.isEmpty { KeychainService.shared.set(key: "grok_api_key", value: k) }
                if let k = keys.claude, !k.isEmpty { KeychainService.shared.set(key: "claude_api_key", value: k) }
            }

            // Restore projects
            for (project, sources) in result.projects {
                modelContext.insert(project)
                for source in sources {
                    modelContext.insert(source)
                }
            }

            importError = nil
            FileLogger.shared.log("Full import: \(result.projects.count) projects + API keys restored")
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Project List Card

private struct ProjectListCard: View {
    let project: Project
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(project.isActive ? Theme.success : Theme.tertiaryText)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                    Text("\(project.sources.count) sources")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(isHovering ? Theme.cardBackgroundColor.opacity(1.2) : Theme.cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(isHovering ? Theme.accentColor.opacity(0.3) : Theme.borderColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Anim.fast) { isHovering = h } }
    }
}

// MARK: - Project Detail View (with accordion sections)

private struct ProjectDetailView: View {
    @Bindable var project: Project
    @Environment(\.modelContext) private var modelContext
    let onBack: () -> Void
    let onDelete: () -> Void

    // Accordion states
    @State private var profileExpanded = false
    @State private var sourcesExpanded = false
    @State private var youtubeExpanded = false
    @State private var scheduleExpanded = false
    @State private var telegramExpanded = false
    @State private var twitterExpanded = false
    @State private var twitterTesting = false
    @State private var twitterTestResult: Bool?
    @State private var showTwitterKeys = false
    @State private var linkedinExpanded = false
    @State private var linkedinTesting = false
    @State private var linkedinTestResult: Bool?
    @State private var showLinkedinKeys = false

    // Save state
    @State private var hasChanges = false
    @State private var isSaving = false
    @State private var showSaveSuccess = false

    // Refine state
    @State private var isRefining = false
    @State private var refineStatus: String?

    // Source add
    @State private var newSourceURL = ""
    @State private var newSourceType = "normal"
    @State private var newYoutubeChannelId = ""

    // Delete confirmation
    @State private var showDeleteConfirm = false
    @State private var backHover = false

    var body: some View {
        VStack(spacing: 0) {
            // Navigation header
            HStack {
                Button { onBack() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Projects")
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(backHover ? Theme.primaryText : Theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.buttonRadius)
                            .fill(backHover ? Theme.buttonHover : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(Anim.fast) { backHover = h } }

                Spacer()

                Toggle("Active", isOn: $project.isActive)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Theme.accentColor)
                    .onChange(of: project.isActive) { _, isActive in
                        hasChanges = true
                        // Save first so fresh ModelContexts in timer callbacks can find the project
                        try? modelContext.save()
                        if isActive {
                            AutomationScheduler.shared.startProject(project)
                        } else {
                            AutomationScheduler.shared.stopProject(project.id)
                        }
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            DarkDivider()

            // Scrollable content
            ScrollView {
                VStack(spacing: 10) {
                    // Project name
                    HStack {
                        TextField("Project Name", text: $project.name)
                            .darkTextField()
                            .font(.system(size: 14, weight: .semibold))
                            .onChange(of: project.name) { _, _ in hasChanges = true }
                    }
                    .padding(.bottom, 4)

                    // Channel Profile
                    AccordionSection(
                        title: "Channel Profile",
                        icon: "person.text.rectangle",
                        iconColor: Theme.accentColor,
                        isExpanded: $profileExpanded
                    ) {
                        channelProfileContent
                    }

                    // Web Sources
                    let webCount = project.sources.filter { !$0.isYouTube }.count
                    AccordionSection(
                        title: "Web Sources",
                        icon: "globe",
                        iconColor: .teal,
                        badge: "\(webCount)",
                        badgeColor: .teal,
                        isExpanded: $sourcesExpanded
                    ) {
                        webSourcesContent
                    }

                    // YouTube Sources
                    let ytCount = project.sources.filter(\.isYouTube).count
                    AccordionSection(
                        title: "YouTube Sources",
                        icon: "play.rectangle.fill",
                        iconColor: Theme.error,
                        badge: "\(ytCount)",
                        badgeColor: Theme.error,
                        isExpanded: $youtubeExpanded
                    ) {
                        youtubeSourcesContent
                    }

                    // Schedule & Thresholds
                    AccordionSection(
                        title: "Schedule & Thresholds",
                        icon: "clock.badge.checkmark",
                        iconColor: Theme.warning,
                        isExpanded: $scheduleExpanded
                    ) {
                        scheduleContent
                    }

                    // Telegram
                    AccordionSection(
                        title: "Telegram",
                        icon: "paperplane.fill",
                        iconColor: .cyan,
                        isExpanded: $telegramExpanded
                    ) {
                        telegramContent
                    }

                    // Twitter (X)
                    AccordionSection(
                        title: "Twitter (X)",
                        icon: "bird.fill",
                        iconColor: .blue,
                        isExpanded: $twitterExpanded
                    ) {
                        twitterContent
                    }

                    // LinkedIn
                    AccordionSection(
                        title: "LinkedIn",
                        icon: "link",
                        iconColor: .blue,
                        isExpanded: $linkedinExpanded
                    ) {
                        linkedinContent
                    }

                    // Actions
                    HStack(spacing: 8) {
                        HoverButton(icon: "square.and.arrow.up", label: "Export", color: Theme.secondaryText) {
                            exportProject()
                        }
                        HoverButton(icon: "doc.on.doc", label: "Duplicate", color: Theme.secondaryText) {
                            duplicateProject()
                        }
                        Spacer()
                        HoverButton(icon: "trash", label: "Delete", color: Theme.error) {
                            showDeleteConfirm = true
                        }
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }

            DarkDivider()

            // Save bar
            HStack {
                if let status = refineStatus {
                    Text(status)
                        .font(Theme.captionFont)
                        .foregroundStyle(status.contains("Done") ? Theme.success : Theme.warning)
                }
                Spacer()
                SaveButton(
                    hasChanges: hasChanges,
                    isSaving: isSaving,
                    showSuccess: showSaveSuccess,
                    action: saveChanges
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .alert("Delete Project?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This will permanently delete \"\(project.name)\" and all its data.")
        }
    }

    // MARK: - Channel Profile

    @ViewBuilder
    private var channelProfileContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Channel Description", text: $project.channelDescription, axis: .vertical)
                .darkTextField()
                .lineLimit(2...4)
                .onChange(of: project.channelDescription) { _, _ in hasChanges = true }

            TextField("Target Audience", text: $project.targetAudience, axis: .vertical)
                .darkTextField()
                .lineLimit(1...2)
                .onChange(of: project.targetAudience) { _, _ in hasChanges = true }

            TextField("Content Priorities", text: $project.contentPriorities, axis: .vertical)
                .darkTextField()
                .lineLimit(1...2)
                .onChange(of: project.contentPriorities) { _, _ in hasChanges = true }

            TextField("Tone & Style", text: $project.toneDescription, axis: .vertical)
                .darkTextField()
                .lineLimit(1...2)
                .onChange(of: project.toneDescription) { _, _ in hasChanges = true }

            TextField("Topics to Avoid", text: $project.avoidTopics, axis: .vertical)
                .darkTextField()
                .lineLimit(1...2)
                .onChange(of: project.avoidTopics) { _, _ in hasChanges = true }

            HStack(spacing: 12) {
                Picker("Language", selection: $project.postLanguage) {
                    ForEach(supportedLanguages, id: \.self) { lang in
                        Text(lang).tag(lang)
                    }
                }
                .frame(width: 220)
                .tint(Theme.accentColor)
                .onChange(of: project.postLanguage) { _, _ in hasChanges = true }

            }


            HStack {
                Button {
                    refineWithAI()
                } label: {
                    HStack(spacing: 4) {
                        if isRefining {
                            ProgressView().controlSize(.small).tint(Theme.accentColor)
                        }
                        Label(isRefining ? "Refining..." : "Refine with AI", systemImage: "sparkles")
                    }
                    .font(Theme.buttonFont)
                    .foregroundStyle(Theme.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.buttonRadius)
                            .fill(Theme.accentColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(project.channelDescription.isEmpty || isRefining)

                Spacer()
            }

            if !project.refinedPrompt.isEmpty {
                DisclosureGroup("Refined Prompt") {
                    Text(project.refinedPrompt)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                }
                .font(Theme.captionFont)
                .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: - Web Sources

    @ViewBuilder
    private var webSourcesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add URL...", text: $newSourceURL)
                    .darkTextField()
                    .onSubmit { addWebSource() }
                Picker("", selection: $newSourceType) {
                    Text("Normal").tag("normal")
                    Text("Priority").tag("priority")
                    Text("Unfiltered").tag("unfiltered")
                }
                .frame(width: 110)
                .controlSize(.small)
                .tint(Theme.accentColor)
                Button("Add") { addWebSource() }
                    .font(Theme.buttonFont)
                    .foregroundStyle(Theme.accentColor)
                    .disabled(newSourceURL.isEmpty)
            }

            let webSources = project.sources
                .filter { !$0.isYouTube }
                .sorted(by: { $0.createdAt < $1.createdAt })

            if webSources.isEmpty {
                Text("No web sources added yet.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                let grouped = Dictionary(grouping: webSources) { $0.sourceType }
                let typeOrder = ["normal", "priority", "unfiltered"]

                ForEach(typeOrder, id: \.self) { type in
                    if let sources = grouped[type], !sources.isEmpty {
                        sourceGroup(type: type, sources: sources)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sourceGroup(type: String, sources: [Source]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: type == "priority" ? "star.fill" : type == "unfiltered" ? "bolt.fill" : "globe")
                    .foregroundStyle(type == "priority" ? Theme.warning : type == "unfiltered" ? Theme.error : Theme.secondaryText)
                    .font(.system(size: 10))
                Text(type)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.secondaryText)
                Text("(\(sources.count))")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.top, 4)

            ForEach(sources) { source in
                HStack(spacing: 8) {
                    Text(source.name)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Spacer()
                    Button { deleteSource(source) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - YouTube Sources

    @ViewBuilder
    private var youtubeSourcesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("YouTube Channel ID", text: $newYoutubeChannelId)
                    .darkTextField()
                Button("Add") { addYoutubeSource() }
                    .font(Theme.buttonFont)
                    .foregroundStyle(Theme.accentColor)
                    .disabled(newYoutubeChannelId.isEmpty)
            }

            let ytSources = project.sources
                .filter(\.isYouTube)
                .sorted(by: { $0.createdAt < $1.createdAt })

            ForEach(ytSources) { source in
                YouTubeSourceRow(source: source, onDelete: { deleteSource(source) })
            }
        }
    }

    // MARK: - Schedule

    @ViewBuilder
    private var scheduleContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                scheduleRow("Crawl every", value: $project.crawlIntervalMinutes, suffix: "min")
            }

            DarkDivider()

            Text("Scoring")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            doubleRow("Min virality score (V)", value: $project.minPublishScore, range: 1...10)
            doubleRow("Min relevance score (R)", value: $project.minRelevanceScore, range: 1...10)
            doubleRow("Min YouTube score", value: $project.minYoutubeScore, range: 1...10)
            doubleRow("Breaking threshold", value: $project.breakingThreshold, range: 5...10)

            doubleRow("Decay factor", value: $project.decayFactor, range: 0.01...1.0)

            DarkDivider()

            Text("Deduplication")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            HStack {
                Text("Web dedup")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.primaryText)
                Slider(value: $project.dedupThreshold, in: 0.4...1.0, step: 0.05)
                    .tint(Theme.accentColor)
                    .onChange(of: project.dedupThreshold) { _, _ in hasChanges = true }
                Text("\(Int(project.dedupThreshold * 100))%")
                    .font(Theme.captionFont)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 35, alignment: .trailing)
            }

            HStack {
                Text("YouTube dedup")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.primaryText)
                Slider(value: $project.dedupYoutubeThreshold, in: 0.4...1.0, step: 0.05)
                    .tint(Theme.accentColor)
                    .onChange(of: project.dedupYoutubeThreshold) { _, _ in hasChanges = true }
                Text("\(Int(project.dedupYoutubeThreshold * 100))%")
                    .font(Theme.captionFont)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 35, alignment: .trailing)
            }

        }
    }

    @ViewBuilder
    private func scheduleRow(_ label: String, value: Binding<Int>, suffix: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.primaryText)
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inputBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderColor, lineWidth: 1))
                .frame(width: 55)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
                .onChange(of: value.wrappedValue) { _, _ in hasChanges = true }
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 25, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func doubleRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.primaryText)
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.inputBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderColor, lineWidth: 1))
                .frame(width: 55)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
                .onChange(of: value.wrappedValue) { _, _ in hasChanges = true }
        }
    }

    // MARK: - Telegram

    @ViewBuilder
    private var telegramContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField("Bot Token", text: $project.telegramBotToken)
                .darkTextField()
                .onChange(of: project.telegramBotToken) { _, newVal in
                    let cleaned = newVal.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                    if cleaned != newVal { project.telegramBotToken = cleaned }
                    hasChanges = true
                }

            TextField("Channel ID (e.g. @mychannel)", text: $project.telegramChannelId)
                .darkTextField()
                .onChange(of: project.telegramChannelId) { _, _ in hasChanges = true }

            DarkDivider()

            Text("Publish Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            scheduleRow("Publish every", value: $project.telegramPublishIntervalMinutes, suffix: "min")
            scheduleRow("Max posts/day", value: $project.telegramMaxPostsPerDay, suffix: "")

            Picker("Post length", selection: $project.telegramPostLength) {
                Text("Short").tag("short")
                Text("Medium").tag("medium")
                Text("Long").tag("long")
            }
            .frame(width: 200)
            .tint(Theme.accentColor)
            .onChange(of: project.telegramPostLength) { _, _ in hasChanges = true }

            Picker("Paragraph symbol", selection: $project.telegramSymbol) {
                Text("None").tag("none")
                Text("⭕️").tag("⭕️")
                Text("💠").tag("💠")
                Text("💢").tag("💢")
                Text("🟠").tag("🟠")
                Text("🫧").tag("🫧")
            }
            .frame(width: 200)
            .tint(Theme.accentColor)
            .onChange(of: project.telegramSymbol) { _, _ in hasChanges = true }

            Toggle("Show source link", isOn: $project.telegramShowSourceLink)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.telegramShowSourceLink) { _, _ in hasChanges = true }

            Toggle("Breaking news", isOn: $project.breakingTelegram)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.breakingTelegram) { _, _ in hasChanges = true }

            Toggle("Show channel ID", isOn: $project.telegramShowChannelTag)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.telegramShowChannelTag) { _, _ in hasChanges = true }

            Toggle("Require media", isOn: $project.requireMedia)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.requireMedia) { _, _ in hasChanges = true }

            Toggle("Show V/R scores", isOn: $project.telegramShowScores)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.telegramShowScores) { _, _ in hasChanges = true }
        }
    }

    // MARK: - Twitter (X)

    @ViewBuilder
    private var twitterContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable Twitter", isOn: $project.twitterEnabled)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.twitterEnabled) { _, _ in hasChanges = true }

            twitterKeyField("API Key", text: $project.twitterApiKey)
            twitterKeyField("API Key Secret", text: $project.twitterApiSecret)
            twitterKeyField("Access Token", text: $project.twitterAccessToken)
            twitterKeyField("Access Token Secret", text: $project.twitterAccessTokenSecret)

            HStack(spacing: 4) {
                Image(systemName: showTwitterKeys ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 10))
                Text(showTwitterKeys ? "Hide keys" : "Show keys")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Theme.secondaryText)
            .onTapGesture { showTwitterKeys.toggle() }

            HStack {
                HoverButton(
                    icon: "bolt.fill",
                    label: twitterTesting ? "Testing..." : "Test Connection",
                    color: Theme.accentColor
                ) {
                    testTwitterConnection()
                }
                .disabled(twitterTesting || project.twitterApiKey.isEmpty)

                if let result = twitterTestResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : Theme.error)
                }
            }

            DarkDivider()

            Text("Publish Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            scheduleRow("Publish every", value: $project.twitterPublishIntervalMinutes, suffix: "min")
            scheduleRow("Max posts/day", value: $project.twitterMaxPostsPerDay, suffix: "")
            doubleRow("Max post age", value: $project.twitterMaxAgeHours, range: 1...168)

            Picker("Post length", selection: $project.twitterPostLength) {
                Text("Short").tag("short")
                Text("Medium").tag("medium")
                Text("Long").tag("long")
            }
            .frame(width: 200)
            .tint(Theme.accentColor)
            .onChange(of: project.twitterPostLength) { _, _ in hasChanges = true }

            TextField("Handle (e.g. @myaccount)", text: $project.twitterHandle)
                .darkTextField()
                .onChange(of: project.twitterHandle) { _, _ in hasChanges = true }

            Picker("Paragraph symbol", selection: $project.twitterSymbol) {
                Text("None").tag("none")
                Text("⭕️").tag("⭕️")
                Text("💠").tag("💠")
                Text("💢").tag("💢")
                Text("🟠").tag("🟠")
                Text("🫧").tag("🫧")
            }
            .frame(width: 200)
            .tint(Theme.accentColor)
            .onChange(of: project.twitterSymbol) { _, _ in hasChanges = true }

            Toggle("Breaking news", isOn: $project.breakingTwitter)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.breakingTwitter) { _, _ in hasChanges = true }

            Toggle("Show source link", isOn: $project.twitterShowSourceLink)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.twitterShowSourceLink) { _, _ in hasChanges = true }

            Toggle("Source link as reply", isOn: $project.twitterSourceAsReply)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.twitterSourceAsReply) { _, _ in hasChanges = true }

            Toggle("Require media", isOn: $project.twitterRequireImage)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.twitterRequireImage) { _, _ in hasChanges = true }

            Toggle("Show handle", isOn: $project.twitterShowHandle)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.twitterShowHandle) { _, _ in hasChanges = true }

            Toggle("Show V/R scores", isOn: $project.twitterShowScores)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.twitterShowScores) { _, _ in hasChanges = true }
        }
    }

    @ViewBuilder
    private func twitterKeyField(_ placeholder: String, text: Binding<String>) -> some View {
        Group {
            if showTwitterKeys {
                TextField(placeholder, text: text)
            } else {
                SecureField(placeholder, text: text)
            }
        }
        .darkTextField()
        .onChange(of: text.wrappedValue) { oldVal, newVal in
            // Strip newlines from paste
            let cleaned = newVal.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            if cleaned != newVal {
                text.wrappedValue = cleaned
            }
            hasChanges = true
        }
    }

    private func testTwitterConnection() {
        twitterTesting = true
        twitterTestResult = nil
        Task {
            let result = await TwitterService.shared.testConnection(
                apiKey: project.twitterApiKey,
                apiSecret: project.twitterApiSecret,
                accessToken: project.twitterAccessToken,
                accessTokenSecret: project.twitterAccessTokenSecret
            )
            twitterTesting = false
            twitterTestResult = result
        }
    }

    // MARK: - LinkedIn

    @ViewBuilder
    private var linkedinContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable LinkedIn", isOn: $project.linkedinEnabled)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.linkedinEnabled) { _, _ in hasChanges = true }

            linkedinKeyField("Access Token", text: $project.linkedinAccessToken)
            TextField("Person ID", text: $project.linkedinPersonId)
                .darkTextField()
                .onChange(of: project.linkedinPersonId) { _, _ in hasChanges = true }

            HStack(spacing: 4) {
                Image(systemName: showLinkedinKeys ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 10))
                Text(showLinkedinKeys ? "Hide keys" : "Show keys")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Theme.secondaryText)
            .onTapGesture { showLinkedinKeys.toggle() }

            HStack {
                HoverButton(
                    icon: "bolt.fill",
                    label: linkedinTesting ? "Testing..." : "Test Connection",
                    color: Theme.accentColor
                ) {
                    testLinkedinConnection()
                }
                .disabled(linkedinTesting || project.linkedinAccessToken.isEmpty)

                if let result = linkedinTestResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : Theme.error)
                }
            }

            DarkDivider()

            Text("Publish Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            scheduleRow("Publish every", value: $project.linkedinPublishIntervalMinutes, suffix: "min")
            scheduleRow("Max posts/day", value: $project.linkedinMaxPostsPerDay, suffix: "")
            doubleRow("Max post age", value: $project.linkedinMaxAgeHours, range: 1...168)

            Picker("Post length", selection: $project.linkedinPostLength) {
                Text("Short").tag("short")
                Text("Medium").tag("medium")
                Text("Long").tag("long")
            }
            .frame(width: 200)
            .tint(Theme.accentColor)
            .onChange(of: project.linkedinPostLength) { _, _ in hasChanges = true }

            TextField("Handle (e.g. @myaccount)", text: $project.linkedinHandle)
                .darkTextField()
                .onChange(of: project.linkedinHandle) { _, _ in hasChanges = true }

            Picker("Paragraph symbol", selection: $project.linkedinSymbol) {
                Text("None").tag("none")
                Text("⭕️").tag("⭕️")
                Text("💠").tag("💠")
                Text("💢").tag("💢")
                Text("🟠").tag("🟠")
                Text("🫧").tag("🫧")
            }
            .frame(width: 200)
            .tint(Theme.accentColor)
            .onChange(of: project.linkedinSymbol) { _, _ in hasChanges = true }

            Toggle("Breaking news", isOn: $project.breakingLinkedin)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.breakingLinkedin) { _, _ in hasChanges = true }

            Toggle("Show source link", isOn: $project.linkedinShowSourceLink)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.linkedinShowSourceLink) { _, _ in hasChanges = true }

            Toggle("Source link as comment", isOn: $project.linkedinSourceAsComment)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.linkedinSourceAsComment) { _, _ in hasChanges = true }

            Toggle("Require media", isOn: $project.linkedinRequireImage)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.linkedinRequireImage) { _, _ in hasChanges = true }

            Toggle("Show handle", isOn: $project.linkedinShowHandle)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.linkedinShowHandle) { _, _ in hasChanges = true }

            Toggle("Show V/R scores", isOn: $project.linkedinShowScores)
                .font(Theme.captionFont)
                .tint(Theme.accentColor)
                .foregroundStyle(Theme.primaryText)
                .onChange(of: project.linkedinShowScores) { _, _ in hasChanges = true }
        }
    }

    @ViewBuilder
    private func linkedinKeyField(_ placeholder: String, text: Binding<String>) -> some View {
        Group {
            if showLinkedinKeys {
                TextField(placeholder, text: text)
            } else {
                SecureField(placeholder, text: text)
            }
        }
        .darkTextField()
        .onChange(of: text.wrappedValue) { oldVal, newVal in
            let cleaned = newVal.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            if cleaned != newVal {
                text.wrappedValue = cleaned
            }
            hasChanges = true
        }
    }

    private func testLinkedinConnection() {
        linkedinTesting = true
        linkedinTestResult = nil
        Task {
            let result = await LinkedInService.shared.testConnection(
                accessToken: project.linkedinAccessToken,
                personId: project.linkedinPersonId
            )
            linkedinTesting = false
            linkedinTestResult = result
        }
    }

    // MARK: - Actions

    private func saveChanges() {
        isSaving = true
        do {
            try modelContext.save()
            // Restart project timers so new settings (e.g. Twitter) take effect
            if project.isActive {
                AutomationScheduler.shared.startProject(project)
            }
            isSaving = false
            showSaveSuccess = true
            hasChanges = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showSaveSuccess = false
            }
        } catch {
            isSaving = false
            FileLogger.shared.log("Save failed: \(error)")
        }
    }

    private func addWebSource() {
        let url = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let normalizedURL = url.hasPrefix("http") ? url : "https://\(url)"
        let source = Source(url: normalizedURL, sourceType: newSourceType)
        source.project = project
        modelContext.insert(source)
        newSourceURL = ""
        newSourceType = "normal"
        hasChanges = true
    }

    private func addYoutubeSource() {
        let channelId = newYoutubeChannelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelId.isEmpty else { return }
        let source = Source(url: "https://www.youtube.com/channel/\(channelId)", name: "YT: \(channelId)")
        source.youtubeChannelId = channelId
        source.project = project
        modelContext.insert(source)
        newYoutubeChannelId = ""
        hasChanges = true
    }

    private func deleteSource(_ source: Source) {
        modelContext.delete(source)
        hasChanges = true
    }

    private func exportProject() {
        do {
            let data = try ProjectExporter.exportJSON(project: project)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(project.name).json"
            panel.message = "Export project backup"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
            FileLogger.shared.log("Exported project: \(project.name)")
        } catch {
            FileLogger.shared.log("Export failed: \(error)")
        }
    }

    private func duplicateProject() {
        let copy = Project(
            name: "\(project.name) (Copy)",
            channelDescription: project.channelDescription,
            targetAudience: project.targetAudience,
            contentPriorities: project.contentPriorities,
            toneDescription: project.toneDescription,
            avoidTopics: project.avoidTopics,
            refinedPrompt: project.refinedPrompt,
            aiProvider: project.aiProvider,
            telegramBotToken: project.telegramBotToken,
            telegramChannelId: project.telegramChannelId,
            crawlIntervalMinutes: project.crawlIntervalMinutes,
            publishIntervalMinutes: project.publishIntervalMinutes,
            maxPostsPerDay: project.maxPostsPerDay,
            breakingThreshold: project.breakingThreshold,
            decayFactor: project.decayFactor,
            maxQueueAgeHours: project.maxQueueAgeHours,
            minPublishScore: project.minPublishScore,
            minRelevanceScore: project.minRelevanceScore,
            minYoutubeScore: project.minYoutubeScore,
            dedupThreshold: project.dedupThreshold,
            dedupYoutubeThreshold: project.dedupYoutubeThreshold,
            requireMedia: project.requireMedia,
            useSymbolFormat: project.useSymbolFormat,
            postLanguage: project.postLanguage
        )
        copy.postLength = project.postLength
        copy.telegramSymbol = project.telegramSymbol
        copy.twitterSymbol = project.twitterSymbol
        copy.telegramShowSourceLink = project.telegramShowSourceLink
        copy.twitterSourceAsReply = project.twitterSourceAsReply
        copy.twitterRequireImage = project.twitterRequireImage
        modelContext.insert(copy)
        // Copy sources
        for source in project.sources {
            let s = Source(url: source.url, name: source.name, sourceType: source.sourceType)
            s.youtubeChannelId = source.youtubeChannelId
            s.youtubeFilter = source.youtubeFilter
            s.refinedYoutubeFilter = source.refinedYoutubeFilter
            s.youtubeDescription = source.youtubeDescription
            s.refinedYoutubeDescription = source.refinedYoutubeDescription
            s.project = copy
            modelContext.insert(s)
        }
    }

    private func refineWithAI() {
        isRefining = true
        refineStatus = "Refining..."
        let provider = AIProviderFactory.provider(for: project)
        Task {
            do {
                let refined = try await provider.refineChannelProfile(
                    description: project.channelDescription,
                    audience: project.targetAudience,
                    priorities: project.contentPriorities,
                    tone: project.toneDescription,
                    avoid: project.avoidTopics
                )
                await MainActor.run {
                    project.refinedPrompt = refined
                    isRefining = false
                    refineStatus = "Done!"
                    hasChanges = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        refineStatus = nil
                    }
                }
            } catch {
                await MainActor.run {
                    isRefining = false
                    refineStatus = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - YouTube Source Row

private struct YouTubeSourceRow: View {
    @Bindable var source: Source
    let onDelete: () -> Void
    @State private var isRefining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(Theme.error)
                    .font(Theme.captionFont)
                Text(source.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button { onDelete() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.borderless)
            }

            HStack {
                TextField("What do you want from this channel?", text: $source.youtubeDescription)
                    .darkTextField()

                Button {
                    refineYoutubeSource()
                } label: {
                    HStack(spacing: 3) {
                        if isRefining {
                            ProgressView().controlSize(.mini).tint(Theme.accentColor)
                        }
                        Text(isRefining ? "..." : "Refine")
                    }
                    .font(Theme.buttonFont)
                    .foregroundStyle(Theme.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.accentColor.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(source.youtubeDescription.isEmpty || isRefining)
            }

            if !source.refinedYoutubeFilter.isEmpty {
                Text("Filter: \(source.refinedYoutubeFilter)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
            }
            if !source.refinedYoutubeDescription.isEmpty {
                Text("Scoring: \(source.refinedYoutubeDescription)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .fill(Theme.inputBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.buttonRadius)
                .strokeBorder(Theme.borderColor, lineWidth: 1)
        )
    }

    private func refineYoutubeSource() {
        let desc = source.youtubeDescription
        let key = GrokService.shared.apiKey
        isRefining = true
        Task {
            do {
                struct Msg: Decodable { let content: String }
                struct Choice: Decodable { let message: Msg }
                struct Resp: Decodable { let choices: [Choice] }
                let response: Resp = try await NetworkClient.shared.postJSON(
                    url: "https://api.x.ai/v1/chat/completions",
                    headers: ["Authorization": "Bearer \(key)"],
                    body: [
                        "model": "grok-3-mini",
                        "messages": [
                            ["role": "user", "content": """
                            From this YouTube channel description, generate exactly 2 lines:
                            LINE 1: max 10 lowercase filter keywords, comma-separated
                            LINE 2: 1-2 sentence scoring hint for AI (max 30 words)
                            Input: \(desc)
                            """]
                        ],
                        "max_tokens": 100
                    ]
                )
                let result = response.choices.first?.message.content ?? ""
                let lines = result.components(separatedBy: .newlines).filter { !$0.isEmpty }
                await MainActor.run {
                    isRefining = false
                    if lines.count >= 2 {
                        source.refinedYoutubeFilter = lines[0].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        source.refinedYoutubeDescription = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if lines.count == 1 {
                        source.refinedYoutubeFilter = lines[0].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        source.refinedYoutubeDescription = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    FileLogger.shared.log("YT refined — filter: \(source.refinedYoutubeFilter) | scoring: \(source.refinedYoutubeDescription)")
                }
            } catch {
                await MainActor.run {
                    isRefining = false
                }
                FileLogger.shared.log("YT refine failed: \(error)")
            }
        }
    }
}

// MARK: - Create Project Sheet

struct CreateProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var channelDescription = ""
    @State private var telegramBotToken = ""
    @State private var telegramChannelId = ""

    var onCreate: (Project) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(Theme.titleFont)
                .foregroundStyle(Theme.primaryText)

            TextField("Project Name", text: $name)
                .darkTextField()

            TextField("Channel Description (any language)", text: $channelDescription, axis: .vertical)
                .darkTextField()
                .lineLimit(3...6)

            VStack(alignment: .leading, spacing: 8) {
                Text("Telegram (optional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)

                SecureField("Bot Token", text: $telegramBotToken)
                    .darkTextField()
                TextField("Channel ID (e.g. @mychannel)", text: $telegramChannelId)
                    .darkTextField()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(Theme.cardBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.borderColor, lineWidth: 1)
            )

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(Theme.buttonFont)
                    .foregroundStyle(Theme.secondaryText)
                    .keyboardShortcut(.cancelAction)

                Button("Create") {
                    let project = Project(
                        name: name,
                        channelDescription: channelDescription,
                        telegramBotToken: telegramBotToken,
                        telegramChannelId: telegramChannelId
                    )
                    onCreate(project)
                    dismiss()
                }
                .font(Theme.buttonFont)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.buttonRadius)
                        .fill(name.isEmpty ? AnyShapeStyle(Theme.cardBackgroundColor) : AnyShapeStyle(Theme.accentGradient))
                )
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .background(Theme.backgroundColor)
        .preferredColorScheme(.dark)
    }
}

// MARK: - API Keys Tab

private struct APIKeysTab: View {
    @State private var grokAPIKey = ""
    @State private var openaiAPIKey = ""
    @State private var grokStatus: String?
    @State private var openaiStatus: String?
    @State private var isTesting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                apiKeyCard(
                    name: "OpenAI",
                    subtitle: "GPT-4.1-mini — best quality/price ratio",
                    color: Theme.success,
                    icon: "brain",
                    key: $openaiAPIKey,
                    status: $openaiStatus,
                    keychainKey: "openai_api_key",
                    providerName: "openai",
                    getKeyURL: "https://platform.openai.com/api-keys"
                )

                apiKeyCard(
                    name: "Grok (xAI)",
                    subtitle: "grok-3-mini",
                    color: Theme.accentColor,
                    icon: "sparkle",
                    key: $grokAPIKey,
                    status: $grokStatus,
                    keychainKey: "grok_api_key",
                    providerName: "grok",
                    getKeyURL: nil
                )

                Text("API keys are encrypted and stored locally.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .onAppear {
            grokAPIKey = KeychainService.shared.get(key: "grok_api_key") ?? ""
            openaiAPIKey = KeychainService.shared.get(key: "openai_api_key") ?? ""
        }
    }

    @ViewBuilder
    private func apiKeyCard(
        name: String,
        subtitle: String,
        color: Color,
        icon: String,
        key: Binding<String>,
        status: Binding<String?>,
        keychainKey: String,
        providerName: String,
        getKeyURL: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }

            SecureField("API Key", text: key)
                .darkTextField()

            HStack(spacing: 10) {
                HoverButton(icon: "checkmark.circle", label: "Save", color: Theme.success) {
                    KeychainService.shared.set(key: keychainKey, value: key.wrappedValue)
                    status.wrappedValue = "Saved"
                }

                HoverButton(icon: "antenna.radiowaves.left.and.right", label: "Test", color: Theme.accentColor) {
                    testProvider(providerName, status: status)
                }

                if let url = getKeyURL {
                    Link(destination: URL(string: url)!) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right")
                            Text("Get Key")
                        }
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                }

                Spacer()

                if let s = status.wrappedValue {
                    Text(s)
                        .font(Theme.captionFont)
                        .foregroundStyle(
                            s.contains("Success") ? Theme.success :
                            s.contains("Saved") ? Theme.accentColor : Theme.error
                        )
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .strokeBorder(Theme.borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    private func testProvider(_ name: String, status: Binding<String?>) {
        isTesting = true
        status.wrappedValue = "Testing..."
        let provider = AIProviderFactory.provider(named: name)
        Task {
            let result = await provider.testConnection()
            await MainActor.run {
                isTesting = false
                status.wrappedValue = result ? "Success! Connected." : "Failed. Check your API key."
            }
        }
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showNotifications") private var showNotifications = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "sunrise")
                            .foregroundStyle(Theme.warning)
                        Text("Startup")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.primaryText)
                    }
                    Toggle("Launch at Login", isOn: $launchAtLogin)
                        .font(Theme.captionFont)
                        .tint(Theme.accentColor)
                        .foregroundStyle(Theme.primaryText)
                        .onChange(of: launchAtLogin) { _, newValue in
                            setLaunchAtLogin(newValue)
                        }
                }
                .darkCard()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "bell.badge")
                            .foregroundStyle(Theme.accentColor)
                        Text("Notifications")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.primaryText)
                    }
                    Toggle("Show notifications for published posts", isOn: $showNotifications)
                        .font(Theme.captionFont)
                        .tint(Theme.accentColor)
                        .foregroundStyle(Theme.primaryText)
                }
                .darkCard()

                VStack(alignment: .leading, spacing: 4) {
                    Text("SociMax v1.0.0")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                    Text("AI-Powered Social Media Automation")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.secondaryText)
                }
                .darkCard()
            }
            .padding(20)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileLogger.shared.log("Launch at login error: \(error)")
        }
    }
}
