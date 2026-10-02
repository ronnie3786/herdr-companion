import SwiftUI

extension PRReviewRunState {
    var displayTitle: String {
        switch self {
        case .queued: "Queued"
        case .running: "Reviewing"
        case .finished: "Completed"
        case .failed: "Failed"
        case .ended: "Interrupted"
        case .unknown: "Status unavailable"
        }
    }
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "circle.dotted"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .ended: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .queued, .running: HerdrTheme.working
        case .finished: HerdrTheme.success
        case .failed: HerdrTheme.alert
        case .ended, .unknown: HerdrTheme.secondaryText
        }
    }
}
