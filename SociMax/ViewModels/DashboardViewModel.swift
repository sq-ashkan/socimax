import Foundation
import SwiftData

@MainActor
@Observable
final class DashboardViewModel {
    var selectedProjectId: UUID?
}
