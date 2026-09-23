import SwiftUI

struct AgentProfilesView: View {
    @State private var store: AgentProfilesStore
    @State private var pendingMachineID: String?
    @State private var pendingProfileID: String?

    init(model: HerdrAppModel) {
        _store = State(initialValue: AgentProfilesStore(model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentProfilesToolbarView(
                store: store,
                selectMachine: requestMachineSelection,
                reload: reload,
                sync: sync
            )

            if let pendingMutationMessage = store.pendingMutationMessage {
                AgentProfilesNoticeView(
                    message: pendingMutationMessage,
                    systemImage: "arrow.clockwise.circle",
                    color: HerdrTheme.warning,
                    actionTitle: "Retry same request",
                    action: retryPendingMutation
                )
            } else if let conflictMessage = store.conflictMessage {
                AgentProfilesNoticeView(
                    message: conflictMessage,
                    systemImage: "arrow.triangle.2.circlepath",
                    color: HerdrTheme.mauve,
                    actionTitle: "Reload & reconcile",
                    action: reload
                )
            } else if let errorMessage = store.errorMessage {
                AgentProfilesNoticeView(
                    message: errorMessage,
                    systemImage: store.requiresServerUpgrade ? "arrow.down.circle" : "exclamationmark.triangle",
                    color: HerdrTheme.alert,
                    actionTitle: "Retry",
                    action: reload
                )
            }

            Divider().overlay(HerdrTheme.separator)

            if store.machines.isEmpty {
                ContentUnavailableView(
                    "No machines configured",
                    systemImage: "server.rack",
                    description: Text("Add a companion connection in Settings before editing Agent Profiles.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.isLoading && store.overview == nil {
                ProgressView("Loading Agent Profiles…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.overview != nil {
                HSplitView {
                    AgentProfilesSidebarView(
                        store: store,
                        selectProfile: requestProfileSelection,
                        createProfile: requestNewProfile
                    )
                    .frame(minWidth: 190, idealWidth: 220, maxWidth: 270)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            AgentProfileEditorView(store: store)
                            AgentProfileProposalListView(store: store)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .background(HerdrBackground())
                }
            } else {
                ContentUnavailableView(
                    "Agent Profiles unavailable",
                    systemImage: "person.text.rectangle",
                    description: Text("Choose Retry after the companion server is reachable.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(HerdrTheme.graphite)
        .foregroundStyle(HerdrTheme.text)
        .tint(HerdrTheme.accent)
        .accessibilityIdentifier("agent-profiles-view")
        .task { await store.load() }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: machineConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button("Discard changes", role: .destructive, action: confirmMachineSelection)
            Button("Cancel", role: .cancel) { pendingMachineID = nil }
        } message: {
            Text("Switching the data machine clears this profile and override draft.")
        }
        .confirmationDialog(
            "Discard profile draft?",
            isPresented: profileConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button("Discard draft", role: .destructive, action: confirmProfileSelection)
            Button("Cancel", role: .cancel) { pendingProfileID = nil }
        } message: {
            Text("Your assignment and override draft stays open, but unsaved profile edits will be cleared.")
        }
    }

    private var machineConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingMachineID != nil },
            set: { if !$0 { pendingMachineID = nil } }
        )
    }

    private var profileConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingProfileID != nil },
            set: { if !$0 { pendingProfileID = nil } }
        )
    }

    private func requestMachineSelection(_ machineID: String) {
        guard machineID != store.selectedMachineID else { return }
        if store.hasUnsavedChanges {
            pendingMachineID = machineID
        } else {
            Task { await store.selectMachine(machineID) }
        }
    }

    private func confirmMachineSelection() {
        guard let machineID = pendingMachineID else { return }
        pendingMachineID = nil
        Task { await store.selectMachine(machineID) }
    }

    private func requestProfileSelection(_ profileID: String) {
        guard !store.isSaving,
              !store.hasPendingMutation,
              profileID != store.selectedProfileID else { return }
        if store.profileHasUnsavedChanges {
            pendingProfileID = profileID
        } else {
            Task { await store.selectProfile(profileID) }
        }
    }

    private func requestNewProfile() {
        guard !store.isSaving, !store.hasPendingMutation else { return }
        if store.profileHasUnsavedChanges {
            pendingProfileID = ""
        } else {
            store.beginCreatingProfile()
        }
    }

    private func confirmProfileSelection() {
        guard let profileID = pendingProfileID else { return }
        pendingProfileID = nil
        if profileID.isEmpty {
            store.beginCreatingProfile()
        } else {
            Task { await store.selectProfile(profileID) }
        }
    }

    private func reload() {
        Task { await store.reloadDiscardingDraft() }
    }

    private func sync() {
        Task { await store.syncNow() }
    }

    private func retryPendingMutation() {
        Task { await store.retryPendingMutation() }
    }
}
