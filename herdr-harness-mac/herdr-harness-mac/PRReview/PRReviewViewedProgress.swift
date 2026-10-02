/// Review-wide counts and shared presentation copy, independent of file-rail filters.
struct PRReviewViewedProgress: Equatable {
    let total: Int
    let viewed: Int

    init(files: [PRReviewFile]) {
        total = files.count
        viewed = files.count(where: { $0.viewed })
    }

    var unviewed: Int { total - viewed }
    var isComplete: Bool { total > 0 && viewed == total }
    var fraction: Double { total == 0 ? 0 : Double(viewed) / Double(total) }

    var summary: String {
        if isComplete {
            return total == 1 ? "1 of 1 file viewed" : "All \(total) files viewed"
        }
        return "\(viewed) of \(total) viewed · \(unviewed) unviewed"
    }

    var accessibilityLabel: String { "Review progress" }
    var accessibilityValue: String {
        let noun = total == 1 ? "file" : "files"
        return "\(viewed) of \(total) \(noun) viewed, \(unviewed) remaining"
    }

    static let viewedBadgeLabel = "Viewed"

    static func rowAccessibilityValue(viewed: Bool) -> String {
        viewed ? viewedBadgeLabel : "Not viewed"
    }

    static let allViewedTitle = "All files viewed"
    static let allViewedDetail = "Turn off Hide viewed to see them again."
    static let showViewedLabel = "Show viewed files"
}

extension PRReviewStore {
    /// The full active comparison includes its own Viewed marks, before filtering.
    var viewedProgress: PRReviewViewedProgress {
        PRReviewViewedProgress(files: comparisonFiles)
    }
}
