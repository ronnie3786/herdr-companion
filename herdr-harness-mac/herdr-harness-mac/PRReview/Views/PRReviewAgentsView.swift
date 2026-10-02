import SwiftUI

struct PRReviewAgentsView: View {
    @Environment(\.herdrFontScale) private var fontScale
    @Bindable var store: PRReviewStore
    var canControl = false
    var documentHost: HerdrAppModel? = nil
    var openPane: (String, String?) -> Void = { _, _ in }
    @State private var showsPicker = false
    @State private var showsHistory = false
    @State private var showsEvents = false

    private var history: [PRReviewRun] {
        let current = Set(store.currentAgentRuns.map(\.id))
        return (store.snapshot?.runs ?? []).filter { !current.contains($0.id) && $0.id != store.snapshot?.consolidation?.runID }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Review team").herdrFont(.title2, weight: .semibold)
                        Text("Each agent reviews independently. Their findings come together below.")
                            .herdrFont(.callout).foregroundStyle(HerdrTheme.secondaryText)
                    }
                    Spacer()
                    if store.supportsReviewAgents {
                        Button("Add agents", systemImage: "person.badge.plus", action: showPicker)
                            .herdrProminentButton()
                            .disabled(!canControl || store.isQueueingAgents || store.snapshot?.review.status != .ready)
                            .accessibilityIdentifier("pr-review-add-agents")
                    }
                }
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .herdrFont(.callout).foregroundStyle(HerdrTheme.alert)
                }
                if store.currentAgentRuns.isEmpty {
                    ContentUnavailableView("No reviewers selected", systemImage: "person.2",
                        description: Text(store.supportsReviewAgents ? "Add an agent to begin a review." : "Update this computer's companion to run saved review agents."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260 * fontScale.rawValue), alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(store.currentAgentRuns) { run in
                            PRReviewAgentRunCard(store: store, run: run, canControl: canControl,
                                                 documentHost: documentHost, openPane: openPane)
                        }
                    }
                }
                if store.supportsReviewAgents || store.snapshot?.consolidation != nil {
                    PRReviewConsolidatorCard(store: store, documentHost: documentHost)
                }
                if !history.isEmpty {
                    DisclosureGroup("Run history (\(history.count))", isExpanded: $showsHistory) {
                        VStack(spacing: 10) {
                            ForEach(history) { run in
                                PRReviewRunRow(store: store, run: run, canControl: canControl, openPane: openPane)
                            }
                        }.padding(.top, 10)
                    }
                }
                DisclosureGroup("Activity", isExpanded: $showsEvents) {
                    PRReviewAgentEvents(events: store.snapshot?.events ?? [])
                        .padding(.top, 10)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .herdrPaneBackground()
        .accessibilityIdentifier("pr-review-agents")
        .sheet(isPresented: $showsPicker) { PRReviewAddAgentsSheet(store: store) { showsPicker = false } }
    }

    private func showPicker() { showsPicker = true }
}
