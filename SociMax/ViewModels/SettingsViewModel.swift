import Foundation
import SwiftData

@MainActor
@Observable
final class SettingsViewModel {
    var selectedProject: Project?
    var showingCreateSheet = false

    func createProject(
        name: String,
        description: String,
        botToken: String,
        channelId: String,
        context: ModelContext
    ) {
        let project = Project(
            name: name,
            channelDescription: description,
            telegramBotToken: botToken,
            telegramChannelId: channelId
        )
        context.insert(project)
        selectedProject = project
    }

    func deleteProject(_ project: Project, context: ModelContext) {
        if selectedProject?.id == project.id {
            selectedProject = nil
        }
        context.delete(project)
    }
}
