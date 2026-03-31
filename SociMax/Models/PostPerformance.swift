import Foundation
import SwiftData

@Model
final class PostPerformance {
    var id: UUID
    var views: Int
    var predictedScore: Double
    var checkedAt: Date

    var post: GeneratedPost?

    init(views: Int, predictedScore: Double) {
        self.id = UUID()
        self.views = views
        self.predictedScore = predictedScore
        self.checkedAt = Date()
    }
}
