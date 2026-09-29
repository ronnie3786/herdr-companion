import SwiftUI

/// Phase 2 swaps the list only. Existing detail/chat/inspector helpers continue
/// serving exact-owner routes until their replacement phases.
struct FirstMateWorkspaceView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var path: [FirstMateChatRoute] = []
    @State private var showsBriefing = false
    @State private var localInspectorTarget: FirstMateFeatureTarget?
    @State private var localInspectorRequestID = UUID()

    private var availableMachineIDs: [String] { fleet.hosts.map(\.machineID) }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    conversations
                        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
                } detail: {
                    if showsBriefing {
                        FirstMateLeadBriefingScreen(model: model, fleet: fleet, openFeature: openFeature)
                    } else if let target = fleet.selectedTarget, let store = fleet.store(for: target) {
                        detail(store: store, target: target)
                    } else {
                        ContentUnavailableView("Choose a conversation", systemImage: "sailboat",
                                               description: Text("Open a feature or My First Mate to follow the work."))
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $path) {
                    conversations
                        .navigationDestination(for: FirstMateChatRoute.self) { route in
                            switch route {
                            case .lead:
                                FirstMateLeadBriefingScreen(model: model, fleet: fleet, openFeature: openFeature)
                            case .chat(let target), .info(let target, _):
                                if let store = fleet.store(for: target) { detail(store: store, target: target) }
                            }
                        }
                }
            }
        }
        .dynamicTypeSize(...HerdrTheme.maximumDynamicTypeSize)
        .preferredColorScheme(.dark)
        .tint(HerdrTheme.accent)
        .sheet(isPresented: $fleet.isCreating) {
            FirstMateCreateSheet(model: model, fleet: fleet, onCreated: openFeature)
        }
        .onChange(of: model.connectionGeneration) { _, _ in
            path = []; showsBriefing = false; localInspectorTarget = nil; fleet.isCreating = false
        }
        .onChange(of: availableMachineIDs) { _, machineIDs in
            path.removeAll { route in
                switch route {
                case .lead: false
                case .chat(let target), .info(let target, _): !machineIDs.contains(target.machineID)
                }
            }
            if let selected = fleet.selectedTarget, !machineIDs.contains(selected.machineID) { fleet.selectTarget(nil) }
        }
        .onChange(of: fleet.selectedTarget) { _, target in
            if target == nil {
                path.removeAll { route in if case .lead = route { false } else { true } }
            }
        }
        .onChange(of: path) { _, current in
            guard horizontalSizeClass != .regular else { return }
            if current.isEmpty {
                fleet.selectTarget(nil)
                localInspectorTarget = nil
            } else if current.last == .lead, fleet.selectedTarget != nil {
                fleet.selectTarget(nil)
                fleet.chat.select(.lead)
                localInspectorTarget = nil
            }
        }
        .onChange(of: fleet.chat.route, initial: true) { _, route in
            guard let route else { return }
            showsBriefing = false
            localInspectorTarget = nil
            fleet.isCreating = false
            if horizontalSizeClass != .regular { path = [.chat(route.target)] }
            fleet.store(for: route.target)?.graphMode = route.graph
        }
        .accessibilityIdentifier("first-mate-workspace")
    }

    private var conversations: some View {
        FirstMateConversationsScreen(model: model, fleet: fleet, openFeature: openFeature,
                                      openInfo: openInfo, openLead: openBriefing)
    }
    private func detail(store: FirstMateStore, target: FirstMateFeatureTarget) -> some View {
        FirstMateFeatureDetailView(
            store: store, featureID: target.featureID, machineName: model.machineName(target.machineID),
            canControl: model.firstMateCanControl(machineID: target.machineID),
            displayName: fleet.conversations.first(where: { $0.id == .init(machineID: target.machineID, featureID: target.featureID) })?.name
                ?? fleet.chat.knownPresentation(for: target)?.name,
            requestedInspector: localInspectorTarget == target ? .overview : fleet.chat.route?.target == target ? fleet.chat.route?.inspector : nil,
            inspectorRequestID: localInspectorTarget == target ? localInspectorRequestID : fleet.chat.route?.target == target ? fleet.chat.route?.id : nil
        )
        .toolbar(.visible, for: .navigationBar)
        .id("\(target.machineID)-\(target.featureID)")
    }
    private func openFeature(_ target: FirstMateFeatureTarget) {
        guard fleet.open(target) else { return }
        showsBriefing = false
        localInspectorTarget = nil
        if horizontalSizeClass != .regular {
            if path.last == .lead { path.append(.chat(target)) }
            else { path = [.chat(target)] }
        }
    }
    private func openInfo(_ target: FirstMateFeatureTarget) {
        openFeature(target)
        guard fleet.selectedTarget == target else { return }
        localInspectorTarget = target
        localInspectorRequestID = UUID()
    }
    private func openBriefing() {
        fleet.selectTarget(nil)
        fleet.chat.select(.lead)
        localInspectorTarget = nil
        showsBriefing = true
        if horizontalSizeClass != .regular { path = [.lead] }
    }
}
