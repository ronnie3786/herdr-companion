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

private struct PRReviewPollingIdentity: Equatable {
    let machineID: String?
    let reviewID: String?
    let generation: Int
    let isDemo: Bool
}

/// The Mac shell. This is the iPad-regular `NavigationSplitView` branch of the
/// iOS `WorkspaceNavigationView`, collapsed to two columns: the persistent
/// navigator (which the iPhone build showed as an overlay drawer) and a detail
/// column that swaps between the pane session and the app's other screens.
/// There is no compact branch — the Mac is always regular.
struct WorkspaceNavigationView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    let modelFavorites: ModelFavoritesStore
    let updates: HerdrUpdateController
    /// Render tests only: a detail view that cannot be reached with demo data
    /// (a populated Pi transcript) in place of the routed screen.
    var detailOverride: AnyView?
    @State private var columnVisibility = NavigationSplitViewVisibility.detailOnly
    @State private var appliedSidebarVisibility = NavigationSplitViewVisibility.detailOnly
    @Environment(\.openWindow) private var openWindow

    @AppStorage("herdr.shell.sidebarWidth") private var storedSidebarWidth = Double(HerdrTheme.sidebarWidth)
    @State private var liveSidebarWidth: Double?
    @State private var hasPlacedSidebar = false
    @Environment(\.herdrWindowIsFullScreen) private var isFullScreen

    private static let sidebarWidthRange = 240.0...480.0

    private var isSidebarVisible: Bool { columnVisibility != .detailOnly }

    private var sidebarWidth: CGFloat {
        CGFloat(min(max(liveSidebarWidth ?? storedSidebarWidth, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound))
    }

    /// First Mate carries its own light or dark appearance into the chrome.
    private var firstMatePalette: FirstMatePalette? {
        shell.detailScope == .firstMate ? FirstMatePalette(scheme: shell.firstMate.colorScheme) : nil
    }

    private var chromeHairline: Color { firstMatePalette?.hairline ?? HerdrTheme.hairline }
    private var chromeTitle: Color { firstMatePalette?.text ?? HerdrTheme.primaryText }
    private var chromeIcon: Color { firstMatePalette?.iconTint ?? HerdrTheme.iconTint }
    private var railBackground: Color { firstMatePalette?.sidebar ?? HerdrTheme.railBackground }
    private var detailBackground: Color { firstMatePalette?.background ?? HerdrTheme.windowBackground }

    /// MonoCode's frame: a flush 260pt rail and a detail column, each topped by
    /// a 40pt bar that lines up with the window's traffic lights. Replaces the
    /// system split view, whose floating glass sidebar could not be drawn flush
    /// or rendered offscreen.
    private var navigationContent: some View {
        HStack(spacing: 0) {
            if isSidebarVisible && !(shell.homeEnabled && shell.detailScope == .watchers) {
                sidebarColumn
                    .frame(width: sidebarWidth)
                    .background { HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: railBackground) }
                    .herdrHairline(.trailing, color: chromeHairline)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            detailColumn
        }
        // Above both columns, so the whole 6pt strip across the rail's edge
        // can be grabbed (the detail column would otherwise take half of it).
        .overlay(alignment: .leading) {
            if isSidebarVisible && !(shell.homeEnabled && shell.detailScope == .watchers) {
                sidebarResizeHandle
                    .offset(x: sidebarWidth - 3)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        // Our 40pt bars end in a hairline; the system's toolbar blur under the
        // title bar would smear content behind them.
        .scrollEdgeEffectHidden()
        // Home screens start without the sidebar and other screens with it, but
        // a person's own toggle is remembered per context instead of being
        // overwritten on every navigation.
        .onChange(of: shell.detailScope.sidebarContext, initial: true) { _, context in
            // First Mate and PR Review keep their host and list rail on screen.
            let preferred = context == .rail ? .all : shell.sidebarVisibility(home: context == .home)
            if columnVisibility != preferred {
                appliedSidebarVisibility = preferred
                // The window opens with its rail already in place; later
                // context switches slide it.
                if hasPlacedSidebar {
                    withAnimation(.snappy(duration: 0.22)) { columnVisibility = preferred }
                } else {
                    columnVisibility = preferred
                }
            }
            hasPlacedSidebar = true
        }
        .onChange(of: columnVisibility) { _, visibility in
            guard visibility != appliedSidebarVisibility else { return }
            appliedSidebarVisibility = visibility
            let context = shell.detailScope.sidebarContext
            if context != .rail { shell.rememberSidebarVisibility(visibility, home: context == .home) }
        }
        .onChange(of: shell.sidebarToggleRequest) { _, _ in toggleSidebar() }
        .onChange(of: shell.sidebarShowRequest) { _, _ in columnVisibility = .all }
        .onAppear { shell.recordVisit(for: model) }
    }

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.22)) {
            columnVisibility = isSidebarVisible ? .detailOnly : .all
        }
    }

    /// The header is an overlay, like the title bar: a child's background may
    /// extend into the window's top safe area, and must not paint over it.
    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            chromeBarSpacer
            Group {
                if shell.detailScope == .firstMate {
                    VStack(spacing: 0) {
                        if !model.isDemoMode {
                            sidebarHostPicker(
                                title: firstMateHostTitle,
                                accessibilityLabel: "Companion host",
                                identifier: "first-mate-host"
                            ) {
                                Picker("Companion host", selection: firstMateScopeSelection) {
                                    Text("All Machines").tag(FirstMateMachineScope.all)
                                    ForEach(model.machines) { machine in
                                        Text(machine.name).tag(FirstMateMachineScope.machine(machine.id))
                                    }
                                }
                                .pickerStyle(.inline)
                            }
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
                                refresh: { Task { await shell.firstMateFleet.refresh() } },
                                startSession: { shell.showFirstMateStart() },
                                manageProjects: shell.showFirstMateProjects,
                                surface: shell.firstMateSurface
                            )
                        } else {
                            FirstMateSidebarView(
                                store: shell.firstMate, back: { shell.show(.session, model: model) },
                                canControl: firstMateCanControl, leaveDemo: model.leaveDemo,
                                startSession: { shell.showFirstMateStart(preferredMachineID: firstMateDetailMachineID) },
                                manageProjects: shell.showFirstMateProjects,
                                openFeature: { featureID in
                                    shell.firstMate.select(featureID)
                                    shell.firstMateSurface = .workspace
                                },
                                surface: shell.firstMateSurface
                            )
                        }
                    }
                } else if shell.detailScope == .prReview {
                    VStack(spacing: 0) {
                        if !model.isDemoMode {
                            sidebarHostPicker(
                                title: prReviewHostTitle,
                                accessibilityLabel: "PR review host",
                                identifier: "pr-review-host"
                            ) {
                                Picker("PR review host", selection: prReviewScopeSelection) {
                                    Text(PRReviewHostScope.allMachinesTitle).tag(PRReviewHostScope.all)
                                    ForEach(model.machines) { machine in
                                        Text(machine.name).tag(PRReviewHostScope.machine(machine.id))
                                    }
                                }
                                .pickerStyle(.inline)
                            }
                        }
                        PRReviewSidebarView(
                            store: shell.prReview,
                            back: { shell.show(.session, model: model) },
                            canControl: model.isDemoMode || prReviewCreationConfiguration != nil,
                            openURL: { url in Task { try? await HerdrExternalLinkOpener.open(url) } },
                            setCreating: setPRReviewCreating,
                            popOut: { openWindow(id: HerdrWindowID.prReview, value: $0) },
                            fleet: prReviewFleetIsVisible ? shell.prReviewFleet : nil,
                            openFleetReview: { shell.openPRReviewFromFleet($0, model: model) },
                            archiveFleetReview: { target, archived in
                                Task { await performPRReviewFleetAction(target) { try await shell.archivePRReviewFromFleet(target, archived: archived) } }
                            },
                            refreshFleetReview: { target in
                                Task { await performPRReviewFleetAction(target) { try await shell.prReviewFleet.refreshReview(target) } }
                            },
                            revealRequest: shell.homeReviewRevealRequest,
                            onRevealHandled: { id in
                                if shell.homeReviewRevealRequest?.id == id { shell.homeReviewRevealRequest = nil }
                            },
                            searchFocusRequest: shell.surfaceSearchFocusRequest
                        )
                    }
                } else {
                    HerdrSidebarView(
                        model: model,
                        openPane: openSession,
                        openDashboard: { shell.goHome(model: model) },
                        openFirstMate: { shell.show(.firstMate, model: model) },
                        openPRReview: { shell.show(.prReview, model: model) },
                        openWatchers: { shell.show(.watchers, model: model) },
                        watchersUnreadCount: shell.watchers.unreadCount,
                        watchersSelected: shell.detailScope == .watchers,
                        firstMateAttentionCount: firstMateAttentionCount,
                        prReviewWalkthroughCount: shell.prReview.walkthroughAttentionCount,
                        showsHeader: false,
                        searchFocusRequest: shell.surfaceSearchFocusRequest
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .overlayPreferenceValue(HerdrRailHeaderActionsKey.self, alignment: .top) { actions in
            sidebarHeader(actions: actions)
        }
    }

    /// The rail's 40pt header: room for the traffic lights, the context's
    /// name, and the sidebar toggle.
    private func sidebarHeader(actions: AnyView?) -> some View {
        HStack(spacing: 7) {
            switch shell.detailScope {
            case .firstMate:
                Image(systemName: "sailboat")
                    .herdrFont(size: 15)
                    .foregroundStyle(firstMatePalette?.accent ?? HerdrTheme.accent)
                    .accessibilityHidden(true)
                Text("First Mate")
            case .prReview:
                Image(systemName: HerdrDetailScope.prReview.symbol)
                    .herdrFont(size: 14)
                    .foregroundStyle(HerdrTheme.accent)
                    .accessibilityHidden(true)
                Text("PR Review")
            default:
                HerdrBrandMark(size: 17)
                Text("herdr")
            }
            Spacer(minLength: 4)
            if let actions {
                HStack(spacing: 2) { actions }
            }
            sidebarToggleButton
        }
        .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
        .foregroundStyle(chromeTitle)
        .lineLimit(1)
        .padding(.leading, (isFullScreen || shell.homeEnabled) ? 13 : HerdrWindowChrome.trafficLightInset)
        .padding(.trailing, 6)
        .herdrBar(hairline: .clear)
        .accessibilityElement(children: .contain)
    }

    /// The 40pt band under a bar overlay plus its hairline as a real 1pt row.
    /// On macOS 26 a scroll view whose top edge meets the window's title-bar
    /// edge extends under the bar with a 40pt inset and a blurred scroll
    /// pocket; the hairline row keeps every column's content clear of it.
    private var chromeBarSpacer: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: HerdrTheme.ControlHeight.titleBar)
            Rectangle().fill(chromeHairline).frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    private var sidebarToggleButton: some View {
        Button(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
            toggleSidebar()
        }
        .buttonStyle(HerdrIconButtonStyle(tint: chromeIcon))
        .help(isSidebarVisible ? "Hide sidebar (Control-Command-S)" : "Show sidebar (Control-Command-S)")
        .accessibilityIdentifier("sidebar-toggle")
    }

    /// A 36pt band under the header holding a borderless host menu.
    private func sidebarHostPicker<Items: View>(
        title: String,
        accessibilityLabel: String,
        identifier: String,
        @ViewBuilder items: () -> Items
    ) -> some View {
        HStack {
            Menu {
                items()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .herdrFont(size: 14)
                        .foregroundStyle(chromeIcon)
                    Text(title)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .herdrFont(size: 10, weight: .semibold)
                        .foregroundStyle(chromeIcon)
                }
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(firstMatePalette?.secondaryText ?? HerdrTheme.secondaryText)
                .padding(.horizontal, 6)
                .frame(height: HerdrTheme.ControlHeight.small)
                .frame(minHeight: HerdrTheme.minHitTarget)
                .contentShape(Rectangle())
            }
            .piChipMenu()
            .fixedSize()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(title)
            .accessibilityIdentifier(identifier)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: HerdrTheme.ControlHeight.bar)
        .herdrHairline(.bottom, color: chromeHairline)
    }

    private var firstMateHostTitle: String {
        switch resolvedFirstMateScope {
        case .all: "All Machines"
        case let .machine(id): model.machines.first { $0.id == id }?.name ?? "All Machines"
        }
    }

    private var prReviewHostTitle: String {
        Self.prReviewHostTitle(scope: resolvedPRReviewScope, machines: model.machines)
    }

    static func prReviewHostTitle(scope: PRReviewHostScope, machines: [HerdrMachine]) -> String {
        switch scope {
        case .all: PRReviewHostScope.allMachinesTitle
        case .machine(let id): machines.first { $0.id == id }?.name ?? "Choose a host"
        }
    }

    /// A 6pt grab strip on the rail's edge; the width persists across launches.
    private var sidebarResizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = storedSidebarWidth
                        liveSidebarWidth = min(max(start + value.translation.width, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
                    }
                    .onEnded { _ in
                        if let liveSidebarWidth { storedSidebarWidth = liveSidebarWidth }
                        liveSidebarWidth = nil
                    }
            )
            // VoiceOver and keyboard users resize the rail too, as they could
            // the system split view's divider.
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(sidebarWidth)) points")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 20 : direction == .decrement ? -20 : 0
                storedSidebarWidth = min(max(storedSidebarWidth + step, Self.sidebarWidthRange.lowerBound),
                                         Self.sidebarWidthRange.upperBound)
            }
            .accessibilityIdentifier("sidebar-resize-handle")
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            chromeBarSpacer
            if updates.isBannerVisible, let version = updates.availableVersion {
                HerdrUpdateBanner(version: version, updates: updates)
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.herdrHostsTitleBar, true)
        }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, base: detailBackground) }
        .overlayPreferenceValue(HerdrTitleBarItemsKey.self, alignment: .top) { items in
            titleBar(items)
        }
    }

    var body: some View {
        navigationContent
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
        .onChange(of: shell.firstMate.features.filter { !$0.isArchived }.map(\.id)) { old, new in
            if old.contains(where: { !new.contains($0) }) {
                Task { await shell.firstMateFleet.refresh() }
            }
        }
        // Fleet observation and store reconciliation belong to the process
        // (`FirstMateFleetDriver`, started from `AppRootView`), so the badge,
        // the Dock, and the chat window keep updating after this window closes.
        .task(id: FirstMateFleetRoster.current(model: model).identity) {
            guard !FirstMateFleetDriver.isHostedByTests else { return }
            let roster = FirstMateFleetRoster.current(model: model)
            let demo = roster.isDemo
            let sources = roster.sources { HerdrAPIClient(configuration: $0) }
            await shell.firstMateProjects.observe(sources: sources, demo: demo, validateConnection: { connection in
                model.isDemoMode == demo && (demo || model.firstMateConfiguration(machineID: connection.machineID) == connection.configuration)
            })
        }
        .task(id: PRReviewConnectionIdentity(configuration: prReviewConfiguration, generation: model.connectionGeneration, isDemo: model.isDemoMode, machineRevision: prReviewMachineID?.hashValue ?? model.prReviewMachineRevision)) {
            shell.attachPRReviewCommentStore(model.prReviewComments)
            shell.configurePRReviewIfNeeded(configuration: prReviewConfiguration, machineID: prReviewMachineID, connectionGeneration: model.connectionGeneration, isDemo: model.isDemoMode)
            await shell.prReview.refresh()
        }
        .task(id: model.prReviewRefreshTick) {
            await shell.refreshPRReviews(refreshFleet: false)
        }
        .task(id: PRReviewPollingIdentity(
            machineID: shell.prReviewMachineID ?? model.prReviewMachine?.id,
            reviewID: shell.prReview.selectedReviewID,
            generation: model.connectionGeneration,
            isDemo: model.isDemoMode
        )) {
            await shell.prReview.refreshSelected()
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
            // A reveal is a one-off, not the person's saved choice.
            appliedSidebarVisibility = .all
            withAnimation(.snappy) { columnVisibility = .all }
        }
    }

    private var resolvedFirstMateScope: FirstMateMachineScope {
        if model.isDemoMode { return .machine("demo") }
        return FirstMateMachineScope.resolved(
            shell.firstMateScope,
            availableMachineIDs: model.machines.map(\.id)
        )
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

    /// The selected snapshot belongs only to the store's active machine. A
    /// removed or swapping owner never falls through to the detail selector or
    /// primary machine, because that could send its feature ID to another host.
    private var firstMateGitOwnerMachineID: String? {
        if model.isDemoMode { return "demo" }
        guard let machineID = shell.activeFirstMateMachineID,
              model.machines.contains(where: { $0.id == machineID })
        else { return nil }
        return machineID
    }

    private var firstMateGitConfiguration: ServerConfiguration? {
        guard let machineID = firstMateGitOwnerMachineID, !model.isDemoMode else { return nil }
        return model.firstMateConfiguration(machineID: machineID)
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

    private var firstMateDetailConnectionIdentity: FirstMateDetailConnectionIdentity {
        .init(
            machineID: firstMateDetailMachineID,
            urlString: firstMateConfiguration?.baseURL.absoluteString,
            token: firstMateConfiguration?.token,
            generation: model.connectionGeneration,
            isDemo: model.isDemoMode
        )
    }

    /// What the Chat navigator badges beside First Mate.
    ///
    /// Live, it is the conversations with an unread dot
    /// (`FirstMateBadge.count`), counted from the unfiltered fleet index, so
    /// search text, machine scope, and the selected First Mate host never
    /// change it, and it matches the Dock and the chat window. A host without
    /// the fleet summary counts what `FirstMateAttention` counts. Demo mode has
    /// no live hosts, so the attention predicate counts the demo store's own
    /// synthetic features instead.
    private var firstMateAttentionCount: Int {
        if model.isDemoMode {
            return FirstMateAttention.count(features: shell.firstMate.features, machineID: "demo")
        }
        return shell.firstMateFleet.badgeCount
    }

    /// The current First Mate screen marks its chat read while it is in the
    /// key window and scrolled to the newest message, like the chat window.
    /// Only a chat the fleet reports unread posts a marker. An equatable
    /// value, so the chat re-renders only when the machine or its unread
    /// chats change.
    private var markFirstMateRead: FirstMateMarkReadAction? {
        guard let machineID = shell.activeFirstMateMachineID else { return nil }
        let fleet = shell.firstMateFleet
        return FirstMateMarkReadAction(
            machineID: machineID,
            unreadThrough: FirstMateMarkReadAction.unreadThrough(hosts: fleet.hosts, readState: fleet.readState, machineID: machineID),
            owner: fleet,
            perform: { [weak fleet] machineID, featureID, messageID in
                guard let fleet else { return }
                Task { await fleet.markRead(machineID: machineID, featureID: featureID, throughMessageID: messageID) }
            }
        )
    }

    /// "Open in window": the chat window on the current feature. In demo mode
    /// only a feature the chat demo also has is requested.
    private func openFirstMateChatWindow() {
        if let featureID = shell.firstMate.selectedFeatureID,
           let machineID = shell.activeFirstMateMachineID,
           !model.isDemoMode || FirstMateDemo.chatWindowFleet().contains(where: { $0.featureID == featureID }) {
            shell.firstMateChatOpenRequest = FirstMateFleetFeatureID(machineID: machineID, featureID: featureID)
        }
        openWindow(id: HerdrWindowID.firstMateChat)
    }

    private var firstMateScopeSelection: Binding<FirstMateMachineScope> {
        Binding(
            get: { resolvedFirstMateScope },
            set: { shell.selectFirstMateScope($0) }
        )
    }

    private var resolvedPRReviewScope: PRReviewHostScope {
        PRReviewHostScope.resolved(shell.prReviewScope, availableMachineIDs: model.machines.map(\.id))
    }

    private var prReviewScopeSelection: Binding<PRReviewHostScope> {
        Binding(get: { resolvedPRReviewScope }, set: { shell.selectPRReviewScope($0) })
    }

    private var prReviewFleetIsVisible: Bool {
        shell.detailScope == .prReview && resolvedPRReviewScope == .all && !model.isDemoMode
    }

    private var prReviewCreationConfiguration: ServerConfiguration? {
        if resolvedPRReviewScope == .all, !model.isDemoMode, let machine = model.prReviewMachine {
            return model.prReviewConfiguration(machineID: machine.id)
        }
        return prReviewConfiguration
    }

    private func setPRReviewCreating(_ creating: Bool) {
        if creating {
            shell.preparePRReviewCreation(model: model)
            // Pin the transport before the sheet can submit, rather than
            // waiting for the connection task after a fleet-host switch.
            shell.configurePRReviewIfNeeded(configuration: prReviewConfiguration, machineID: prReviewMachineID, connectionGeneration: model.connectionGeneration, isDemo: model.isDemoMode)
        }
        shell.isCreatingPRReview = creating
        if !creating, prReviewFleetIsVisible {
            Task { await shell.prReviewFleet.refresh() }
        }
    }

    private func performPRReviewFleetAction(_ target: PRReviewWindowTarget, action: () async throws -> Void) async {
        do {
            try await action()
            if shell.prReview.currentMachineID == target.machineID, shell.prReview.selectedReviewID == target.reviewID {
                await shell.prReview.refresh()
            }
            await shell.prReviewFleet.refresh()
        } catch {
            if !HerdrCancellation.isCancellation(error) { model.toastMessage = error.localizedDescription }
        }
    }

    private var prReviewMachineID: String? {
        shell.prReviewMachineID ?? (model.isDemoMode ? "demo" : model.prReviewMachine?.id)
    }

    private var prReviewConfiguration: ServerConfiguration? {
        model.prReviewConfiguration(machineID: prReviewMachineID)
    }

    private func applyFirstMateNavigationRequest() async {
        if !Task.isCancelled, let request = shell.firstMateOpenRequest,
           request.id != shell.firstMateAppliedRequestID,
           firstMateConnectionIsReady,
           request.serverURL == firstMateConfiguration?.baseURL.absoluteString {
            shell.firstMateSurface = .workspace
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
        // Dashboard cards and Agent view open features the fleet list knows
        // about, which can be newer than this store's list. Refresh once before
        // deciding the target is absent, so the click never lands elsewhere.
        if !Task.isCancelled, let target = shell.pendingFirstMateControlTarget,
           target.machineID == firstMateDetailMachineID, firstMateConnectionIsReady,
           !shell.firstMate.features.contains(where: { $0.id == target.featureID }) {
            let store = shell.firstMate
            await store.refresh()
            guard !Task.isCancelled, shell.firstMate === store else { return }
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
            shell.showFirstMateStart(preferredMachineID: machineID)
            shell.pendingFirstMateCreateMachineID = nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let detailOverride {
            detailOverride
        } else {
            routedDetail
        }
    }

    @ViewBuilder
    private var routedDetail: some View {
        switch shell.resolvedScope(for: model) {
        // Each screen reads its own data, so fleet polls never re-evaluate this
        // root view.
        case .home:
            ContentUnavailableView("Home", systemImage: "house", description: Text("Your First Mate overview is being prepared."))
        case .dashboard:
            DashboardView(model: model, shell: shell)
        case .agentBoard:
            AgentBoardView(model: model, shell: shell)
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
                    "Choose a chat",
                    symbol: "bubble.left",
                    detail: "Open a chat or terminal from the sidebar."
                )
            }
        case .firstMate:
            switch shell.firstMateSurface {
            case .newSession:
                FirstMateStartSessionView(
                    model: shell.firstMateStart, index: shell.firstMateProjects,
                    manageProjects: shell.showFirstMateProjects,
                    started: { session in
                        if shell.openStartedFirstMateSession(session, connectionGeneration: model.connectionGeneration, isDemo: model.isDemoMode) {
                            Task { await shell.firstMateFleet.refresh() }
                        }
                    }
                )
            case .projects:
                FirstMateProjectsView(index: shell.firstMateProjects, manualSetup: { shell.showFirstMateStart(mode: .manual) }) { selection in
                    shell.showFirstMateStart(project: selection)
                }
            case .workspace:
            FirstMateWorkspaceView(
                model: model,
                store: shell.firstMate,
                modelFavorites: modelFavorites,
                canControl: firstMateCanControl,
                owningMachineID: firstMateGitOwnerMachineID,
                gitOwnerIsReady: firstMateGitOwnerMachineID != nil && firstMateConnectionIsReady,
                configuration: firstMateGitConfiguration,
                configurationRevision: firstMateGitOwnerMachineID.map { model.machineConfigurationRevision(for: $0) } ?? 0,
                owningMachineName: resolvedFirstMateScope == .all ? activeFirstMateMachine?.name : nil,
                allowsDirectCreate: true,
                popOutGit: { openWindow(id: HerdrWindowID.firstMateGit, value: $0) },
                popOutChat: { openFirstMateChatWindow() },
                startSession: { shell.showFirstMateStart(preferredMachineID: firstMateDetailMachineID) }
            )
            .environment(\.firstMateMarkRead, markFirstMateRead)
            }
        case .watchers:
            WatchersView(store: shell.watchers, revealRequest: shell.homeWatcherRevealRequest,
                         onRevealHandled: { id in
                             if shell.homeWatcherRevealRequest?.id == id { shell.homeWatcherRevealRequest = nil }
                         }, searchFocusRequest: shell.surfaceSearchFocusRequest)
        case .prReview:
            PRReviewContainerView(
                store: shell.prReview,
                comments: shell.prReviewComments,
                canControl: model.isDemoMode || prReviewConfiguration != nil,
                openURL: { url in Task { try? await HerdrExternalLinkOpener.open(url) } },
                askAI: { selection, view, rect in
                    guard let review = shell.prReview.selectedReview,
                          let machineID = shell.prReview.currentMachineID else { return }
                    Task { await model.presentPRReviewQuestion(machineID: machineID, review: review, selection: selection, anchor: (view, rect)) }
                },
                questionDraftChanged: { shell.hasPRReviewQuestionDraft = $0 },
                setCreating: setPRReviewCreating,
                openPane: { paneID, machineID in
                    shell.openPane(rawPaneID: paneID, machineID: machineID, model: model)
                },
                setAddingSkill: { shell.isAddingPRReviewSkill = $0 },
                popOut: { openWindow(id: HerdrWindowID.prReview, value: $0) },
                documentHost: model
            )
        case .fleet:
            FleetDestinationView(model: model)
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

    /// The detail column's 40pt title bar: navigation, the screen's own title
    /// and actions (from `herdrTitleBar`), the ⋯ menu, and the global items
    /// (update badge, Herd Pulse, connection).
    private func titleBar(_ items: HerdrTitleBarItems?) -> some View {
        HStack(spacing: 6) {
            if !isSidebarVisible {
                sidebarToggleButton
            }
            navigationControls
            Group {
                if let leading = items?.leading {
                    leading
                } else {
                    defaultTitle
                }
            }
            .layoutPriority(-1)
            Spacer(minLength: 8)
            if let trailing = items?.trailing {
                trailing
            }
            // A chat's own ⋯ menu ends with these same sections.
            if items?.hostsShellMenu != true {
                HerdrShellMenu(tint: chromeIcon)
            }
            globalItems
        }
        .padding(.leading, titleBarLeadingPadding)
        .padding(.trailing, 8)
        .herdrBar(hairline: .clear)
        .foregroundStyle(chromeTitle)
        .environment(\.herdrShellMenu, shellMenuActions)
    }

    /// What every ⋯ menu in the title bar ends with: the app's destinations
    /// and Ask Agent.
    private var shellMenuActions: HerdrShellMenuActions {
        let resolved = shell.resolvedScope(for: model)
        return HerdrShellMenuActions(
            current: HerdrDetailScope.menuDestinations.contains(resolved) ? resolved : nil,
            show: { shell.show($0, model: model) },
            askAgent: model.canControl ? { shell.isAgentPresented = true } : nil
        )
    }

    private var titleBarLeadingPadding: CGFloat {
        guard !shell.homeEnabled, !isSidebarVisible, !isFullScreen else { return isSidebarVisible ? 12 : 8 }
        return HerdrWindowChrome.trafficLightInset - 2
    }

    @ViewBuilder
    private var defaultTitle: some View {
        switch shell.detailScope {
        case .home, .dashboard, .agentBoard:
            Text(shell.detailScope.label)
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(chromeTitle)
                .lineLimit(1)
        case .firstMate:
            Label("First Mate", systemImage: "sailboat")
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(chromeTitle)
                .lineLimit(1)
        case .watchers:
            Label("Watchers", systemImage: "eye")
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(chromeTitle)
                .lineLimit(1)
        case .prReview:
            Label("PR Review", systemImage: HerdrDetailScope.prReview.symbol)
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                .foregroundStyle(chromeTitle)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 0) {
            if !shell.homeEnabled && shell.detailScope != .dashboard {
                // A place, not a second Back button.
                Button("Dashboard", systemImage: "square.grid.2x2") { shell.goHome(model: model) }
                    .buttonStyle(HerdrIconButtonStyle(tint: chromeIcon))
                    .help("Dashboard (Shift-Command-D)")
                    .accessibilityIdentifier("back-to-dashboard")
            }
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nav-history-controls")
    }

    private var globalItems: some View {
        HStack(spacing: 2) {
            // Appears only while a check has a newer release to offer, so updating
            // never requires the menu bar.
            HerdrUpdateToolbarItem(updates: updates)

            HerdPulseButton()

            ConnectionPill(state: model.connectionState)
                .padding(.leading, 4)
        }
    }

    private func historyButton(
        symbol: String, label: String, help: String,
        identifier: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(label, systemImage: symbol, action: action)
            .buttonStyle(HerdrIconButtonStyle(tint: chromeIcon))
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
