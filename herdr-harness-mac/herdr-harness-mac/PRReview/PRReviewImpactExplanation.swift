import Foundation

extension PRReviewFile {
    var impactExplanation: String {
        let reason = impactReason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reason.isEmpty { return "Why \(impact?.rawValue ?? "this rating"): \(reason)" }
        if impact == nil || impact == .unknown {
            return "Not ranked yet. Choose Rank files for a short explanation of what deserves attention."
        }
        return "No explanation was saved for this rating. Rank files again for review guidance."
    }
}
