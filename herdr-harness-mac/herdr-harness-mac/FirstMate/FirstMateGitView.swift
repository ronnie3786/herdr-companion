import SwiftUI

struct FirstMateGitLoadIdentity: Hashable {
    let machineID: String
    let featureID: String
    let configurationRevision: Int
    let url: String?
    let token: String?
    let retryGeneration: Int
}

struct FirstMateGitView: View {
    @Bindable var model: HerdrAppModel
    let machineID: String
    let featureID: String
    let featureTitle: String
    let configuration: ServerConfiguration?
    let configurationRevision: Int
    let pinnedWorkspaceID: String?
    var workspaceSelectionChanged: ((String) -> Void)?
    var popOut: ((FirstMateGitWindowTarget) -> Void)?

    @State private var catalog: FirstMateGitCatalog
    @State private var retryGeneration = 0
    @Environment(\.colorScheme) private var scheme

    init(
        model: HerdrAppModel,
        machineID: String,
        featureID: String,
        featureTitle: String,
        configuration: ServerConfiguration?,
        configurationRevision: Int,
        pinnedWorkspaceID: String? = nil,
        initialWorkspaceID: String = "project",
        workspaceSelectionChanged: ((String) -> Void)? = nil,
        popOut: ((FirstMateGitWindowTarget) -> Void)? = nil
    ) {
        self.model = model
        self.machineID = machineID
        self.featureID = featureID
        self.featureTitle = featureTitle
        self.configuration = configuration
        self.configurationRevision = configurationRevision
        self.pinnedWorkspaceID = pinnedWorkspaceID
        self.workspaceSelectionChanged = workspaceSelectionChanged
        self.popOut = popOut
        _catalog = State(initialValue: FirstMateGitCatalog(
            pinnedWorkspaceID: pinnedWorkspaceID,
            initialWorkspaceID: initialWorkspaceID
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            contextBar
            Group {
                switch catalog.phase {
                case .idle, .loading:
                    loading
                case .unsupported:
                    unavailable(
                        "Git needs a server update",
                        detail: "Update the companion on this feature’s owning machine to use First Mate Git."
                    )
                case let .failed(message):
                    unavailable("Git unavailable", detail: message)
                case .ready:
                    gitContent
                }
            }
        }
        .background(FirstMatePalette(scheme: scheme).background)
        .task(id: loadIdentity) {
            let client = configuration.map { HerdrAPIClient(configuration: $0) }
            await catalog.load(
                machineID: machineID,
                featureID: featureID,
                client: client,
                demo: isDemoTarget,
                demoFeatureTitle: featureTitle,
                configuration: configuration,
                configurationRevision: configurationRevision
            )
        }
        .navigationTitle(windowTitle)
        .accessibilityIdentifier("first-mate-git")
    }

    private var contextBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(catalog.featureTitle ?? featureTitle).herdrFont(.headline, weight: .semibold)
                Text("\(machineName) · \(workspaceTitle) · \(workspaceContext)")
                    .herdrFont(.caption, monospaced: true)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("first-mate-git-workspace-context")
            }
            Spacer()
            if catalog.phase == .ready, !catalog.isPinned {
                Picker(
                    "Git workspace",
                    selection: Binding(
                        get: { catalog.selectedWorkspaceID },
                        set: {
                            catalog.selectWorkspace(id: $0)
                            workspaceSelectionChanged?($0)
                        }
                    )
                ) {
                    ForEach(catalog.workspaces) { workspace in
                        Text(workspace.title).tag(workspace.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .accessibilityLabel("Git workspace")
                .accessibilityIdentifier("first-mate-git-workspace-picker")
                if let popOut, catalog.selectedWorkspace != nil {
                    Button("Open Git in New Window", systemImage: "macwindow.badge.plus") {
                        popOut(target)
                    }
                    .labelStyle(.iconOnly)
                    .help("Open Git in New Window")
                    .accessibilityLabel("Open Git in New Window")
                    .accessibilityIdentifier("first-mate-git-open-window")
                }
            }
            Button("Refresh Git workspaces", systemImage: "arrow.clockwise") {
                retryGeneration &+= 1
            }
            .labelStyle(.iconOnly)
            .help("Refresh Git workspaces")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(FirstMatePalette(scheme: scheme).surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var gitContent: some View {
        if let selectedWorkspace = catalog.selectedWorkspace {
            if isDemoTarget {
                let workspace = FirstMateGitDemo.nativeWorkspace(for: selectedWorkspace)
                WorkspaceGitView(
                    workspace: workspace,
                    loadStatus: { try await model.fetchGitStatus(for: workspace) },
                    loadDiff: { file, section in
                        try await model.fetchGitDiff(for: workspace, file: file, section: section)
                    },
                    stageFile: { file in try await model.stageGitFile(file, in: workspace) },
                    unstageFile: { file in try await model.unstageGitFile(file, in: workspace) }
                )
                .id(selectedWorkspace.id)
            } else if let configuration {
                // A healthy authenticated API is sufficient. First Mate Git
                // does not depend on a live terminal-pane connection.
                PaneGitWebView(configuration: configuration, firstMateTarget: target)
                    .id("\(target.id)|\(configurationRevision)|\(configuration.baseURL.absoluteString)")
            } else {
                unavailable(
                    "Machine unavailable",
                    detail: "The owning machine is no longer configured. Add it again, then retry."
                )
            }
        } else {
            unavailable(
                "Workspace unavailable",
                detail: "Workspace \(catalog.selectedWorkspaceID) is not available for this feature. The window remains pinned to that exact target."
            )
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading Git workspaces…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func unavailable(_ title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "arrow.triangle.branch")
        } description: {
            Text(detail)
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise") { retryGeneration &+= 1 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var target: FirstMateGitWindowTarget {
        .init(machineID: machineID, featureID: featureID, workspaceID: catalog.selectedWorkspaceID)
    }

    private var machineName: String {
        model.machines.first { $0.id == machineID }?.name ?? machineID
    }

    private var isDemoTarget: Bool {
        model.isDemoMode && machineID == "demo"
    }

    private var workspaceTitle: String {
        catalog.selectedWorkspace?.title ?? catalog.selectedWorkspaceID
    }

    private var workspaceContext: String {
        catalog.selectedWorkspace?.path ?? "Workspace \(catalog.selectedWorkspaceID) unavailable"
    }

    private var windowTitle: String {
        let feature = catalog.featureTitle ?? featureTitle
        let workspace = catalog.selectedWorkspace?.title ?? catalog.selectedWorkspaceID
        return "\(feature) — \(workspace) — First Mate Git"
    }

    var loadIdentity: FirstMateGitLoadIdentity {
        .init(
            machineID: machineID,
            featureID: featureID,
            // The companion Git API is independent of the terminal connection.
            // A transient terminal disconnect must not restart this task and
            // discard the embedded web view while First Mate remains usable.
            configurationRevision: configurationRevision,
            url: configuration?.baseURL.absoluteString,
            token: configuration?.token,
            retryGeneration: retryGeneration
        )
    }
}

struct FirstMateGitWindowRoot: View {
    @Bindable var model: HerdrAppModel
    let driver: HerdrConnectionDriver
    let target: FirstMateGitWindowTarget

    var body: some View {
        FirstMateGitView(
            model: model,
            machineID: target.machineID,
            featureID: target.featureID,
            featureTitle: target.featureID,
            configuration: model.firstMateConfiguration(machineID: target.machineID),
            configurationRevision: model.machineConfigurationRevision(for: target.machineID),
            pinnedWorkspaceID: target.workspaceID
        )
        .frame(minWidth: 720, minHeight: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-git-window-\(target.id)")
        .onChange(of: model.connectionGeneration, initial: true) { _, _ in
            driver.syncConnection(model: model)
        }
        .onChange(of: model.hasCompletedSetup) { _, _ in
            driver.syncConnection(model: model)
        }
    }
}
