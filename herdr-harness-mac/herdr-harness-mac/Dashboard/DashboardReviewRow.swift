import SwiftUI

struct DashboardReviewRow: View {
    let review: PRReviewSummary
    let open: () -> Void
    @State private var isHovered = false
    private var state: DashboardReviewState { review.viewerReview ?? .init(state: "unknown") }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(HerdrTheme.mauve).frame(width: 2)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(review.title).herdrFont(.subheadline, weight: state.needsAttention ? .semibold : .regular)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Label(state.label, systemImage: state.symbol).herdrFont(.caption2)
                            .foregroundStyle(state.needsAttention ? HerdrTheme.working : HerdrTheme.muted)
                            .lineLimit(1).layoutPriority(1)
                        if state.error != nil {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(HerdrTheme.muted)
                                .help("Last known review state. GitHub refresh failed.")
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(review.owner)/\(review.repo) #\(review.number) · \(review.author)")
                            .foregroundStyle(HerdrTheme.mauve).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(skillLabel).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                            .help(skillLabel)
                    }.herdrFont(.caption2)
                }
            }
            .padding(.vertical, 11).padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(isHovered ? HerdrTheme.elevated : .clear, in: .rect(cornerRadius: 5))
            .overlay(alignment: .bottom) { Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1) }
            .contentShape(.rect)
        }.buttonStyle(.plain).onHover { isHovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("dashboard-review-\(review.id)")
    }
    private var skillLabel: String {
        guard let runs = review.skillRuns else {
            return review.runningRuns > 0 ? "\(review.runningRuns) skills running" : "Skill details unavailable"
        }
        return runs.isEmpty ? "No skills run" : runs.map(\.label).joined(separator: " · ")
    }
}
