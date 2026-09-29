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
    @State private var selectedCommitSHA: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale

    init(
        model: HerdrAppModel,
        machineID: String,
        featureID: String,
        featureTitle: String,
        configuration: ServerConfiguration?,
        configurationRevision: Int,
        pinnedWorkspaceID: String? = nil,
        initialWorkspaceID: String? = nil,
        initialCommitSHA: String? = nil,
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
        _selectedCommitSHA = State(initialValue: initialCommitSHA)
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

    /// A 36pt bar: feature title over "machine · workspace · path", the
    /// workspace picker, pop-out and refresh. It follows First Mate's palette
    /// (light or dark); the Git content below stays dark.
    private var contextBar: some View {
        let palette = FirstMatePalette(scheme: scheme)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(catalog.featureTitle ?? featureTitle)
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text("\(machineName) · \(workspaceTitle) · \(workspaceContext)")
                    .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: true)
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("first-mate-git-workspace-context")
            }
            Spacer(minLength: 8)
            if catalog.phase == .ready, !catalog.isPinned {
                Menu {
                    ForEach(primaryWorkspaces) { workspace in
                        workspaceButton(workspace)
                    }
                    if !otherWorkspaces.isEmpty {
                        Menu("Other checkouts (\(otherWorkspaces.count))") {
                            ForEach(otherWorkspaces) { workspace in
                                workspaceButton(workspace)
                            }
                        }
                    }
                } label: {
                    Text(catalog.selectedWorkspace?.title ?? "Choose checkout…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .controlSize(.small)
                .frame(maxWidth: 360)
                .help("Choose a repository checkout. Assignments that share a checkout appear once.")
                .accessibilityLabel("Git checkout")
                .accessibilityIdentifier("first-mate-git-workspace-picker")
                if let popOut, catalog.selectedWorkspace != nil {
                    Button("Open Git in New Window", systemImage: "macwindow.badge.plus") {
                        popOut(target)
                    }
                    .buttonStyle(FirstMateGitIconButtonStyle(palette: palette))
                    .help("Open Git in New Window")
                    .accessibilityLabel("Open Git in New Window")
                    .accessibilityIdentifier("first-mate-git-open-window")
                }
            }
            Button("Refresh Git workspaces", systemImage: "arrow.clockwise") {
                retryGeneration &+= 1
            }
            .buttonStyle(FirstMateGitIconButtonStyle(palette: palette))
            .help("Refresh Git workspaces")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .frame(minHeight: HerdrTheme.ControlHeight.bar * fontScale.rawValue)
        .background(palette.surface)
        .herdrHairline(.bottom, color: palette.hairline)
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
                // Git keeps the dark code palette in either appearance, so its
                // surfaces and text resolve dark beside it.
                .environment(\.colorScheme, .dark)
            } else if let configuration {
                // A healthy authenticated API is sufficient. First Mate Git
                // does not depend on a live terminal-pane connection.
                PaneGitWebView(configuration: configuration, firstMateTarget: target)
                    .id("\(target.id)|\(configurationRevision)|\(configuration.baseURL.absoluteString)")
                    .environment(\.colorScheme, .dark)
            } else {
                unavailable(
                    "Machine unavailable",
                    detail: "The owning machine is no longer configured. Add it again, then retry."
                )
            }
        } else if catalog.selectedWorkspaceID.isEmpty {
            ContentUnavailableView {
                Label("Choose a checkout", systemImage: "arrow.triangle.branch")
            } description: {
                Text(catalog.selectionMessage ?? "Choose the feature branch from the checkout menu above.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailable(
                "Workspace unavailable",
                detail: "Workspace \(catalog.selectedWorkspaceID) is not available for this feature. The window remains pinned to that exact target."
            )
        }
    }

    private var primaryWorkspaces: [FirstMateGitWorkspace] {
        catalog.workspaces.filter {
            $0.id == catalog.recommendedWorkspaceID || $0.id == "project"
        }.sorted { $0.id == catalog.recommendedWorkspaceID && $1.id != catalog.recommendedWorkspaceID }
    }

    private var otherWorkspaces: [FirstMateGitWorkspace] {
        catalog.workspaces.filter {
            $0.id != catalog.recommendedWorkspaceID && $0.id != "project"
        }
    }

    private func workspaceButton(_ workspace: FirstMateGitWorkspace) -> some View {
        Button {
            catalog.selectWorkspace(id: workspace.id)
            selectedCommitSHA = nil
            workspaceSelectionChanged?(workspace.id)
        } label: {
            if workspace.matches(catalog.selectedWorkspaceID) {
                Label(workspace.title, systemImage: "checkmark")
            } else {
                Text(workspace.title)
            }
        }
        .help(workspace.path)
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading Git workspaces…")
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(FirstMatePalette(scheme: scheme).secondaryText)
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
        .init(machineID: machineID, featureID: featureID, workspaceID: catalog.selectedWorkspaceID, commitSHA: selectedCommitSHA)
    }

    private var machineName: String {
        model.machines.first { $0.id == machineID }?.name ?? machineID
    }

    private var isDemoTarget: Bool {
        model.isDemoMode && machineID == "demo"
    }

    private var workspaceTitle: String {
        catalog.selectedWorkspace?.title ?? "Choose checkout"
    }

    private var workspaceContext: String {
        catalog.selectedWorkspace?.path ?? "No checkout selected"
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

/// `HerdrIconButtonStyle` in First Mate's palette, so the bar's icons keep
/// their contrast in First Mate light: 26pt glyph box on a 28pt hit area,
/// icon ink at rest, text ink and a selection wash while hovered.
private struct FirstMateGitIconButtonStyle: ButtonStyle {
    let palette: FirstMatePalette

    func makeBody(configuration: Configuration) -> some View {
        FirstMateGitIconButtonBody(configuration: configuration, palette: palette)
    }
}

private struct FirstMateGitIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let palette: FirstMatePalette
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .herdrFont(size: 14)
            .foregroundStyle(isHovering ? palette.text : palette.iconTint)
            .frame(width: HerdrTheme.ControlHeight.regular, height: HerdrTheme.ControlHeight.regular)
            .background(
                isHovering || configuration.isPressed ? palette.selectedFill : .clear,
                in: .rect(cornerRadius: HerdrTheme.Radius.control)
            )
            .frame(minWidth: HerdrTheme.minHitTarget, minHeight: HerdrTheme.minHitTarget)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { isHovering = $0 }
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
            pinnedWorkspaceID: target.workspaceID,
            initialCommitSHA: target.commitSHA
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
