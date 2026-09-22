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

    var body: some View {
        let controlTarget = FirstMateWorkspaceControlTarget(store: store, canControl: canControl)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let owningMachineName {
                    Label(owningMachineName, systemImage: "desktopcomputer")
                        .herdrFont(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("first-mate-owning-machine")
                }
                Spacer()
                Picker("First Mate view", selection: $mode) {
                    ForEach(FirstMateWorkspaceMode.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .accessibilityIdentifier("first-mate-chat-git-picker")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(FirstMatePalette(scheme: scheme).surface)
            .overlay(alignment: .bottom) { Divider() }

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
                                .frame(minWidth: 340, idealWidth: 465, maxWidth: .infinity)
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
        .background(FirstMatePalette(scheme: scheme).background)
        .foregroundStyle(.primary)
        .tint(FirstMatePalette(scheme: scheme).accent)
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
