import SwiftUI
import SwiftData
import SQLite3
import ServiceManagement

let sharedModelContainer: ModelContainer = {
    let schema = Schema([
        Project.self,
        Source.self,
        FetchedArticle.self,
        GeneratedPost.self,
        PostPerformance.self
    ])
    let fm = FileManager.default
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let storeURL = appSupport.appendingPathComponent("SociMax.store")

    func criticalLog(_ msg: String) {
        let logDir = appSupport.appendingPathComponent("SociMax")
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("socimax.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    let config = ModelConfiguration(
        "SociMax",
        schema: schema,
        isStoredInMemoryOnly: false
    )

    // Try to open database
    do {
        return try ModelContainer(for: schema, configurations: [config])
    } catch {
        criticalLog("[DB] Failed to open: \(error) — deleting and creating fresh")
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(atPath: storeURL.path + suffix)
        }
    }

    do {
        return try ModelContainer(for: schema, configurations: [config])
    } catch {
        fatalError("Could not create ModelContainer: \(error)")
    }
}()

/// Force WAL checkpoint so all data is flushed to the main DB file
func walCheckpoint() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let storePath = appSupport.appendingPathComponent("SociMax.store").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(storePath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    FileLogger.shared.log("WAL checkpoint completed")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var onboardingWindow: NSWindow?

    private var walTimer: Timer?
    private var backupTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileLogger.shared.log("App launched!")

        // Catch CoreData/SwiftData faults that would otherwise crash the app
        NSSetUncaughtExceptionHandler { exception in
            FileLogger.shared.log("[CRASH] Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "no reason")")
            FileLogger.shared.log("[CRASH] Stack: \(exception.callStackSymbols.prefix(10).joined(separator: "\n"))")
            walCheckpoint()
        }

        // Auto-enable launch at login on first run
        if !UserDefaults.standard.bool(forKey: "didSetupLaunchAtLogin") {
            UserDefaults.standard.set(true, forKey: "didSetupLaunchAtLogin")
            UserDefaults.standard.set(true, forKey: "launchAtLogin")
        }

        // Always re-register on every launch (new app versions invalidate the old registration)
        if UserDefaults.standard.bool(forKey: "launchAtLogin") {
            let status = SMAppService.mainApp.status
            if status != .enabled {
                try? SMAppService.mainApp.register()
                FileLogger.shared.log("Launch at login re-registered (was: \(status))")
            }
        }

        // Periodic WAL checkpoint every 5 minutes to prevent data loss on crash
        startWALTimer()

        // Backup database to Desktop every 10 minutes
        startBackupTimer()

        // Stop WAL timer before sleep, restart after wake
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.walTimer?.invalidate()
            self?.walTimer = nil
            walCheckpoint()
            FileLogger.shared.log("WAL timer stopped before sleep")
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.startWALTimer()
            FileLogger.shared.log("WAL timer restarted after wake")
        }

        // Status bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
        }

        // Floating panel
        let panel = FloatingPanel()
        let rootView = MenuBarPopover()
            .modelContainer(sharedModelContainer)
        let hostingView = NSHostingView(rootView: rootView)
        panel.contentView = hostingView
        self.panel = panel

        // Check onboarding
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            showOnboarding()
        }

        // Flush WAL before anything else — ensures data consistency after crash/restart
        walCheckpoint()

        // Start automation
        Task { @MainActor in
            AutomationScheduler.shared.configure(with: sharedModelContainer)
            let context = ModelContext(sharedModelContainer)
            let descriptor = FetchDescriptor<Project>()
            if let projects = try? context.fetch(descriptor) {
                let activeProjects = projects.filter(\.isActive)
                FileLogger.shared.log("Found \(projects.count) projects, \(activeProjects.count) active")
                if !activeProjects.isEmpty {
                    AutomationScheduler.shared.startAll(projects: activeProjects)
                    FileLogger.shared.log("Automation started!")
                } else {
                    FileLogger.shared.log("No active projects")
                }
            } else {
                FileLogger.shared.log("Failed to fetch projects")
            }
        }
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            // Show the main panel
            if let button = self.statusItem?.button {
                self.panel?.positionNear(statusBarButton: button)
            }
            self.panel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Theme.backgroundColor)
        window.center()
        window.contentView = NSHostingView(rootView: onboardingView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.onboardingWindow = window
    }

    private func startWALTimer() {
        walTimer?.invalidate()
        walTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            walCheckpoint()
        }
    }

    private func startBackupTimer() {
        backupTimer?.invalidate()
        // Run backup immediately on launch, then every 10 minutes
        backupDatabase()
        backupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.backupDatabase()
        }
    }

    private func backupDatabase() {
        walCheckpoint()
        let fm = FileManager.default

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let backupDir = appSupport.appendingPathComponent("SociMax/Backups")
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = df.string(from: Date())
        let backupURL = backupDir.appendingPathComponent("socimax-\(timestamp).json")

        // Don't duplicate if same-minute backup exists
        guard !fm.fileExists(atPath: backupURL.path) else { return }

        // Export all projects to JSON (schema-independent, survives version changes)
        let context = ModelContext(sharedModelContainer)
        let descriptor = FetchDescriptor<Project>()
        guard let projects = try? context.fetch(descriptor), !projects.isEmpty else { return }

        do {
            let jsonData = try ProjectExporter.exportAll(projects: projects)
            try jsonData.write(to: backupURL)
            let sizeKB = jsonData.count / 1024
            FileLogger.shared.log("[Backup] Saved: \(backupURL.lastPathComponent) (\(sizeKB)KB)")

            // Keep only latest 3 backups
            let allFiles = ((try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { a, b in
                    let aDate = (try? fm.attributesOfItem(atPath: a.path)[.creationDate] as? Date) ?? .distantPast
                    let bDate = (try? fm.attributesOfItem(atPath: b.path)[.creationDate] as? Date) ?? .distantPast
                    return aDate > bDate
                }
            for file in allFiles.dropFirst(3) {
                try? fm.removeItem(at: file)
            }
        } catch {
            FileLogger.shared.log("[Backup] Failed: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FileLogger.shared.log("App terminating — saving & checkpointing")
        let context = sharedModelContainer.mainContext
        try? context.save()
        walCheckpoint()
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.close()
        } else {
            if let button = statusItem?.button {
                panel.positionNear(statusBarButton: button)
            }
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct SociMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
