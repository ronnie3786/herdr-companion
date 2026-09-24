import Foundation

struct DashboardReviewState: Codable, Equatable, Sendable {
    var state: String
    var pendingCommentCount: Int = 0
    var needsUser: Bool = false
    var isOwnPR: Bool? = nil
    var reviewedAt: String? = nil
    var reviewedCommit: String? = nil
    var headCommit: String? = nil
    var reviewRequested: Bool = false
    var updatedAt: String? = nil
    var checkedAt: String? = nil
    var error: String? = nil

    /// Unknown states must never manufacture a request for human attention.
    var needsAttention: Bool { ["pending", "re_review_requested"].contains(state) }
    var label: String {
        switch state {
        case "pending": pendingCommentCount > 0 ? "Pending · \(pendingCommentCount) drafts" : "Pending review"
        case "re_review_requested": "Re-review requested"
        case "approved": "Approved"
        case "changes_requested": "Changes requested"
        case "commented": "Commented"
        case "not_reviewed": "Not reviewed"
        default: "Review state unavailable"
        }
    }
    var symbol: String {
        switch state {
        case "pending": "circle.lefthalf.filled"
        case "re_review_requested": "arrow.clockwise"
        case "approved": "checkmark"
        case "changes_requested": "xmark"
        case "commented": "bubble"
        default: "circle"
        }
    }
    enum CodingKeys: String, CodingKey {
        case state, error
        case pendingCommentCount = "pending_comment_count", needsUser = "needs_user"
        case isOwnPR = "is_own_pr", reviewedAt = "reviewed_at", reviewedCommit = "reviewed_commit"
        case headCommit = "head_commit", reviewRequested = "review_requested"
        case updatedAt = "updated_at", checkedAt = "checked_at"
    }
}

extension PRReviewSummary {
    /// GitHub polling has its own clock and does not change the checkout revision.
    /// A delayed diff/snapshot response must not roll the viewer's state backward.
    func retainingNewerViewerState(from previous: PRReviewSummary?) -> Self {
        guard let previous, previous.id == id, let old = previous.viewerReview else { return self }
        let oldDate = (old.checkedAt ?? old.updatedAt).flatMap(HerdrTimestamp.date) ?? .distantPast
        let newDate = (viewerReview?.checkedAt ?? viewerReview?.updatedAt).flatMap(HerdrTimestamp.date) ?? .distantPast
        guard viewerReview == nil || oldDate > newDate else { return self }
        var result = self
        result.viewerReview = old
        return result
    }
}
