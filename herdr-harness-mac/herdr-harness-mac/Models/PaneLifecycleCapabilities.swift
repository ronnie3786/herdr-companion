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

    /// Requires `quick-session-launch-options-v1`: the quick-session endpoint
    /// accepts an exact model, thinking level, and focus flag. Older
    /// companions keep the legacy payload and must be updated before a
    /// workspace launch can pin its options.
    var supportsQuickSessionLaunchOptions: Bool {
        capabilities?.contains("quick-session-launch-options-v1") == true
    }
}
