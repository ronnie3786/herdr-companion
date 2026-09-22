import AppKit
import SwiftUI

private struct FirstMateNavigationRequestIdentity: Equatable {
    let requestID: UUID?
    let controlMachineID: String?
    let controlFeatureID: String?
    let controlInspector: FirstMateInspector?
    let createMachineID: String?
}

private struct FirstMateDetailConnectionIdentity: Hashable {
    let machineID: String?
    let urlString: String?
    let token: String?
    let generation: Int
    let isDemo: Bool
}

private struct FirstMateFleetTaskIdentity: Hashable {
    struct Machine: Hashable {
        let id: String
        let name: String
        let urlString: String
        let token: String
    }

    let isDemo: Bool
    let generation: Int
    let machines: [Machine]
}

private struct PRReviewPollingIdentity: Equatable {
    let machineID: String?
    let reviewID: String?
    let generation: Int
    let isDemo: Bool
}

/// The Mac shell. This is the iPad-regular `NavigationSplitView` branch of the
/// iOS `WorkspaceNavigationView`, collapsed to two columns: the persistent
/// navigator (which the iPhone build showed as an overlay drawer) and a detail
/// column that swaps between the pane session, the workspace overview, and the
/// attention deck. There is no compact branch — the Mac is always regular.
struct WorkspaceNavigationView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Bindable var activeWorkStore: ActiveWorkStore
    let modelFavorites: ModelFavoritesStore
    let updates: HerdrUpdateController
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
                if shell.detailScope == .firstMate {
                    VStack(spacing: 0) {
                        if !model.isDemoMode {
                            Picker("Companion host", selection: firstMateScopeSelection) {
                                Text("All Machines").tag(FirstMateMachineScope.all)
                                ForEach(model.machines) { machine in
                                    Text(machine.name).tag(FirstMateMachineScope.machine(machine.id))
                                }
                            }.padding(12).accessibilityIdentifier("first-mate-host")
                        }
                        if resolvedFirstMateScope == .all, !model.isDemoMode {
                            FirstMateFleetSidebarView(
                                index: shell.firstMateFleet,
                                appearanceStore: shell.firstMate,
                                selectedMachineID: shell.activeFirstMateMachineID,
                                selectedFeatureID: shell.firstMate.selectedFeatureID,
                                createMachines: firstMateConfiguredMachines,
                                back: { shell.show(.session, model: model) },
                                openFeature: shell.openFirstMateFeatureFromFleet,
                                createFeature: shell.createFirstMateFeature,
                                refresh: { Task { await shell.firstMateFleet.refresh() } }
                            )
                        } else {
                            FirstMateSidebarView(store: shell.firstMate, back: { shell.show(.session, model: model) }, canControl: firstMateCanControl, leaveDemo: model.leaveDemo)
                        }
                    }
                } else if shell.detailScope == .prReview {
                    VStack(spacing: 0) {
                        if !model.isDemoMode {
                            Picker("PR review host", selection: Binding(get: { shell.prReviewMachineID ?? model.prReviewMachine?.id ?? "" }, set: { shell.prReviewMachineID = $0 })) {
                                ForEach(model.machines) { machine in Text(machine.name).tag(machine.id) }
                            }.padding(12).accessibilityIdentifier("pr-review-host")
                        }
                        PRReviewSidebarView(
                            store: shell.prReview,
                            back: { shell.show(.session, model: model) },
                            canControl: model.isDemoMode || prReviewConfiguration != nil,
                            openURL: { url in Task { try? await ActiveWorkLinkOpener.open(url) } },
                            setCreating: { shell.isCreatingPRReview = $0 },
                            popOut: { openWindow(id: HerdrWindowID.prReview, value: $0) }
                        )
                    }
                } else {
                    HerdrSidebarView(
                        model: model,
                        openPane: openSession,
                        openWorkspace: { shell.showWorkspace(id: $0.id, model: model) },
                        openFirstMate: { shell.show(.firstMate, model: model) },
                        openPRReview: { shell.show(.prReview, model: model) },
                        firstMateAttentionCount: firstMateAttentionCount
                    )
                    .background(HerdrTheme.ink)
                }
            }
            .navigationSplitViewColumnWidth(min: shell.detailScope == .firstMate || shell.detailScope == .prReview ? 210 : 240, ideal: shell.detailScope == .firstMate || shell.detailScope == .prReview ? 235 : 280, max: 480)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HerdrTheme.graphite)
                .toolbar { detailToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        .task(id: firstMateDetailConnectionIdentity) {
            // Connection changes own store configuration. The process-owned
            // guard also makes this safe when closing and recreating the main
            // window starts a fresh SwiftUI task for the same connection.
            shell.configureFirstMateIfNeeded(
                machineID: firstMateDetailMachineID,
                configuration: firstMateConfiguration,
                connectionGeneration: model.connectionGeneration,
                isDemo: model.isDemoMode
            )
            await shell.firstMate.refresh()
            await applyFirstMateNavigationRequest()
            if model.isDemoMode, ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateDemo") {
                shell.show(.firstMate, model: model)
            }
        }
        .task(id: firstMateFleetTaskIdentity) {
            // Connection-owned First Mate stores are reconciled on every roster
            // or credential change, whether or not First Mate is on screen.
            shell.reconcileFirstMateStores(
                configurations: firstMateConfigurations,
                connectionGeneration: model.connectionGeneration,
                isDemo: model.isDemoMode
            )
            // The Chat sidebar badge has to be visible without opening First
            // Mate, so observation runs independently of the selected
            // destination and the selected First Mate host. Demo mode owns no
            // live hosts: the empty roster also clears fleet data a previous
            // connection left behind.
            await shell.firstMateFleet.observe(
                sources: model.isDemoMode ? [] : firstMateFleetSources,
                connectionGeneration: model.connectionGeneration
            )
        }
        .task(id: PRReviewConnectionIdentity(configuration: prReviewConfiguration, generation: model.connectionGeneration, isDemo: model.isDemoMode, machineRevision: prReviewMachineID?.hashValue ?? model.prReviewMachineRevision)) {
            shell.configurePRReviewIfNeeded(configuration: prReviewConfiguration, machineID: prReviewMachineID, connectionGeneration: model.connectionGeneration, isDemo: model.isDemoMode)
            await shell.prReview.refresh()
            await applyPRReviewNavigationRequest()
        }
        .task(id: shell.prReviewOpenRequest?.id) {
            await applyPRReviewNavigationRequest()
        }
        .task(id: model.prReviewRefreshTick) {
            guard shell.prReview.hasLoaded else { return }
            await shell.prReview.refresh()
            await shell.prReview.refreshSelected()
        }
        .task(id: PRReviewPollingIdentity(
            machineID: shell.prReviewMachineID ?? model.prReviewMachine?.id,
            reviewID: shell.prReview.selectedReviewID,
            generation: model.connectionGeneration,
            isDemo: model.isDemoMode
        )) {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: shell.prReview.pollingInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await shell.prReview.refreshSelected()
            }
        }
        .task(id: FirstMateNavigationRequestIdentity(
            requestID: shell.firstMateOpenRequest?.id,
            controlMachineID: shell.pendingFirstMateControlTarget?.machineID,
            controlFeatureID: shell.pendingFirstMateControlTarget?.featureID,
            controlInspector: shell.pendingFirstMateControlTarget?.inspector,
            createMachineID: shell.pendingFirstMateCreateMachineID
        )) {
            await applyFirstMateNavigationRequest()
        }
        // Revealing a pane in a column the user has hidden would be a silent
        // no-op, so ⇧⌘K brings the navigator back first.
        .onChange(of: model.sidebarRevealToken) { _, token in
            guard token > 0 else { return }
            withAnimation(.snappy) { columnVisibility = .all }
        }
        .task(id: model.connectionGeneration) {
            activeWorkStore.resetForConnectionChange()
            await refreshActiveWork()
        }
        .task(id: model.activeWorkRefreshTick) {
            guard activeWorkStore.hasLoaded else { return }
            await refreshActiveWork()
        }
        .task(id: model.primaryConnectionState) {
            guard model.primaryConnectionState == .live || model.primaryConnectionState == .demo,
                  !activeWorkStore.hasLoaded || activeWorkStore.hasError else { return }
            await refreshActiveWork()
        }
    }

    private var resolvedFirstMateScope: FirstMateMachineScope {
        if model.isDemoMode { return .machine("demo") }
        if let scope = shell.firstMateScope {
            if case .machine(let machineID) = scope,
               !model.machines.contains(where: { $0.id == machineID }) {
                return model.machines.first.map { .machine($0.id) } ?? .all
            }
            return scope
        }
        return firstMateDetailMachineID.map(FirstMateMachineScope.machine) ?? .all
    }

    private var firstMateDetailMachineID: String? {
        if model.isDemoMode { return "demo" }
        if let machineID = shell.firstMateMachineID,
           model.machines.contains(where: { $0.id == machineID }) { return machineID }
        if case .machine(let machineID) = shell.firstMateScope,
           model.machines.contains(where: { $0.id == machineID }) { return machineID }
        return model.machines.first?.id
    }

    private var firstMateConfiguration: ServerConfiguration? {
        model.firstMateConfiguration(machineID: firstMateDetailMachineID)
    }

    private var activeFirstMateMachine: HerdrMachine? {
        guard let activeFirstMateMachineID = shell.activeFirstMateMachineID else { return nil }
        return model.machines.first { $0.id == activeFirstMateMachineID }
    }

    private var firstMateCanControl: Bool {
        firstMateConnectionIsReady && (model.isDemoMode || firstMateConfiguration != nil)
    }

    private var firstMateConnectionIsReady: Bool {
        shell.isActiveFirstMateConnection(
            machineID: firstMateDetailMachineID,
            configuration: firstMateConfiguration,
            connectionGeneration: model.connectionGeneration,
            isDemo: model.isDemoMode
        )
    }

    private var firstMateConfigurations: [String: ServerConfiguration] {
        Dictionary(uniqueKeysWithValues: model.machines.compactMap { machine in
            model.firstMateConfiguration(machineID: machine.id).map { (machine.id, $0) }
        })
    }

    private var firstMateConfiguredMachines: [HerdrMachine] {
        model.machines.filter { firstMateConfigurations[$0.id] != nil }
    }

    private var firstMateFleetSources: [FirstMateFleetSource] {
        firstMateConfiguredMachines.compactMap { machine in
            guard let configuration = firstMateConfigurations[machine.id] else { return nil }
            return FirstMateFleetSource(
                machine: machine,
                configuration: configuration,
                client: HerdrAPIClient(configuration: configuration)
            )
        }
    }

    private var firstMateDetailConnectionIdentity: FirstMateDetailConnectionIdentity {
        .init(
            machineID: firstMateDetailMachineID,
            urlString: firstMateConfiguration?.baseURL.absoluteString,
            token: firstMateConfiguration?.token,
            generation: model.connectionGeneration,
            isDemo: model.isDemoMode
        )
    }

    private var firstMateFleetTaskIdentity: FirstMateFleetTaskIdentity {
        .init(
            isDemo: model.isDemoMode,
            generation: model.connectionGeneration,
            machines: firstMateConfiguredMachines.compactMap { machine in
                guard let configuration = firstMateConfigurations[machine.id] else { return nil }
                return .init(
                    id: machine.id,
                    name: machine.name,
                    urlString: configuration.baseURL.absoluteString,
                    token: configuration.token
                )
            }
        )
    }

    /// What the Chat navigator badges beside First Mate.
    ///
    /// Live attention is counted from the unfiltered fleet index, so search
    /// text, machine scope, and the selected First Mate host never change it.
    /// Demo mode has no live hosts, so the same predicate counts the demo
    /// store's own synthetic features instead.
    private var firstMateAttentionCount: Int {
        if model.isDemoMode {
            return FirstMateAttention.count(features: shell.firstMate.features, machineID: "demo")
        }
        return shell.firstMateFleet.attentionCount
    }

    private var firstMateScopeSelection: Binding<FirstMateMachineScope> {
        Binding(
            get: { resolvedFirstMateScope },
            set: { shell.selectFirstMateScope($0) }
        )
    }

    private var prReviewMachineID: String? {
        shell.prReviewMachineID ?? (model.isDemoMode ? "demo" : model.prReviewMachine?.id)
    }

    private var prReviewConfiguration: ServerConfiguration? {
        model.prReviewConfiguration(machineID: prReviewMachineID)
    }

    private func applyPRReviewNavigationRequest() async {
        guard !Task.isCancelled,
              let request = shell.prReviewOpenRequest,
              request.id != shell.prReviewAppliedRequestID,
              model.isDemoMode || request.serverURL == prReviewConfiguration?.baseURL.absoluteString
        else { return }

        shell.prReview.tab = request.tab
        shell.prReview.select(request.reviewID)
        await shell.prReview.refreshSelected()
        guard !Task.isCancelled else { return }
        if let file = request.file {
            shell.prReview.selectedPath = file
            if let line = request.line {
                shell.prReview.scroll(to: file, line: line, side: request.side)
            }
        }
        shell.prReviewAppliedRequestID = request.id
    }

    private func applyFirstMateNavigationRequest() async {
        if !Task.isCancelled, let request = shell.firstMateOpenRequest,
           request.id != shell.firstMateAppliedRequestID,
           firstMateConnectionIsReady,
           request.serverURL == firstMateConfiguration?.baseURL.absoluteString {
            // A deeplink can race the connection task. Refreshing here is safe:
            // the connection task also applies the still-pending request after
            // its own configure/refresh completes.
            let store = shell.firstMate
            await store.refresh()
            if !Task.isCancelled,
               shell.firstMate === store,
               firstMateConnectionIsReady,
               shell.firstMateOpenRequest?.id == request.id {
                store.select(request.featureID)
                store.inspector = request.graph ? .workflow : request.tab
                store.graphMode = request.graph
                await store.refresh()
                if !Task.isCancelled,
                   shell.firstMate === store,
                   firstMateConnectionIsReady,
                   shell.firstMateOpenRequest?.id == request.id {
                    shell.firstMateAppliedRequestID = request.id
                }
            }
        }
        if !Task.isCancelled, let target = shell.pendingFirstMateControlTarget,
           target.machineID == firstMateDetailMachineID,
           firstMateConnectionIsReady,
           shell.firstMate.features.contains(where: { $0.id == target.featureID }) {
            shell.firstMate.select(target.featureID)
            shell.firstMate.inspector = target.inspector
            shell.firstMate.graphMode = target.inspector == .workflow
            shell.pendingFirstMateControlTarget = nil
        }
        if !Task.isCancelled, let machineID = shell.pendingFirstMateCreateMachineID,
           machineID == firstMateDetailMachineID,
           firstMateConnectionIsReady,
           firstMateCanControl {
            shell.firstMate.isCreating = true
            shell.pendingFirstMateCreateMachineID = nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch shell.resolvedScope(for: model) {
        // `.git` never survives `resolvedScope` — it is a pane sub-mode the
        // picker translates — but the switch still has to name it.
        case .session, .git:
            if let pane = model.pane(id: model.selectedPaneID) {
                PaneSessionView(
                    model: model, pane: pane, modelFavorites: modelFavorites,
                    preferredMode: shell.agentControlPaneMode ?? (shell.detailScope == .git ? .git
                        : (pane.supportsPiSemanticChat ? .chat : .terminal)),
                    modeFocusRequest: shell.paneModeFocusRequest,
                    modeApplied: { mode in
                        shell.agentControlPaneModeDidApply(mode, paneID: pane.id)
                    }
                )
                    .id(pane.id)
            } else {
                placeholder(
                    "Choose a pane",
                    symbol: "terminal",
                    detail: "Open a terminal or agent session."
                )
            }
        case .workspace:
            if let workspace = model.workspace(id: model.selectedWorkspaceID) {
                WorkspacePaneListView(
                    model: model,
                    workspace: workspace,
                    highlightedTabID: shell.highlightedOverviewTabID,
                    selectPane: openSession
                )
            } else {
                placeholder(
                    "Choose a workspace",
                    symbol: "rectangle.3.group",
                    detail: "Its tabs and panes will appear here."
                )
            }
        case .firstMate:
            FirstMateWorkspaceView(
                store: shell.firstMate,
                canControl: firstMateCanControl,
                owningMachineName: resolvedFirstMateScope == .all ? activeFirstMateMachine?.name : nil,
                allowsDirectCreate: resolvedFirstMateScope != .all
            )
            .id(shell.firstMateStoreID)
        case .prReview:
            PRReviewContainerView(
                store: shell.prReview,
                canControl: model.isDemoMode || prReviewConfiguration != nil,
                openURL: { url in Task { try? await ActiveWorkLinkOpener.open(url) } },
                askAI: { selection, view, rect in
                    guard let review = shell.prReview.selectedReview,
                          let machineID = shell.prReview.currentMachineID else { return }
                    Task { await model.presentPRReviewQuestion(machineID: machineID, review: review, selection: selection, anchor: (view, rect)) }
                },
                questionDraftChanged: { shell.hasPRReviewQuestionDraft = $0 },
                setCreating: { shell.isCreatingPRReview = $0 },
                openPane: { paneID, machineID in
                    shell.openPane(rawPaneID: paneID, machineID: machineID, model: model)
                },
                setAddingSkill: { shell.isAddingPRReviewSkill = $0 },
                popOut: { openWindow(id: HerdrWindowID.prReview, value: $0) },
                documentHost: model
            )
        case .activeWork:
            Group {
                if model.isDemoMode || model.activeWorkLegacyUI {
                    ActiveWorkContainerView(
                        store: activeWorkStore,
                        isControlEnabled: model.canControlPrimary,
                        refresh: refreshActiveWork,
                        createItem: createItem,
                        setupJira: setupJira,
                        transition: transition,
                        setLifecycle: setLifecycle,
                        openSession: openTrackedSession,
                        openURL: { url in
                            Task {
                                do {
                                    try await ActiveWorkLinkOpener.open(url)
                                } catch {
                                    model.toastMessage = error.localizedDescription
                                }
                            }
                        },
                        transcribeVoice: { try await model.transcribeVoiceNote(at: $0) },
                        askBoard: { question in
                            shell.presentAgent(prompt: activeWorkStore.agentPrompt(question: question))
                        }
                    )
                } else if let configuration = model.activeServerConfiguration {
                    ActiveWorkBoardWebView(
                        configuration: configuration,
                        openPane: { paneID, machineID in
                            shell.openPane(rawPaneID: paneID, machineID: machineID, model: model)
                        },
                        openExternal: { url in
                            Task {
                                do {
                                    try await ActiveWorkLinkOpener.open(url)
                                } catch {
                                    model.toastMessage = error.localizedDescription
                                }
                            }
                        },
                        copyText: { model.copyToPasteboard($0) },
                        popOut: { openWindow(id: HerdrWindowID.activeWorkBoard) },
                        spawnReview: { payload in
                            Task { await model.spawnPrReviewSession(payload) }
                        }
                    )
                    .accessibilityIdentifier("active-work-container")
                } else {
                    ActiveWorkBoardEmptyStateView()
                        .accessibilityIdentifier("active-work-container")
                }
            }
        case .fleet:
            FleetManagementSheet(model: model, isEmbedded: true)
        case .attention:
            AttentionView(model: model) { pane, _ in
                openSession(pane)
            }
        case .activity:
            ActivityFeedView(model: model, selectPane: openSession)
        }
    }

    /// Every "open this pane" affordance goes through here. Assigning
    /// `selectedPaneID` alone is not enough: when the pane is already selected
    /// the assignment is a no-op and the detail would stay on whatever scope
    /// the user is looking at.
    private func openSession(_ pane: HerdrPane) {
        shell.openPane(id: pane.id, model: model)
    }

    private func openTrackedSession(_ session: ActiveWorkPiSession) {
        guard let paneID = session.paneID else { return }
        shell.openPane(rawPaneID: paneID, machineID: session.machineID, model: model)
    }

    private func refreshActiveWork() async {
        await activeWorkStore.refresh {
            try await model.fetchActiveWork()
        }
    }

    private func setupJira(_ candidate: ActiveWorkJiraCandidate) async throws {
        _ = try await model.setupActiveWorkJira(key: candidate.key)
        await refreshActiveWork()
    }

    private func createItem(kind: String, title: String, summary: String) async throws {
        _ = try await model.createActiveWorkItem(kind: kind, title: title, summary: summary)
        await refreshActiveWork()
    }

    private func transition(
        _ item: ActiveWorkItem,
        _ target: ActiveWorkPipelineStage
    ) async throws {
        _ = try await model.transitionActiveWorkItem(item, to: target)
        await refreshActiveWork()
    }

    private func setLifecycle(_ item: ActiveWorkItem, _ lifecycle: String) async throws {
        _ = try await model.setActiveWorkLifecycle(item, lifecycle: lifecycle)
        await refreshActiveWork()
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 2) {
                historyButton(
                    symbol: "chevron.left",
                    label: "Back",
                    help: "Go back to the previous pane or screen",
                    identifier: "nav-history-back",
                    isEnabled: shell.canGoBack
                ) { shell.goBack(model: model) }

                historyButton(
                    symbol: "chevron.right",
                    label: "Forward",
                    help: "Go forward",
                    identifier: "nav-history-forward",
                    isEnabled: shell.canGoForward
                ) { shell.goForward(model: model) }
            }
            .accessibilityIdentifier("nav-history-controls")
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .principal) {
            if shell.detailScope == .firstMate {
                Label("First Mate", systemImage: "sailboat")
                    .foregroundStyle(.primary)
            } else if shell.detailScope == .prReview {
                Label("PR Review", systemImage: HerdrDetailScope.prReview.symbol)
                    .foregroundStyle(.primary)
            } else {
                WorkspaceScopePicker(
                    selection: scopeSelection,
                    includesGit: model.currentPaneGitIsAvailable,
                    unreadAlertCount: model.unreadAlertCount
                )
            }
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            Button("Agent", systemImage: "sparkles") {
                shell.isAgentPresented = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(shell.detailScope == .firstMate ? FirstMatePalette(scheme: shell.firstMate.colorScheme).secondaryText : HerdrTheme.mist)
            .herdrHitTarget()
            .disabled(!model.canControl)
            .help("Ask a one-off question without creating a chat")
            .accessibilityIdentifier("open-headless-agent")
        }
        .sharedBackgroundVisibility(.hidden)

        // Appears only while a check has a newer release to offer, so updating
        // never requires the menu bar.
        ToolbarItem(placement: .primaryAction) {
            HerdrUpdateToolbarItem(updates: updates)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            HerdPulseButton()
                .buttonStyle(.plain)
                .herdrHitTarget()
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            ConnectionPill(state: model.connectionState)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// Reads the resolved scope when the picker has a matching segment, and
    /// otherwise returns nil so dedicated destinations leave every segment
    /// unselected. Writes are limited to actual picker cases.
    private var scopeSelection: Binding<HerdrDetailScope?> {
        Binding(
            get: {
                let resolved = shell.resolvedScope(for: model)
                // Git is a pane sub-mode wearing a segment: it only reads as
                // selected while the mounted session is actually showing Git.
                if resolved == .session, model.currentPaneDetailMode == .git {
                    return .git
                }
                return HerdrDetailScope.pickerSelection(for: resolved)
            },
            set: { scope in
                guard let scope = scope,
                      HerdrDetailScope.pickerSelection(for: scope) != nil else { return }
                shell.show(scope, model: model)
            }
        )
    }

    private func historyButton(
        symbol: String, label: String, help: String,
        identifier: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .herdrHitTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(shell.detailScope == .firstMate ? FirstMatePalette(scheme: shell.firstMate.colorScheme).secondaryText : isEnabled ? HerdrTheme.mist : HerdrTheme.muted)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func placeholder(_ title: String, symbol: String, detail: String) -> some View {
        ZStack {
            HerdrBackground()

            ContentUnavailableView(
                title,
                systemImage: symbol,
                description: Text(detail)
            )
        }
    }
}
