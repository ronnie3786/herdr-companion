import SwiftUI

struct FirstMateWorkspaceView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // One semantic path survives size-class changes. Regular presentation uses
    // its chat and inspector side by side without popping or recreating routes.
    @State private var path: [FirstMateChatRoute] = []
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var briefingGoal = ""
    @State private var creationGoal: String?
    private var regular: Bool { horizontalSizeClass == .regular }
    private var showsBriefing: Bool {
        // Info decorates its conversation. Popping a feature back to the global
        // lead must restore automatic choice before either presentation mounts.
        for route in path.reversed() {
            switch route {
            case .lead: return true
            case .chat: return false
            case .info: continue
            }
        }
        return false
    }
    private var availableMachineIDs: [String] { fleet.hosts.map(\.machineID) }

    var body: some View {
        Group {
            if regular {
                NavigationSplitView(columnVisibility: $columns) {
                    conversations
                        .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 360)
                        .composerLayoutMeasurement(id: "first-mate-sidebar-column")
                } content: {
                    Group {
                        if showsBriefing { briefing }
                        else if let target = fleet.selectedTarget { chat(target, topmost: true) }
                        else { ContentUnavailableView("Choose a conversation", systemImage: "sailboat") }
                    }
                    .navigationSplitViewColumnWidth(min: 300, ideal: 520, max: .infinity)
                    .composerLayoutMeasurement(id: "first-mate-chat-column")
                    .accessibilityIdentifier("first-mate-chat-column")
                } detail: {
                    Group {
                        if let target = fleet.selectedTarget, let store = fleet.store(for: target) {
                            FirstMateInfoScreen(model: model, fleet: fleet, store: store, target: target,
                                assignmentID: assignmentID(for: target), openFeature: openFeature, embedded: true)
                                .id(target)
                        } else {
                            ContentUnavailableView("Conversation info", systemImage: "info.circle",
                                description: Text("Select a conversation to see its overview and saved evidence."))
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 420)
                    .composerLayoutMeasurement(id: "first-mate-info-column")
                    .accessibilityIdentifier("first-mate-info-column")
                }
                .navigationSplitViewStyle(.balanced)
                .toolbarVisibility(.visible, for: .tabBar)
            } else {
                NavigationStack(path: $path) {
                    conversations.navigationDestination(for: FirstMateChatRoute.self, destination: destination)
                }
            }
        }
        .herdrFirstMateChrome()
        .sheet(isPresented: $fleet.isCreating, onDismiss: { creationGoal = nil }) {
            FirstMateCreateSheet(model: model, fleet: fleet, onCreated: { target in
                if let creationGoal, briefingGoal == creationGoal { briefingGoal = "" }
                openFeature(target)
            }, initialGoal: creationGoal ?? "")
        }
        .onChange(of: model.connectionGeneration) { _, _ in path = []; fleet.isCreating = false }
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
            switch current.last {
            case .chat(let target), .info(let target, _):
                if fleet.selectedTarget != target { _ = fleet.open(target) }
            case .lead:
                if fleet.chat.selection != .lead { fleet.selectTarget(nil); fleet.chat.select(.lead) }
            case nil:
                if !regular { fleet.selectTarget(nil) }
            }
        }
        .onChange(of: regular) { _, _ in
            // A presentation change must not mint a navigation intent, select
            // another owner, reset the Info tab, or consume an in-flight draft.
            columns = .all
        }
        .onChange(of: fleet.chat.route, initial: true) { _, route in
            guard let route else { return }
            fleet.isCreating = false
            let store = fleet.store(for: route.target)
            store?.graphMode = route.graph
            store?.inspector = route.inspector ?? .overview
            path = [.chat(route.target)]
            if route.inspector != nil { path.append(.info(route.target, assignmentID: route.assignmentID)) }
        }
        .accessibilityIdentifier("first-mate-workspace")
    }

    private var conversations: some View {
        FirstMateConversationsScreen(model: model, fleet: fleet, openFeature: openFeature,
            openInfo: { target in openFeature(target); showInfo(target, inspector: .overview, assignmentID: nil) }, openLead: openBriefing)
    }
    private var briefing: some View {
        FirstMateLeadScreen(model: model, fleet: fleet, goal: $briefingGoal,
            topmost: regular || path.last == .lead, openFeature: openFeature,
            openInfo: { showInfo($0, inspector: .overview, assignmentID: nil) },
            create: { goal in creationGoal = goal; model.beginAppNavigation(); fleet.beginCreating() },
            back: regular ? { clearSelection() } : nil, embedded: regular)
    }
    @ViewBuilder private func destination(_ route: FirstMateChatRoute) -> some View {
        switch route {
        case .lead: briefing
        case .chat(let target): chat(target, topmost: path.last == route)
        case .info(let target, let assignmentID):
            if let store = fleet.store(for: target) {
                FirstMateInfoScreen(model: model, fleet: fleet, store: store, target: target,
                    assignmentID: assignmentID, openFeature: openFeature)
            }
        }
    }
    @ViewBuilder private func chat(_ target: FirstMateFeatureTarget, topmost: Bool) -> some View {
        if let store = fleet.store(for: target) {
            FirstMateChatScreen(model: model, fleet: fleet, store: store, target: target, topmost: topmost,
                openInfo: { showInfo(target, inspector: $0, assignmentID: $1) }, readTrackingEnabled: true,
                back: regular ? { clearSelection() } : nil, embedded: regular)
                .id(target)
        }
    }
    private func assignmentID(for target: FirstMateFeatureTarget) -> String? {
        guard case .info(let owner, let id) = path.last, owner == target else { return nil }
        return id
    }
    private func clearSelection() {
        model.beginAppNavigation(); path = []; fleet.selectTarget(nil)
    }
    private func openFeature(_ target: FirstMateFeatureTarget) {
        let previous = fleet.selectedTarget
        guard fleet.open(target) else { return }
        if previous != target { fleet.store(for: target)?.inspector = .overview }
        if !regular && path.contains(.lead) { path.append(.chat(target)) }
        else { path = [.chat(target)] }
    }
    private func showInfo(_ target: FirstMateFeatureTarget, inspector: FirstMateInspector, assignmentID: String?) {
        guard fleet.selectedTarget == target, let store = fleet.store(for: target) else { return }
        model.beginAppNavigation(); store.inspector = inspector
        if case .info = path.last { path.removeLast() }
        path.append(.info(target, assignmentID: assignmentID))
    }
    private func openBriefing() {
        fleet.selectTarget(nil); fleet.chat.select(.lead)
        path = [.lead]
    }
}
