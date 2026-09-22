import SwiftUI

struct FirstMateFeatureListView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: FirstMateStore
    let openFeature: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("herdr.firstMate.appearance") private var appearance = FirstMateAppearance.system
    @State private var archiveCandidate: FirstMateFeature? = nil

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }
    private var waiting: [FirstMateFeature] { store.activeFeatures.filter { ["awaiting_direction", "blocked"].contains($0.status) } }
    private var otherFeatures: [FirstMateFeature] { store.activeFeatures.filter { !["awaiting_direction", "blocked"].contains($0.status) } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                introduction
                if let error = store.error, !store.features.isEmpty {
                    FirstMateNoticeView(title: "Updates paused", message: error, symbol: "wifi.exclamationmark")
                }
                if store.isDemo { demoBanner }
                if store.filteredFeatures.isEmpty {
                    emptyState
                } else {
                    featureSection("Needs your direction", features: waiting)
                    featureSection(waiting.isEmpty ? "Your features" : "Everything else", features: otherFeatures)
                    if store.showArchived { featureSection("Archived", features: store.archivedFeatures) }
                }
            }
            .padding(20)
        }
        .background(palette.background)
        .refreshable { await store.refresh() }
        .navigationTitle("First Mate")
        .toolbarColorScheme(scheme, for: .navigationBar)
        .searchable(text: $store.search, prompt: "Find a feature or goal")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { machineMenu }
            ToolbarItemGroup(placement: .topBarTrailing) {
                optionsMenu
                Button("New feature", systemImage: "plus") { store.isCreating = true }
                    .disabled(!model.firstMateCanControl || store.unsupported)
                    .accessibilityIdentifier("first-mate-new-feature")
            }
        }
        .sheet(item: $archiveCandidate) { feature in
            FirstMateMobileArchiveSheet(store: store, feature: feature)
        }
        .accessibilityIdentifier("first-mate-feature-list")
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep the whole feature in view.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("One conversation. A team working behind it.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
            if !store.activeFeatures.isEmpty {
                HStack(spacing: 8) {
                    Label("\(store.activeFeatures.count) features", systemImage: "square.stack.3d.up")
                    Text("·").accessibilityHidden(true)
                    Text("\(store.activeFeatures.count { ["running", "coordinating", "recovering"].contains($0.status) }) working")
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var machineMenu: some View {
        Menu {
            ForEach(model.machines) { machine in
                Button {
                    model.selectFirstMateMachine(id: machine.id)
                } label: {
                    if model.firstMateMachineID == machine.id {
                        Label(machine.name, systemImage: "checkmark")
                    } else { Text(machine.name) }
                }
            }
        } label: {
            Label(model.firstMateMachineName, systemImage: "desktopcomputer")
                .font(.subheadline)
                .lineLimit(1)
        }
        .disabled(store.isDemo || model.machines.isEmpty)
        .accessibilityLabel("Feature host, \(model.firstMateMachineName)")
        .accessibilityIdentifier("first-mate-machine-picker")
    }

    private var optionsMenu: some View {
        Menu("First Mate options", systemImage: "ellipsis.circle") {
            Picker("Appearance", selection: $appearance) {
                ForEach(FirstMateAppearance.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Button("Refresh features", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                .disabled(store.isRefreshing)
            Button(store.archiveSupported ? (store.showArchived ? "Hide archived" : "Show archived") : "Archive requires companion update", systemImage: "archivebox") {
                store.showArchived.toggle()
                Task { await store.refresh() }
            }
            .disabled(!store.archiveSupported)
            .accessibilityIdentifier("first-mate-show-archived")
            if store.isDemo {
                Button("Next demo scenario", systemImage: "forward.end", action: store.advanceDemo)
            }
        }
        .accessibilityIdentifier("first-mate-options")
    }

    private var demoBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "flask").foregroundStyle(palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Demo · \(store.demoStepTitle)").font(.caption.weight(.semibold))
                Text("Sample features, no live agents").font(.caption2).foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 0)
            Button("Next scenario", systemImage: "forward.end", action: store.advanceDemo)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("first-mate-demo-next")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private func featureSection(_ title: String, features: [FirstMateFeature]) -> some View {
        if !features.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondaryText)
                ForEach(features) { feature in
                    VStack(spacing: 8) {
                        Button { openFeature(feature.id) } label: {
                            FirstMateFeatureCard(feature: feature, snapshot: store.snapshots[feature.id])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("first-mate-feature-\(feature.id)")
                        if feature.isArchived {
                            Button("Unarchive", systemImage: "arrow.uturn.backward") {
                                Task { _ = await store.setArchived(featureID: feature.id, archived: false) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!model.firstMateCanControl || !store.archiveSupported || store.isSending)
                            .accessibilityIdentifier("first-mate-unarchive-\(feature.id)")
                        }
                    }
                    .contextMenu {
                        if feature.isArchived {
                            Button("Unarchive", systemImage: "arrow.uturn.backward") {
                                Task { _ = await store.setArchived(featureID: feature.id, archived: false) }
                            }
                            .disabled(!model.firstMateCanControl || !store.archiveSupported || store.isSending)
                        } else {
                            Button("Archive…", systemImage: "archivebox") { archiveCandidate = feature }
                                .disabled(!model.firstMateCanControl || !store.archiveSupported || store.isSending)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !store.search.isEmpty {
            ContentUnavailableView.search(text: store.search)
        } else if store.unsupported {
            ContentUnavailableView("First Mate needs a server update", systemImage: "arrow.down.circle", description: Text("Update the companion server on this Mac to use First Mate. Your existing sessions remain available in Agents."))
        } else if store.isRefreshing && !store.hasLoaded {
            ProgressView("Loading your features…").frame(maxWidth: .infinity).padding(.vertical, 48)
        } else if let error = store.error {
            ContentUnavailableView {
                Label("Features couldn't load", systemImage: "wifi.exclamationmark")
            } description: { Text(error) } actions: {
                Button("Try again") { Task { await store.refresh() } }
            }
        } else if !model.firstMateCanControl {
            ContentUnavailableView("Connect a Mac", systemImage: "desktopcomputer", description: Text("Choose a connected Mac to keep a feature, its agents, and its evidence together."))
        } else {
            ContentUnavailableView {
                Label("Start with an outcome", systemImage: "sailboat")
            } description: {
                Text("Bring a ticket or an idea. Your First Mate will shape a plan with you, delegate the work, and come back for your direction.")
            } actions: {
                Button("New feature") { store.isCreating = true }.buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct FirstMateMobileArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FirstMateStore
    let feature: FirstMateFeature
    @State private var reason: FirstMateArchiveReason? = nil

    private var workContinues: Bool {
        ["running", "coordinating", "recovering"].contains(feature.status)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(workContinues
                         ? "Work continues after archiving. The feature leaves the active list, while all visits, assignments, documents, sessions, events, status, and Active Work linkage are retained."
                         : "The feature leaves the active list, while all visits, assignments, documents, sessions, events, status, and Active Work linkage are retained.")
                }
                Section("Optional reason") {
                    Picker("Reason", selection: $reason) {
                        Text("No reason").tag(nil as FirstMateArchiveReason?)
                        ForEach(FirstMateArchiveReason.allCases) { value in
                            Text(value.title).tag(value as FirstMateArchiveReason?)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Archive feature?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Archive", role: .destructive) {
                        Task {
                            if await store.setArchived(featureID: feature.id, archived: true, reason: reason) { dismiss() }
                        }
                    }
                    .disabled(!store.archiveSupported || store.isSending)
                    .accessibilityIdentifier("first-mate-confirm-archive")
                }
            }
        }
    }
}
