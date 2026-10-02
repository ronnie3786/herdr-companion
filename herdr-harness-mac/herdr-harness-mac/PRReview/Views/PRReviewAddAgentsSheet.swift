import SwiftUI

struct PRReviewAddAgentsSheet: View {
    @Bindable var store: PRReviewStore
    let dismiss: () -> Void
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add reviewers").herdrFont(.title2, weight: .semibold)
            Text("Choose agents for another pass. Herdr will update the consolidated report when they finish.")
                .herdrFont(.callout).foregroundStyle(HerdrTheme.secondaryText)
            ScrollView {
                PRReviewAgentPicker(agents: store.reviewAgents, selection: $selected, unavailableIDs: store.activeAgentIDs)
            }
            .frame(maxHeight: 420)
            Text("Create more agents in Settings → Agent Roles → PR Review Agents.")
                .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.alert)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button(store.isQueueingAgents ? "Adding…" : "Run selected", action: submit)
                    .herdrProminentButton().keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .disabled(store.isQueueingAgents)
        }
        .padding(24)
        .frame(width: 570)
        .foregroundStyle(HerdrTheme.primaryText)
        .background(alignment: .top) { HerdrHazeBand() }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
        .interactiveDismissDisabled(store.isQueueingAgents)
        .onChange(of: store.activeAgentIDs) { _, ids in selected.subtract(ids) }
        .onChange(of: store.reviewAgents) { _, agents in selected.formIntersection(agents.map(\.id)) }
        .onChange(of: store.currentMachineID) { _, _ in dismiss() }
        .onChange(of: store.selectedReviewID) { _, _ in dismiss() }
    }

    private func submit() {
        let ids = selected.subtracting(store.activeAgentIDs).sorted()
        Task { if await store.queueAgents(ids) { dismiss() } }
    }
}
