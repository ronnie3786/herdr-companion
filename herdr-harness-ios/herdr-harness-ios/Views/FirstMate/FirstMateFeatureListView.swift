import SwiftUI

struct FirstMateFeatureListView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    let openFeature: (FirstMateFeatureTarget) -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("herdr.firstMate.appearance") private var appearance = FirstMateAppearance.system
    @State private var archiveCandidate: FirstMateFeatureTarget? = nil

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }
    private var visibleHosts: [FirstMateMobileFleetHost] { fleet.visibleHosts }
    private var showsOwnerLabels: Bool { visibleHosts.count > 1 }
    private var allVisibleHostsUnsupported: Bool {
        !visibleHosts.isEmpty && visibleHosts.allSatisfy(\.isFirstMateUnsupported)
    }
    private var anyVisibleHostLoaded: Bool { visibleHosts.contains(where: \.hasLoaded) }
    private var anyVisibleHostLoading: Bool { visibleHosts.contains(where: \.isLoading) }
    private var activeRowCount: Int { fleet.visibleRows.count { !$0.feature.isArchived } }
    private var workingRowCount: Int {
        fleet.visibleRows.count {
            !$0.feature.isArchived && ["running", "coordinating", "recovering"].contains($0.feature.status)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                introduction
                hostNotices
                if fleet.isDemo { demoBanner }
                if fleet.visibleRows.isEmpty {
                    emptyState
                } else {
                    featureSection("Needs your direction", rows: fleet.waitingRows)
                    featureSection(
                        fleet.waitingRows.isEmpty ? "Your features" : "Everything else",
                        rows: fleet.otherActiveRows
                    )
                    if fleet.showArchived { featureSection("Archived", rows: fleet.archivedRows) }
                }
            }
            .padding(20)
        }
        .background(palette.background)
        .refreshable { await fleet.refresh() }
        .navigationTitle("First Mate")
        .toolbarColorScheme(scheme, for: .navigationBar)
        .searchable(text: $fleet.search, prompt: "Find a feature or goal")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { machineMenu }
            ToolbarItemGroup(placement: .topBarTrailing) {
                optionsMenu
                Button("New feature", systemImage: "plus") { fleet.beginCreating() }
                    .disabled(!model.firstMateCanControlVisibleHosts)
                    .accessibilityIdentifier("first-mate-new-feature")
            }
        }
        .sheet(item: $archiveCandidate) { target in
            FirstMateMobileArchiveSheet(model: model, fleet: fleet, target: target)
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
            if activeRowCount > 0 {
                HStack(spacing: 8) {
                    Label("\(activeRowCount) features", systemImage: "square.stack.3d.up")
                    Text("·").accessibilityHidden(true)
                    Text("\(workingRowCount) working")
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One notice per visible host so a failure, an older companion, or an
    /// empty host never hides a healthy peer's features.
    @ViewBuilder private var hostNotices: some View {
        ForEach(hostNoticeItems, id: \.id) { notice in
            FirstMateNoticeView(title: notice.title, message: notice.message, symbol: notice.symbol)
        }
    }

    private struct HostNotice {
        let id: String
        let title: String
        let message: String
        let symbol: String
    }

    private var hostNoticeItems: [HostNotice] {
        visibleHosts.compactMap { host in
            if host.isFirstMateUnsupported {
                return HostNotice(
                    id: "\(host.machineID)-unsupported",
                    title: "\(host.machineName) needs a server update",
                    message: "Update the companion server on this Mac to use First Mate. Existing features remain in Agents.",
                    symbol: "arrow.down.circle"
                )
            }
            if let error = host.error {
                return HostNotice(
                    id: "\(host.machineID)-error",
                    title: host.features.isEmpty
                        ? "\(host.machineName) features couldn't load"
                        : "Updates paused for \(host.machineName)",
                    message: error,
                    symbol: "wifi.exclamationmark"
                )
            }
            if host.isEmpty, visibleHosts.count > 1, fleet.search.isEmpty {
                return HostNotice(
                    id: "\(host.machineID)-empty",
                    title: "No features on \(host.machineName) yet",
                    message: "Create one there, or open a feature that already runs on it.",
                    symbol: "tray"
                )
            }
            return nil
        }
    }

    private var machineMenu: some View {
        Menu {
            Button {
                model.selectFirstMateScope(.all)
            } label: {
                checkedMenuLabel("All Machines", isChecked: fleet.resolvedScope == .all)
            }
            .accessibilityIdentifier("first-mate-machine-all")
            Divider()
            ForEach(model.machines) { machine in
                Button {
                    model.selectFirstMateScope(.machine(machine.id))
                } label: {
                    checkedMenuLabel(machine.name, isChecked: fleet.resolvedScope == .machine(machine.id))
                }
                .accessibilityIdentifier("first-mate-machine-\(machine.id)")
            }
        } label: {
            Label(model.firstMateScopeLabel, systemImage: "desktopcomputer")
                .font(.subheadline)
                .lineLimit(1)
        }
        .disabled(model.machines.isEmpty)
        .accessibilityLabel("Feature host, \(model.firstMateScopeLabel)")
        .accessibilityIdentifier("first-mate-machine-picker")
    }

    @ViewBuilder private func checkedMenuLabel(_ title: String, isChecked: Bool) -> some View {
        if isChecked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var optionsMenu: some View {
        Menu("First Mate options", systemImage: "ellipsis.circle") {
            Picker("Appearance", selection: $appearance) {
                ForEach(FirstMateAppearance.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            Button("Refresh features", systemImage: "arrow.clockwise") { Task { await fleet.refresh() } }
            Button(
                fleet.canShowArchived ? (fleet.showArchived ? "Hide archived" : "Show archived") : "Archive requires companion update",
                systemImage: "archivebox"
            ) {
                fleet.setShowArchived(!fleet.showArchived)
                Task { await fleet.refresh() }
            }
            .disabled(!fleet.canShowArchived)
            .accessibilityIdentifier("first-mate-show-archived")
            if fleet.isDemo {
                Button("Next demo scenario", systemImage: "forward.end", action: fleet.advanceDemo)
            }
        }
        .accessibilityIdentifier("first-mate-options")
    }

    private var demoBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "flask").foregroundStyle(palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Demo · \(fleet.demoStepTitle ?? "Synthetic")").font(.caption.weight(.semibold))
                Text("Sample features on every demo host, no live agents").font(.caption2).foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 0)
            Button("Next scenario", systemImage: "forward.end", action: fleet.advanceDemo)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("first-mate-demo-next")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private func featureSection(_ title: String, rows: [FirstMateMobileFleetFeature]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondaryText)
                ForEach(rows) { row in
                    featureRow(row)
                }
            }
        }
    }

    @ViewBuilder private func featureRow(_ row: FirstMateMobileFleetFeature) -> some View {
        let store = fleet.store(for: row.target)
        let canControl = model.firstMateCanControl(machineID: row.machineID)
        let canArchive = canControl && store?.archiveSupported == true && store?.isSending == false
        VStack(spacing: 8) {
            Button { openFeature(row.target) } label: {
                FirstMateFeatureCard(
                    feature: row.feature,
                    snapshot: store?.snapshots[row.featureID],
                    machineName: showsOwnerLabels ? row.machineName : nil,
                    machineAccessibilityIdentifier: showsOwnerLabels
                        ? fleet.machineIdentifier(for: row.machineID)
                        : nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(fleet.featureIdentifier(for: row.target))
            if row.feature.isArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") {
                    guard let store else { return }
                    let context = store.operationContext
                    Task { _ = await fleet.setArchived(row.target, archived: false, expectedContext: context) }
                }
                .buttonStyle(.bordered)
                .disabled(!canArchive)
                .accessibilityIdentifier("first-mate-unarchive-\(row.machineID)-\(row.featureID)")
            }
        }
        .contextMenu {
            if row.feature.isArchived {
                Button("Unarchive", systemImage: "arrow.uturn.backward") {
                    guard let store else { return }
                    let context = store.operationContext
                    Task { _ = await fleet.setArchived(row.target, archived: false, expectedContext: context) }
                }
                .disabled(!canArchive)
            } else {
                Button("Archive…", systemImage: "archivebox") { archiveCandidate = row.target }
                    .disabled(!canArchive)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !fleet.search.isEmpty {
            ContentUnavailableView.search(text: fleet.search)
        } else if fleet.hosts.isEmpty {
            ContentUnavailableView("Connect a Mac", systemImage: "desktopcomputer", description: Text("Choose a connected Mac to keep a feature, its agents, and its evidence together."))
        } else if allVisibleHostsUnsupported {
            ContentUnavailableView("First Mate needs a server update", systemImage: "arrow.down.circle", description: Text("Update the companion server on \(visibleHosts.map(\.machineName).joined(separator: ", ")) to use First Mate. Your existing sessions remain available in Agents."))
        } else if anyVisibleHostLoading && !anyVisibleHostLoaded {
            ProgressView("Loading your features…").frame(maxWidth: .infinity).padding(.vertical, 48)
        } else if !model.firstMateCanControlVisibleHosts,
                  visibleHosts.contains(where: { $0.isUnavailable }) {
            ContentUnavailableView {
                Label("Features couldn't load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(fleet.visibleHosts.compactMap(\.error).first ?? "The selected machines are unreachable right now.")
            } actions: {
                Button("Try again") { Task { await fleet.refresh() } }
            }
        } else {
            ContentUnavailableView {
                Label("Start with an outcome", systemImage: "sailboat")
            } description: {
                Text("Bring a ticket or an idea. Your First Mate will shape a plan with you, delegate the work, and come back for your direction.")
            } actions: {
                Button("New feature") { fleet.beginCreating() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.firstMateCanControlVisibleHosts)
            }
        }
    }
}

private struct FirstMateMobileArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    let target: FirstMateFeatureTarget
    @State private var reason: FirstMateArchiveReason? = nil

    private var store: FirstMateStore? { fleet.store(for: target) }
    private var feature: FirstMateFeature? { fleet.feature(for: target) }
    private var ownerAvailable: Bool { fleet.hosts.contains { $0.machineID == target.machineID } }
    private var workContinues: Bool {
        guard let feature else { return false }
        return ["running", "coordinating", "recovering"].contains(feature.status)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let feature {
                    Section {
                        Text(workContinues
                             ? "Work continues after archiving. The feature leaves the active list, while all visits, assignments, documents, sessions, events, status, and Active Work linkage are retained."
                             : "The feature leaves the active list, while all visits, assignments, documents, sessions, events, status, and Active Work linkage are retained.")
                    }
                    Section("Feature") {
                        LabeledContent("Title", value: feature.title)
                        LabeledContent("Host", value: fleet.host(for: target)?.machineName ?? model.machineName(target.machineID))
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
            }
            .navigationTitle("Archive feature?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Archive", role: .destructive) {
                        guard let store else { return }
                        let context = store.operationContext
                        Task {
                            if await fleet.setArchived(target, archived: true, reason: reason, expectedContext: context) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(feature == nil || store?.archiveSupported != true || store?.isSending == true)
                    .accessibilityIdentifier("first-mate-confirm-archive")
                }
            }
        }
        // An owner that leaves the roster invalidates this confirmation: the
        // sheet dismisses instead of retargeting another machine.
        .task(id: ownerAvailable) {
            if !ownerAvailable { dismiss() }
        }
    }
}
