import SwiftUI

struct PRReviewConsolidatorCard: View {
    @Bindable var store: PRReviewStore
    let documentHost: HerdrAppModel?

    private var consolidation: PRReviewConsolidation? { store.snapshot?.consolidation }
    private var isCurrent: Bool {
        guard let review = store.snapshot?.review else { return false }
        return consolidation?.matches(review) == true
    }
    private var documents: [PRReviewDocument] {
        guard isCurrent, consolidation?.state == "finished" else { return [] }
        let ids = Set(consolidation?.documentIDs ?? [])
        return (store.snapshot?.documents ?? []).filter { ids.contains($0.id) }
    }
    private var status: String {
        guard let consolidation else { return "Waiting for reviewers" }
        guard isCurrent else { return "PR commits changed. Run reviewers again to update the report." }
        switch consolidation.state {
        case "waiting": return "Waiting for all reviewers to finish"
        case "running": return "Checking and combining findings"
        case "finished": return (consolidation.incompleteRunIDs ?? []).isEmpty ? "Report ready" : "Report ready with incomplete coverage"
        case "failed": return "Consolidation failed"
        default: return "Status unavailable"
        }
    }
    private var symbol: String {
        guard isCurrent else { return "clock" }
        switch consolidation?.state {
        case "running": return "circle.dotted"
        case "finished": return (consolidation?.incompleteRunIDs ?? []).isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle"
        case "failed": return "exclamationmark.circle"
        default: return "clock"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                AgentRoleAvatarView(avatar: "architecture", size: 44, selected: consolidation?.state == "running")
                VStack(alignment: .leading, spacing: 5) {
                    Text("Consolidator").herdrFont(.headline)
                    Label(status, systemImage: symbol).herdrFont(.callout)
                        .foregroundStyle(HerdrTheme.secondaryText)
                    Text("Validates findings, removes duplicates, and links each agent's original report.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            if let error = consolidation?.error, !error.isEmpty {
                Text(error).herdrFont(.caption).foregroundStyle(HerdrTheme.alert)
            }
            ForEach(documents) { document in
                PRReviewReportLink(store: store, document: document, documentHost: documentHost)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .herdrCard(fill: HerdrTheme.accent.opacity(0.045), outline: HerdrTheme.accent.opacity(0.2))
        .accessibilityIdentifier("pr-review-consolidator")
    }
}
