import SwiftUI

private enum FirstMateWorkspaceMode: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case git = "Git"
    var id: Self { self }
}

private struct FirstMateWorkspaceControlTarget: Equatable {
    let storeID: ObjectIdentifier
    let lifecycle: FirstMateStore.LifecycleIdentity
    let canControl: Bool

    @MainActor
    init(store: FirstMateStore, canControl: Bool) {
        storeID = ObjectIdentifier(store)
        lifecycle = store.lifecycle
        self.canControl = canControl
    }
}

struct FirstMateWorkspaceView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var store: FirstMateStore
    let modelFavorites: ModelFavoritesStore
    let canControl: Bool
    let owningMachineID: String?
    let gitOwnerIsReady: Bool
    let configuration: ServerConfiguration?
    let configurationRevision: Int
    var owningMachineName: String? = nil
    var allowsDirectCreate = true
    var popOutGit: ((FirstMateGitWindowTarget) -> Void)?

    @State private var mode = FirstMateWorkspaceMode.chat
    @State private var selectedGitWorkspaceID = "project"
    @State private var selectedGitTargetIdentity: String?
    @State private var controlLease = FirstMateWorkspaceControlLease()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrHostsTitleBar) private var hostsTitleBar

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        let controlTarget = FirstMateWorkspaceControlTarget(store: store, canControl: canControl)
        VStack(spacing: 0) {
            if !hostsTitleBar {
                HStack(spacing: 8) {
                    titleBarLeading
                    Spacer(minLength: 8)
                    titleBarTrailing
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .herdrBar()
            }

            Group {
                if let snapshot = store.snapshot {
                    if mode == .git {
                        if let owningMachineID, gitOwnerIsReady {
                            FirstMateGitView(
                                model: model,
                                machineID: owningMachineID,
                                featureID: snapshot.feature.id,
                                featureTitle: snapshot.feature.title,
                                configuration: configuration,
                                configurationRevision: configurationRevision,
                                initialWorkspaceID: initialGitWorkspaceID,
                                workspaceSelectionChanged: {
                                    selectedGitWorkspaceID = $0
                                    selectedGitTargetIdentity = gitTargetIdentity
                                },
                                popOut: popOutGit
                            )
                            .id("\(owningMachineID)|\(snapshot.feature.id)")
                        } else {
                            ContentUnavailableView(
                                "Git unavailable",
                                systemImage: "arrow.triangle.branch",
                                description: Text("The feature’s owning machine is unavailable. Herdr will not substitute another host.")
                            )
                        }
                    } else {
                        HSplitView {
                            FirstMateChatView(
                                store: store,
                                model: model,
                                snapshot: snapshot,
                                canControl: canControl,
                                modelFavorites: modelFavorites
                            )
                                .frame(minWidth: 330, idealWidth: 480, maxWidth: .infinity)
                            FirstMateInspectorView(store: store, snapshot: snapshot)
                                .frame(minWidth: 340, idealWidth: 420, maxWidth: .infinity)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(store.unsupported ? "First Mate needs a server update" : "A First Mate for every feature", systemImage: "sailboat")
                    } description: {
                        Text(store.error ?? "Start with a ticket or an idea. Keep the plan, independent agents, and evidence in one conversation.")
                    } actions: {
                        if !store.unsupported, allowsDirectCreate {
                            Button("New feature") { store.isCreating = true }.disabled(!canControl)
                        }
                        Button("Refresh") { Task { await store.refresh() } }
                    }
                }
            }
        }
        .herdrTitleBar {
            if hostsTitleBar { titleBarLeading }
        } trailing: {
            if hostsTitleBar { titleBarTrailing }
        }
        .herdrPaneBackground(palette.background)
        // Hierarchical `.secondary` / `.tertiary` resolve to palette tokens
        // that clear 4.5:1 in both appearances.
        .foregroundStyle(palette.text, palette.secondaryText, palette.tertiaryText)
        .tint(palette.accent)
        .task(id: FirstMateWorkspaceObservationID(store: store)) { await observe() }
        .onChange(of: gitTargetIdentity, initial: true) { _, target in
            guard let target else { return }
            if let selectedGitTargetIdentity, selectedGitTargetIdentity != target {
                selectedGitWorkspaceID = "project"
            }
            selectedGitTargetIdentity = target
        }
        .sheet(isPresented: $store.isCreating) { FirstMateCreateSheet(store: store) }
        .sheet(item: $store.resourcePresentation, onDismiss: store.closeResource) { _ in
            if let resource = store.openedResource {
                FirstMateResourceSheet(store: store, resource: resource)
                    .id(resource.id)
            }
        }
        .onChange(of: controlTarget, initial: true) { _, _ in
            controlLease.update(store: store, available: canControl)
        }
        .onDisappear {
            controlLease.release(storeID: controlTarget.storeID, lifecycleIdentity: controlTarget.lifecycle)
        }
        .accessibilityIdentifier("first-mate-workspace")
    }

    // MARK: Title bar

    /// The feature, its ticket and the status menu (MonoCode's `.tbar`).
    @ViewBuilder
    private var titleBarLeading: some View {
        if let snapshot = store.snapshot {
            let feature = snapshot.feature
            let closed = ["completed", "cancelled"].contains(feature.status)
            HStack(spacing: 8) {
                Text(feature.title)
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .help(feature.title)
                    .accessibilityAddTraits(.isHeader)
                if let workItemID = feature.workItemID {
                    Text(workItemID)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
                Menu {
                    Button("Pause feature", systemImage: "pause") {
                        let context = store.operationContext
                        Task { await store.perform("pause", expectedContext: context) }
                    }
                    Button("Resume feature", systemImage: "play") {
                        let context = store.operationContext
                        Task { await store.perform("resume", expectedContext: context) }
                    }
                } label: {
                    FirstMateStatusLabel(status: store.executionDisplayStatus(for: feature), style: .pill)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!canControl || store.isSending || closed)
                .help("Pause or resume feature")
            }
        } else {
            Text("First Mate")
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(palette.text)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The owning machine and Chat | Git.
    private var titleBarTrailing: some View {
        HStack(spacing: 10) {
            if let owningMachineName {
                Label(owningMachineName, systemImage: "desktopcomputer")
                    .labelStyle(DashboardInlineLabelStyle(spacing: 5))
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("first-mate-owning-machine")
            }
            HerdrTabs(
                selection: $mode,
                tabs: FirstMateWorkspaceMode.allCases.map { .init(value: $0, title: $0.rawValue) },
                style: .compactSegments,
                accessibilityLabel: "First Mate view"
            )
            .fixedSize()
            .accessibilityIdentifier("first-mate-chat-git-picker")
        }
    }

    private var gitTargetIdentity: String? {
        guard let owningMachineID, let featureID = store.selectedFeatureID else { return nil }
        return "\(owningMachineID)|\(featureID)"
    }

    private var initialGitWorkspaceID: String {
        selectedGitTargetIdentity == gitTargetIdentity ? selectedGitWorkspaceID : "project"
    }

    private func observe() async {
        repeat {
            await store.refresh()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        } while !Task.isCancelled && !store.isDemo && !store.unsupported
    }
}
