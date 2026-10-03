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
    /// "Open in window": the First Mate chat window on this feature. Nil hides
    /// the button (the chat window preview is off).
    var popOutChat: (() -> Void)?
    var startSession: (() -> Void)?

    @State private var mode = FirstMateWorkspaceMode.chat
    @State private var selectedGitWorkspaceID: String?
    @State private var selectedGitTargetIdentity: String?
    @State private var selectedGitCommitSHA: String?
    @State private var controlLease = FirstMateWorkspaceControlLease()
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase
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
                                initialCommitSHA: selectedGitCommitSHA,
                                workspaceSelectionChanged: {
                                    selectedGitWorkspaceID = $0
                                    selectedGitCommitSHA = nil
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
                            FirstMateInspectorView(store: store, snapshot: snapshot, openCommit: { selection in
                                selectedGitWorkspaceID = selection.workspaceID
                                selectedGitCommitSHA = selection.commitSHA
                                selectedGitTargetIdentity = gitTargetIdentity
                                mode = .git
                            })
                                .firstMateSimulator(model: model, machineID: owningMachineID, featureID: snapshot.feature.id)
                                .frame(minWidth: 340, idealWidth: 420, maxWidth: .infinity)
                        }
                    }
                } else if mode == .chat, store.selectedFeatureID != nil {
                    HSplitView {
                        ProgressView("Loading conversation…")
                            .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                        FirstMateInspectorView(store: store)
                            .frame(minWidth: 340, idealWidth: 420, maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView {
                        Label(store.unsupported ? "First Mate needs a server update" : "A First Mate for every feature", systemImage: "sailboat")
                    } description: {
                        Text(store.error ?? "Start with a ticket or an idea. Keep the plan, independent agents, and evidence in one conversation.")
                    } actions: {
                        if allowsDirectCreate, startSession != nil || !store.unsupported {
                            Button("New session") {
                                if let startSession { startSession() } else { store.isCreating = true }
                            }
                                .herdrProminentButton()
                                .disabled(startSession == nil && !canControl)
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
        // Unstyled buttons get Herdr's outline: under the hierarchical style
        // above, the native bezel turns light gray behind a white label.
        .buttonStyle(HerdrButtonStyle(kind: .outline, height: HerdrTheme.ControlHeight.regular))
        .tint(palette.accent)
        .task(id: "\(store.lifecycle.opaqueID)|\(store.selectedFeatureID ?? "")|\(controlActiveState == .key)|\(scenePhase == .background)") { await observe() }
        .task(id: store.lifecycle) { await observeList() }
        .onChange(of: gitTargetIdentity, initial: true) { _, target in
            guard let target else { return }
            if let selectedGitTargetIdentity, selectedGitTargetIdentity != target {
                selectedGitWorkspaceID = nil
                selectedGitCommitSHA = nil
            }
            selectedGitTargetIdentity = target
        }
        .sheet(isPresented: Binding(get: { startSession == nil && store.isCreating }, set: { store.isCreating = $0 })) {
            FirstMateCreateSheet(store: store)
        }
        .onChange(of: store.isCreating, initial: true) { _, creating in
            if creating, let startSession {
                store.isCreating = false
                startSession()
            }
        }
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
                    .modifier(FirstMateArchiveContextMenu(store: store, feature: feature, canControl: canControl))
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
                .buttonStyle(.herdrPlain)
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

    /// The owning machine, Open in window, and Chat | Git.
    private var titleBarTrailing: some View {
        HStack(spacing: 10) {
            if let owningMachineName {
                Label(owningMachineName, systemImage: "desktopcomputer")
                    .labelStyle(HerdrInlineLabelStyle(spacing: 5))
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("first-mate-owning-machine")
            }
            if let popOutChat {
                Button(action: popOutChat) {
                    Image(systemName: "macwindow")
                        .herdrFont(size: 13)
                        .foregroundStyle(palette.iconTint)
                        .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.herdrPlain)
                .accessibilityLabel("Open in window")
                .help("Open in window")
                .accessibilityIdentifier("first-mate-open-chat-window")
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

    private var initialGitWorkspaceID: String? {
        selectedGitTargetIdentity == gitTargetIdentity ? selectedGitWorkspaceID : nil
    }

    private func observe() async {
        repeat {
            await store.refreshConversation()
            do { try await Task.sleep(for: .seconds(scenePhase == .background ? 30 : controlActiveState == .key ? 2 : 10)) } catch { return }
        } while !Task.isCancelled && !store.isDemo
    }

    /// The main workspace still owns its feature list. Refreshing it must not
    /// block a selection's conversation, or repeat on every selection change.
    private func observeList() async {
        repeat {
            await store.refresh(includeConversation: false)
            do { try await Task.sleep(for: .seconds(scenePhase == .background ? 30 : 10)) } catch { return }
        } while !Task.isCancelled && !store.isDemo
    }
}
