import SwiftUI

/// Only the global lead destination follows machine choice. Explicit owned
/// feature/assignment routes use ChatScreen directly and never redirect here.
struct FirstMateLeadScreen: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Binding var goal: String
    let topmost: Bool
    let openFeature: (FirstMateFeatureTarget) -> Void
    let openInfo: (FirstMateFeatureTarget) -> Void
    let create: (String) -> Void
    var back: (() -> Void)? = nil
    @State private var retry = 0
    @State private var error: String?
    @State private var loading = false
    @Environment(\.scenePhase) private var scenePhase

    private struct Request: Equatable {
        let machineID: String?
        let lifecycle: FirstMateStore.LifecycleIdentity?
        let visible: Bool
        let pin: String?
        let retry: Int
    }
    private var request: Request {
        let id = fleet.leadChoice.current
        return .init(machineID: id, lifecycle: id.flatMap { fleet.store(forMachineID: $0)?.lifecycle },
            visible: topmost && model.selectedTab == .firstMate && scenePhase == .active
                && !model.isSidebarPresented && !model.isCarModePresented && !model.isShowingError
                && model.agentRequest == nil && !fleet.isCreating
                && fleet.chat.selection == .lead && !fleet.chat.isRouting && fleet.chat.route == nil,
            pin: fleet.chat.pinnedMachineID, retry: retry)
    }
    private var target: FirstMateFeatureTarget? {
        guard let selected = fleet.selectedTarget, selected.machineID == request.machineID,
              fleet.store(for: selected)?.snapshots[selected.featureID]?.feature.isLead == true else { return nil }
        return selected
    }
    var body: some View {
        // The scheduled operation belongs to this render's key and existing
        // user intent. Automatic choice/visibility updates never mint authority.
        let captured = request
        let intent = fleet.chat.currentNavigationIntent
        Group {
            if request.machineID == nil {
                FirstMateLeadBriefingScreen(model: model, fleet: fleet, goal: $goal, openFeature: openFeature, create: create)
            } else if let target, let store = fleet.store(for: target) {
                FirstMateChatScreen(model: model, fleet: fleet, store: store, target: target, topmost: topmost,
                    openInfo: { _, _ in openInfo(target) }, readTrackingEnabled: true, back: back, followsLeadChoice: true)
                    .id(target)
            } else {
                VStack(spacing: 20) {
                    FirstMateFaceOrb(size: 52)
                    Text("My First Mate").herdrFont(.headline)
                    Text(request.machineID.map(model.machineName) ?? "").herdrFont(.caption)
                    if loading { ProgressView("Opening your First Mate…") }
                    else {
                        Text(error ?? "First Mate is not available yet.").herdrFont(.body)
                            .foregroundStyle(HerdrTheme.warning).fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { retry += 1 }.buttonStyle(HerdrButtonStyle(kind: .outline))
                            .accessibilityIdentifier("first-mate-lead-retry")
                    }
                    FirstMateLeadMachineMenu(model: model, fleet: fleet)
                }
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                .herdrFirstMateChrome().navigationTitle("My First Mate").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar).toolbarVisibility(.hidden, for: .tabBar)
                .accessibilityIdentifier("first-mate-lead-opening")
            }
        }
        .task(id: captured) {
            guard !Task.isCancelled, captured == request, captured.visible,
                  fleet.chat.isCurrentNavigation(intent), let machineID = captured.machineID else { return }
            loading = true; error = nil
            let opened = await fleet.chat.openLead(on: machineID, intent: intent, fleet: fleet,
                canControl: { model.firstMateCanControl(machineID: $0) },
                whileCurrent: { request == captured && !fleet.chat.isRouting && fleet.chat.route == nil })
            guard !Task.isCancelled, request == captured, fleet.chat.isCurrentNavigation(intent) else { return }
            loading = false
            if opened == nil { error = fleet.chat.leadOpenError ?? "First Mate could not be opened on its owning machine." }
        }
    }
}
