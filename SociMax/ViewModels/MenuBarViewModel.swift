import Foundation
import SwiftData

@MainActor
@Observable
final class MenuBarViewModel {
    var isRunning = false

    func toggleRunning(projects: [Project], container: ModelContainer) {
        isRunning.toggle()
        if isRunning {
            AutomationScheduler.shared.configure(with: container)
            AutomationScheduler.shared.startAll(projects: projects)
        } else {
            AutomationScheduler.shared.stopAll()
        }
    }
}
