import Foundation

enum DashboardReviewPresentation {
    static func filtered(_ reviews: [PRReviewSummary], focusMode: Bool, query: String) -> [PRReviewSummary] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return reviews.filter {
            $0.archivedAt == nil && $0.viewerReview?.isOwnPR != true
                && (!focusMode || $0.viewerReview?.needsAttention == true)
                && (search.isEmpty || [$0.title, $0.repo, $0.owner, $0.author, String($0.number)]
                    .contains { $0.localizedStandardContains(search) })
        }
        // Parse each date once; never inside the comparator.
        .map { ($0, $0.updatedAt.flatMap(HerdrTimestamp.date) ?? .distantPast) }
        .sorted { lhs, rhs in
            let left = lhs.0.viewerReview?.needsAttention == true
            let right = rhs.0.viewerReview?.needsAttention == true
            if left != right { return left }
            return lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 > rhs.1
        }
        .map(\.0)
    }
}
