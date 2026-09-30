import SwiftUI

struct FirstMateWorkspaceView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var path: [FirstMateChatRoute] = []
    @State private var showsBriefing = false
    @State private var briefingGoal = ""
    @State private var creationGoal: String?
    private var regular: Bool { horizontalSizeClass == .regular }
    private var availableMachineIDs: [String] { fleet.hosts.map(\.machineID) }

    var body: some View {
        Group {
            if regular {
                NavigationSplitView { conversations.navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380) } detail: {
                    NavigationStack(path: $path) {
                        Group {
                            if showsBriefing { briefing }
                            else if let target = fleet.selectedTarget { chat(target, topmost: path.isEmpty) }
                            else { ContentUnavailableView("Choose a conversation", systemImage: "sailboat") }
                        }
                        .navigationDestination(for: FirstMateChatRoute.self, destination: destination)
                    }
                }.navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $path) {
                    conversations.navigationDestination(for: FirstMateChatRoute.self, destination: destination)
                }
            }
        }
        .dynamicTypeSize(...HerdrTheme.maximumDynamicTypeSize).preferredColorScheme(.dark).tint(HerdrTheme.accent)
        .sheet(isPresented: $fleet.isCreating, onDismiss: { creationGoal = nil }) {
            FirstMateCreateSheet(model: model, fleet: fleet, onCreated: { target in
                if let creationGoal, briefingGoal == creationGoal { briefingGoal = "" }
                openFeature(target)
            }, initialGoal: creationGoal ?? "")
        }
        .onChange(of: model.connectionGeneration) { _, _ in path = []; showsBriefing = false; fleet.isCreating = false }
        .onChange(of: availableMachineIDs) { _, machineIDs in
            path.removeAll { route in
                switch route {
                case .lead: false
                case .chat(let target), .info(let target, _): !machineIDs.contains(target.machineID)
                }
            }
        }
        .onChange(of: fleet.selectedTarget) { _, target in
            if target == nil { path.removeAll { route in if case .lead = route { false } else { true } } }
        }
        .onChange(of: path) { old, current in
            if old.count > current.count { model.beginAppNavigation() }
            if !regular {
                switch current.last {
                case .chat(let target), .info(let target, _):
                    if fleet.selectedTarget != target { _ = fleet.open(target) }
                case .lead:
                    if fleet.chat.selection != .lead { fleet.selectTarget(nil); fleet.chat.select(.lead) }
                case nil: fleet.selectTarget(nil)
                }
            }
        }
        .onChange(of: fleet.chat.route, initial: true) { _, route in
            guard let route else { return }
            showsBriefing = false; fleet.isCreating = false
            let store = fleet.store(for: route.target)
            store?.graphMode = route.graph
            store?.inspector = route.inspector ?? .overview
            path = regular ? [] : [.chat(route.target)]
            if let _ = route.inspector { path.append(.info(route.target, assignmentID: route.assignmentID)) }
        }
        .accessibilityIdentifier("first-mate-workspace")
    }
    private var conversations: some View {
        FirstMateConversationsScreen(model: model, fleet: fleet, openFeature: openFeature,
            openInfo: { target in openFeature(target); showInfo(target, inspector: .overview, assignmentID: nil) }, openLead: openBriefing)
    }
    private var briefing: some View {
        FirstMateLeadScreen(model: model, fleet: fleet, goal: $briefingGoal,
            topmost: regular ? path.isEmpty : path.last == .lead, openFeature: openFeature,
            openInfo: { showInfo($0, inspector: .overview, assignmentID: nil) },
            create: { goal in creationGoal = goal; model.beginAppNavigation(); fleet.beginCreating() },
            back: regular && path.isEmpty ? { showsBriefing = false; fleet.selectTarget(nil) } : nil)
    }
    @ViewBuilder private func destination(_ route: FirstMateChatRoute) -> some View {
        switch route {
        case .lead: briefing
        case .chat(let target): chat(target, topmost: path.last == route)
        case .info(let target, let assignmentID):
            if let store = fleet.store(for: target) {
                FirstMateInfoScreen(model: model, fleet: fleet, store: store, target: target, assignmentID: assignmentID, openFeature: openFeature)
            }
        }
    }
    @ViewBuilder private func chat(_ target: FirstMateFeatureTarget, topmost: Bool) -> some View {
        if let store = fleet.store(for: target) {
            FirstMateChatScreen(model: model, fleet: fleet, store: store, target: target, topmost: topmost,
                openInfo: { showInfo(target, inspector: $0, assignmentID: $1) }, readTrackingEnabled: true,
                back: regular && path.isEmpty ? { fleet.selectTarget(nil) } : nil)
                .id(target)
        }
    }
    private func openFeature(_ target: FirstMateFeatureTarget) {
        let previous = fleet.selectedTarget
        guard fleet.open(target) else { return }
        if previous != target { fleet.store(for: target)?.inspector = .overview }
        showsBriefing = false
        if regular { path = [] }
        else if path.contains(.lead) { path.append(.chat(target)) }
        else { path = [.chat(target)] }
    }
    private func showInfo(_ target: FirstMateFeatureTarget, inspector: FirstMateInspector, assignmentID: String?) {
        guard fleet.selectedTarget == target, let store = fleet.store(for: target) else { return }
        model.beginAppNavigation()
        store.inspector = inspector
        if path.last != .info(target, assignmentID: assignmentID) { path.append(.info(target, assignmentID: assignmentID)) }
    }
    private func openBriefing() {
        fleet.selectTarget(nil); fleet.chat.select(.lead); showsBriefing = true
        path = regular ? [] : [.lead]
    }
}
