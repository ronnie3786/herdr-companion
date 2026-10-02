import SwiftUI

struct PRReviewAgentRunCard: View {
    @Bindable var store: PRReviewStore
    let run: PRReviewRun
    let canControl: Bool
    let documentHost: HerdrAppModel?
    let openPane: (String, String?) -> Void

    private var canRerun: Bool {
        guard let agentID = run.agentID else { return false }
        return canControl && !store.isQueueingAgents && !store.activeAgentIDs.contains(agentID)
            && store.reviewAgents.contains { $0.id == agentID }
    }
    private var documents: [PRReviewDocument] { (store.snapshot?.documents ?? []).filter { $0.runID == run.id } }
    private var isEarlierRevision: Bool {
        guard let review = store.snapshot?.review, let head = run.headSHA, let base = run.baseSHA else { return false }
        return head != review.headSHA || base != review.baseSHA
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AgentRoleAvatarView(avatar: run.agentAvatar ?? "review", size: 46, selected: run.isActive)
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.displayName).herdrFont(.headline).fixedSize(horizontal: false, vertical: true)
                    Label(run.state.displayTitle, systemImage: run.state.symbol)
                        .herdrFont(.caption).foregroundStyle(run.state.color)
                    if isEarlierRevision {
                        Label("Earlier PR revision", systemImage: "clock.arrow.circlepath")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.warning)
                    }
                }
                Spacer(minLength: 0)
            }
            if let error = run.error ?? run.note, !error.isEmpty {
                Text(error).herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(documents) { document in
                PRReviewReportLink(store: store, document: document, documentHost: documentHost)
            }
            HStack {
                if let paneID = run.paneID {
                    Button("Open agent") { openPane(paneID, store.currentMachineID) }
                }
                Spacer()
                if !run.isActive {
                    Button("Run again", systemImage: "arrow.clockwise", action: rerun).disabled(!canRerun)
                }
            }
            .buttonStyle(.borderless)
            .herdrFont(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .herdrCard()
        .accessibilityIdentifier("pr-review-agent-run-\(run.id)")
    }

    private func rerun() {
        guard let agentID = run.agentID else { return }
        Task { await store.queueAgents([agentID]) }
    }
}
