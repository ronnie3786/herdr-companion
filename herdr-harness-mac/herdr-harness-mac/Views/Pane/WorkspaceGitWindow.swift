import SwiftUI

struct WorkspaceGitWindowTarget: Codable, Hashable, Identifiable, Sendable {
    let machineID: String
    let workspaceID: String
    let paneID: String

    var scopedPaneID: String {
        MachineScopedID.compose(machineID: machineID, rawID: paneID)
    }

    var id: String {
        [machineID, workspaceID, paneID].joined(separator: "|")
    }

    init(machineID: String, workspaceID: String, paneID: String) {
        self.machineID = machineID
        self.workspaceID = workspaceID
        self.paneID = paneID
    }

    init(pane: HerdrPane) {
        self.init(machineID: pane.machineID, workspaceID: pane.workspaceID, paneID: pane.paneID)
    }

    func resolve(in workspaces: [HerdrWorkspace]) -> WorkspaceGitWindowRoute? {
        guard let workspace = workspaces.first(where: {
            $0.machineID == machineID && $0.workspaceID == workspaceID
        }), let pane = workspace.panes.first(where: {
            $0.id == scopedPaneID && $0.workspaceID == workspaceID
        }) else { return nil }
        return WorkspaceGitWindowRoute(workspace: workspace, pane: pane)
    }
}

struct WorkspaceGitWindowRoute: Equatable {
    let workspace: HerdrWorkspace
    let pane: HerdrPane
}

struct WorkspaceGitWindowRoot: View {
    @Bindable var model: HerdrAppModel
    let driver: HerdrConnectionDriver
    let target: WorkspaceGitWindowTarget

    @State private var gitAvailability: PaneGitAvailability = .checking
    @State private var probeErrorMessage: String?
    @State private var retryGeneration = 0

    var body: some View {
        Group {
            if let route {
                gitContent(route)
            } else if isConnecting {
                loadingView("Connecting to \(machineName)…")
            } else if connectionState == .disconnected || connectionState == .failed {
                unavailableView(
                    title: "Machine unavailable",
                    detail: "\(machineName) is \(connectionState.title.lowercased()). Herdr will retry automatically."
                )
            } else {
                unavailableView(
                    title: "Workspace unavailable",
                    detail: "This Git window’s workspace or pane is no longer available on \(machineName)."
                )
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(HerdrTheme.ink)
        .foregroundStyle(HerdrTheme.text)
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
        .navigationTitle(windowTitle)
        .onChange(of: model.connectionGeneration, initial: true) { _, _ in
            driver.syncConnection(model: model)
        }
        .onChange(of: model.hasCompletedSetup) { _, _ in
            driver.syncConnection(model: model)
        }
        .task(id: probeTaskID) {
            await followGitAvailability()
        }
    }

    @ViewBuilder
    private func gitContent(_ route: WorkspaceGitWindowRoute) -> some View {
        if model.isDemoMode {
            WorkspaceGitView(
                workspace: route.workspace,
                loadStatus: { try await model.fetchGitStatus(for: route.workspace) },
                loadDiff: { file, section in
                    try await model.fetchGitDiff(for: route.workspace, file: file, section: section)
                },
                stageFile: { file in try await model.stageGitFile(file, in: route.workspace) },
                unstageFile: { file in try await model.unstageGitFile(file, in: route.workspace) }
            )
        } else if gitAvailability == .available,
                  let configuration = model.serverConfiguration(for: route.pane) {
            PaneGitWebView(
                configuration: configuration,
                workspaceID: target.workspaceID,
                paneID: target.paneID
            )
            .id("\(target.id)|\(route.pane.displayPath)|\(model.connectionGeneration)")
        } else if gitAvailability == .checking, let probeErrorMessage {
            unavailableView(
                title: "Git unavailable",
                detail: "\(probeErrorMessage) Herdr will retry automatically."
            )
        } else if gitAvailability == .checking || isConnecting {
            loadingView("Checking this pane for Git…")
        } else {
            unavailableView(
                title: "Git unavailable",
                detail: "This pane is not currently inside a Git repository."
            )
        }
    }

    private func loadingView(_ message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .herdrFont(.caption, monospaced: true, weight: .medium)
                .foregroundStyle(HerdrTheme.mist)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func unavailableView(title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: PaneDetailMode.git.symbol)
        } description: {
            Text(detail)
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise") {
                retryGeneration &+= 1
            }
            .herdrProminentButton()
        }
        .foregroundStyle(HerdrTheme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var route: WorkspaceGitWindowRoute? {
        target.resolve(in: model.workspaces)
    }

    private var machineName: String {
        model.machines.first(where: { $0.id == target.machineID })?.name ?? "the selected machine"
    }

    private var windowTitle: String {
        route.map { "\($0.workspace.label) Git" } ?? "Workspace Git"
    }

    private var isConnecting: Bool {
        guard model.hasCompletedSetup,
              model.machines.contains(where: { $0.id == target.machineID })
        else { return false }
        return model.connectionState(forMachine: target.machineID) == .connecting
    }

    private var connectionState: ConnectionState {
        model.connectionState(forMachine: target.machineID)
    }

    private var probeTaskID: String {
        let routeID = route?.pane.id ?? "missing"
        let connection = model.connectionState(forMachine: target.machineID).title
        return "\(target.id):\(routeID):\(model.connectionGeneration):\(connection):\(retryGeneration)"
    }

    private func followGitAvailability() async {
        if model.isDemoMode {
            gitAvailability = .available
            probeErrorMessage = nil
            return
        }

        gitAvailability = .checking
        while !Task.isCancelled {
            guard let pane = target.resolve(in: model.workspaces)?.pane else {
                gitAvailability = isConnecting ? .checking : .unavailable
                do {
                    try await Task.sleep(for: PaneGitProbePolicy.refreshInterval)
                } catch {
                    return
                }
                continue
            }

            do {
                let status = try await model.fetchGitStatus(for: pane)
                try Task.checkCancellation()
                probeErrorMessage = nil
                gitAvailability = PaneGitProbePolicy.availability(
                    after: .status(ok: status.ok, rootPath: status.cwd),
                    preserving: gitAvailability
                )
            } catch APIError.server(let status, _) where status == 404 {
                guard !Task.isCancelled else { return }
                probeErrorMessage = nil
                gitAvailability = PaneGitProbePolicy.availability(
                    after: .notFound,
                    preserving: gitAvailability
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                probeErrorMessage = error.localizedDescription
                gitAvailability = PaneGitProbePolicy.availability(
                    after: .transientFailure,
                    preserving: gitAvailability
                )
            }

            do {
                try await Task.sleep(for: PaneGitProbePolicy.refreshInterval)
            } catch {
                return
            }
        }
    }
}
