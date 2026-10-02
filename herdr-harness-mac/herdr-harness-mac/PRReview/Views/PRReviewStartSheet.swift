import SwiftUI

struct PRReviewStartSheet: View {
    @Bindable var store: PRReviewStore
    let dismiss: () -> Void
    @State private var selectedAgents: Set<String> = []
    @State private var urlText = ""
    @State private var restoredScope: String?
    @Environment(\.openSettings) private var openSettings

    private static let selectionKey = "herdr.prReview.lastAgents"
    private var scopeID: String { store.currentMachineID ?? "unconfigured" }
    private var hasURL: Bool { !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose your review team").herdrFont(.title2, weight: .semibold)
                TextField("Pull request link", text: $urlText)
                    .textFieldStyle(.roundedBorder).herdrFont(.callout)
                    .accessibilityIdentifier("pr-review-start-url")
                    .disabled(store.isCreating)
            }
            if !store.isDemo && store.capabilities == nil {
                ProgressView("Loading review agents…").frame(maxWidth: .infinity, minHeight: 100)
            } else if store.supportsReviewAgents {
                ScrollView {
                    PRReviewAgentPicker(agents: store.reviewAgents, selection: $selectedAgents)
                        .padding(.vertical, 2)
                }
                .frame(maxHeight: 420)
                HStack(alignment: .top) {
                    Text("Add custom agents in Settings → Agent Roles → PR Review Agents.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    Spacer()
                    Button("Settings", action: showSettings).buttonStyle(.borderless)
                }
            } else {
                ContentUnavailableView("Companion update needed", systemImage: "arrow.down.circle",
                    description: Text("Update the review computer's companion to choose PR Review Agents. You can still add this pull request without running agents."))
            }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text("\(selectedAgents.count) selected").herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Add only", action: addOnly).disabled(!hasURL)
                Button(store.isCreating ? "Starting…" : "Start review", action: start)
                    .herdrProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasURL || !store.supportsReviewAgents || selectedAgents.isEmpty)
            }
            .disabled(store.isCreating)
        }
        .padding(24)
        .frame(width: 570)
        .foregroundStyle(HerdrTheme.primaryText)
        .background(alignment: .top) { HerdrHazeBand() }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true) }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("pr-review-start-sheet")
        .interactiveDismissDisabled(store.isCreating)
        .onAppear { urlText = store.pendingURL ?? ""; restoreSelectionIfReady() }
        .onChange(of: scopeID) { _, _ in restoredScope = nil; selectedAgents = []; restoreSelectionIfReady() }
        .onChange(of: store.capabilities) { _, _ in restoreSelectionIfReady() }
        .onChange(of: store.reviewAgents) { _, agents in
            if restoredScope == scopeID { selectedAgents.formIntersection(agents.map(\.id)) }
            else { restoreSelectionIfReady() }
        }
    }

    private func restoreSelectionIfReady() {
        guard restoredScope != scopeID, store.isDemo || store.capabilities != nil else { return }
        selectedAgents = PRReviewAgentSelection.initialSelection(agents: store.reviewAgents,
            saved: UserDefaults.standard.stringArray(forKey: Self.key(machineID: scopeID)))
        restoredScope = scopeID
    }
    private func showSettings() { openSettings() }
    private func start() { submit(selectedAgents.sorted()) }
    private func addOnly() { submit([]) }
    private func submit(_ ids: [String]) {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let machineID = scopeID
        Task {
            let succeeded: Bool
            if store.supportsReviewAgents {
                succeeded = await store.createWithAgents(url: url, agentIDs: ids)
            } else {
                await store.create(url: url)
                succeeded = store.error == nil && scopeID == machineID
            }
            guard succeeded else { return }
            Self.saveSelection(selectedAgents, machineID: machineID)
            store.pendingURL = nil
            dismiss()
        }
    }

    private static func key(machineID: String) -> String { "\(selectionKey).\(machineID)" }
    static func loadSelection(machineID: String = "default", defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key(machineID: machineID)) ?? [])
    }
    static func saveSelection(_ selection: Set<String>, machineID: String = "default", defaults: UserDefaults = .standard) {
        defaults.set(selection.sorted(), forKey: key(machineID: machineID))
    }
}
