import Foundation

enum DashboardReviewPresentation {
    static func filtered(_ reviews: [PRReviewSummary], focusMode: Bool, query: String) -> [PRReviewSummary] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return reviews.filter {
            $0.archivedAt == nil && $0.viewerReview?.isOwnPR != true
                && (!focusMode || $0.viewerReview?.needsAttention == true)
                && (search.isEmpty || [$0.title, $0.repo, $0.owner, $0.author, String($0.number)]
                    .contains { $0.localizedStandardContains(search) })
        }.sorted {
            let lhs = $0.viewerReview?.needsAttention == true
            let rhs = $1.viewerReview?.needsAttention == true
            if lhs != rhs { return lhs }
            let left = $0.updatedAt.flatMap(HerdrTimestamp.date) ?? .distantPast
            let right = $1.updatedAt.flatMap(HerdrTimestamp.date) ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }
}
