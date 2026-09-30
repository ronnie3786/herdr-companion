import SwiftUI

struct AppRootView: View {
    @Bindable var model: HerdrAppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HerdPulseCoordinator.self) private var herdPulse
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.hasCompletedSetup {
                ZStack {
                    appTabs
                    SidebarDrawer(model: model)
                }
            } else {
                OnboardingView(model: model)
            }
        }
        .task(id: model.connectionGeneration) {
            guard model.hasCompletedSetup else { return }
            await model.runConnection()
        }
        .task {
            if let paneID = HerdrAppDelegate.takePendingPaneID() {
                model.openPane(id: paneID)
            }
            if HerdrAppDelegate.takePendingCarMode() {
                model.openCarMode()
            }
            for await notification in NotificationCenter.default.notifications(named: .herdrOpenPane) {
                guard let paneID = notification.object as? String else { continue }
                model.openPane(id: paneID)
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .herdrOpenCarMode) {
                model.openCarMode()
            }
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: .herdrPushToken) {
                guard let token = notification.object as? String else { continue }
                await model.registerPushDevice(token: token)
            }
        }
        .task(id: model.hasCompletedSetup && model.smartAlertsEnabled && !model.isDemoMode) {
            await model.prepareSmartAlerts()
        }
        .task(id: firstMateObservation) {
            guard firstMateObservation.isActive else { return }
            await model.observeFirstMate()
        }
        .onChange(of: model.machines) { _, machines in
            model.firstMateFleet.updateMachineNames(machines)
        }
        .onChange(of: model.selectedTab == .firstMate && scenePhase == .active, initial: true) { _, visible in
            model.firstMateDriver.isFirstMateVisible = visible
        }
        .onChange(of: visibleFirstMateTarget, initial: true) { _, target in
            model.firstMateDriver.setVisibleTarget(target)
        }
        .onChange(of: model.firstMateFleet.selectedStore?.operationContext) { _, _ in
            model.firstMateDriver.setVisibleTarget(visibleFirstMateTarget)
        }
        .task(id: herdPulseContext) {
            await herdPulse.synchronize(context: herdPulseContext)
        }
        .onOpenURL(perform: model.open)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                model.open(url: url)
            }
        }
        .overlay(alignment: .top) {
            if let message = model.toastMessage {
                ToastView(message: message, dismiss: model.clearToast)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toastMessage)
        // Presented from the root, not from the navigator drawer that opens it:
        // the drawer closes as soon as a promoted run routes the app to its new
        // pane, and the sheet has to outlive that.
        .sheet(item: $model.agentRequest) { request in
            HeadlessAgentSheet(model: model, machineID: request.machineID)
        }
        .fullScreenCover(isPresented: $model.isCarModePresented) {
            CarModeView(model: model) {
                model.isCarModePresented = false
            }
        }
        .alert(
            "Connection issue",
            isPresented: $model.isShowingError
        ) {
            Button("Dismiss", role: .cancel, action: model.clearError)
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .herdrAppChrome()
    }

    private var firstMateObservation: FirstMateObservationContext {
        FirstMateObservationContext(
            machineIDs: model.machines.map(\.id),
            generation: model.connectionGeneration,
            isDemo: model.isDemoMode,
            isActive: model.hasCompletedSetup && scenePhase == .active
        )
    }

    private var visibleFirstMateTarget: FirstMateFeatureTarget? {
        model.selectedTab == .firstMate && scenePhase == .active ? model.firstMateFleet.selectedTarget : nil
    }

    private var herdPulseContext: HerdPulseSyncContext {
        return HerdPulseSyncContext(
            aggregate: HerdPulseAggregate(
                workspaces: model.workspaces,
                alerts: model.alerts,
                pendingReadPaneIDs: model.pendingReadPaneIDs,
                revealTitles: model.showSessionTitles,
                connectionState: model.connectionState
            ),
            serverConnection: model.activeServerConnection
        )
    }

    @ViewBuilder private var firstMateWorkspace: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-HerdrFirstMateSizeClassScenarios") {
            FirstMateSizeClassScenario(model: model)
        } else {
            FirstMateWorkspaceView(model: model, fleet: model.firstMateFleet)
        }
        #else
        FirstMateWorkspaceView(model: model, fleet: model.firstMateFleet)
        #endif
    }

    private var appTabs: some View {
        TabView(selection: Binding(get: { model.selectedTab }, set: { model.selectTab($0) })) {
            Tab("First Mates", systemImage: "sailboat", value: .firstMate) {
                firstMateWorkspace
            }
            .badge(model.firstMateFleet.badgeCount)


            Tab("Agents", systemImage: "bubble.left.and.bubble.right", value: .workspaces) {
                WorkspaceNavigationView(model: model)
            }

            Tab("Attention", systemImage: "bell.badge", value: .attention) {
                AttentionNavigationView(model: model)
            }
            .badge(model.unreadAlertCount)

            Tab("Notes", systemImage: "note.text", value: .notes) {
                RemoteNotesView(model: model)
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView(model: model)
            }
        }
    }
}

#if DEBUG
/// Drives the real workspace through iPad window size-class changes in UI tests.
private struct FirstMateSizeClassScenario: View {
    let model: HerdrAppModel
    @State private var compact = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Use compact layout") { compact = true }
                    .accessibilityIdentifier("size-class-compact")
                Button("Use regular layout") { compact = false }
                    .accessibilityIdentifier("size-class-regular")
            }
            .buttonStyle(HerdrButtonStyle(kind: .outline))
            FirstMateWorkspaceView(model: model, fleet: model.firstMateFleet)
                .environment(\.horizontalSizeClass, compact ? .compact : .regular)
        }
    }
}
#endif
