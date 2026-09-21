import Foundation

struct ServerCapabilities: Decodable, Sendable {
    let capabilities: [String]?

    var supportsRetirement: Bool {
        capabilities?.contains("pane-retirement-v1") == true
    }

    var supportsConversationContext: Bool {
        capabilities?.contains("pi-session-context-v1") == true
    }

    var supportsIssueReports: Bool {
        capabilities?.contains("issue-reports-v1") == true
    }

    var supportsPRReview: Bool {
        capabilities?.contains("pr-review-v1") == true
    }
}
