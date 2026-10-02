import AppKit
import SwiftUI

struct AgentRolesView: View {
    private enum Navigation: Equatable {
        case role(String), machine(String), newRole, reload
    }

    @Bindable var store: AgentRolesStore
    var initialTab: AgentRoleEditor.Tab = .profile
    var refreshConnections: () -> Void = {}
    @State private var pendingNavigation: Navigation?
    @State private var confirmsDiscard = false
    @State private var showsSources = false

    var body: some View {
        VStack(spacing: 0) {
            AgentRolesHeader(store: store, selectMachine: { request(.machine($0)) },
                             reload: { request(.reload) }, showSources: { showsSources = true })
            Divider()
            if store.machines.isEmpty && store.draft == nil {
                ContentUnavailableView("No machines yet", systemImage: "desktopcomputer",
                    description: Text("Add a machine in Settings › Machines to configure its First Mate roles."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch store.status {
                case .loading:
                    ProgressView("Loading Agent Roles…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .needsUpdate:
                    ContentUnavailableView {
                        Label("Companion update needed", systemImage: "arrow.down.circle")
                    } description: {
                        Text("The companion on \(store.selectedMachine?.name ?? "this machine") does not support Agent Roles yet.")
                    } actions: {
                        Button("Try Again", action: retry)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .unavailable(message):
                    ContentUnavailableView {
                        Label("Couldn't load Agent Roles", systemImage: "wifi.slash")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again", action: retry)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded:
                    HStack(spacing: 0) {
                        AgentRolesRail(store: store, select: { request(.role($0)) }, newRole: { request(.newRole) })
                        Divider()
                        if let role = Binding($store.draft) {
                            AgentRoleEditor(store: store, role: role, initialTab: initialTab)
                                .id(role.wrappedValue.id)
                        } else {
                            ContentUnavailableView("No roles", systemImage: "person.2",
                                description: Text("Create a role to get started."))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(HerdrTheme.primaryText)
        .background(HerdrBackground())
        .tint(HerdrTheme.accent)
        .accessibilityIdentifier("agent-roles-view")
        .task {
            refreshConnections()
            await store.catalog.refresh()
            await store.loadIfNeeded()
        }
        .onChange(of: store.isSaving) { _, saving in
            if !saving {
                refreshConnections()
                Task { await store.loadIfNeeded() }
            }
        }
        .sheet(isPresented: $showsSources) { AgentRoleSourcesSheet(catalog: store.catalog) }
        .confirmationDialog("Discard unsaved role edits?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard Edits", role: .destructive, action: confirmDiscard)
            Button("Keep Editing", role: .cancel) { pendingNavigation = nil }
        } message: {
            Text("Your changes to this role's profile and skills have not been saved.")
        }
    }

    private func retry() {
        refreshConnections()
        Task { await store.load() }
    }

    private func request(_ navigation: Navigation) {
        guard !store.isSaving else { return }
        if case let .role(id) = navigation, id == store.draft?.id { return }
        if case let .machine(id) = navigation, id == store.selectedMachineID { return }
        if store.hasUnsavedChanges {
            pendingNavigation = navigation
            confirmsDiscard = true
        } else { apply(navigation) }
    }

    private func confirmDiscard() {
        guard let navigation = pendingNavigation else { return }
        pendingNavigation = nil
        store.discard()
        apply(navigation)
    }

    private func apply(_ navigation: Navigation) {
        switch navigation {
        case let .role(id): store.selectRole(id)
        case let .machine(id): Task { await store.selectMachine(id) }
        case .newRole: store.newRole()
        case .reload:
            refreshConnections()
            Task {
                await store.catalog.refresh()
                await store.load()
            }
        }
    }
}
