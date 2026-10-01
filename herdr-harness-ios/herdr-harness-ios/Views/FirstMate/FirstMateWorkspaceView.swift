import SwiftUI

struct FirstMateWorkspaceView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var fleet: FirstMateMobileFleetStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // One semantic path survives size-class changes. Regular presentation uses
    // its chat and inspector side by side without popping or recreating routes.
    @State private var path: [FirstMateChatRoute] = []
    /// iPad columns: the person's last choices; nil follows the orientation.
    @State private var inspectorOpen: Bool?
    @State private var listPreference: FirstMateIPadLayout.ListPreference?
    @State private var inspectorPinned = false
    @State private var inspectorDrag: CGFloat = 0
    @State private var gitTarget: FirstMateGitTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                GeometryReader { geometry in
                    // Orientation counts the bars and the keyboard back in, so
                    // typing in portrait never reads as landscape.
                    let size = CGSize(width: geometry.size.width,
                                      height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
                    regularColumns(FirstMateIPadLayout.resolve(size: size, inspectorOpen: inspectorOpen,
                                                               list: listPreference, pinned: inspectorPinned))
                }
                .toolbarVisibility(.visible, for: .tabBar)
            } else {
                NavigationStack(path: $path) {
                    conversations.navigationDestination(for: FirstMateChatRoute.self, destination: destination)
                }
            }
        }
        .herdrFirstMateChrome()
        .firstMateGitCover(item: $gitTarget, model: model)
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
        .onChange(of: fleet.chat.route, initial: true) { _, route in
            guard let route else { return }
            fleet.isCreating = false
            let store = fleet.store(for: route.target)
            store?.graphMode = route.graph
            store?.inspector = route.inspector ?? .overview
            path = [.chat(route.target)]
            if route.inspector != nil { path.append(.info(route.target, assignmentID: route.assignmentID)) }
        }
        // A container of its own, so the identifier names the workspace
        // instead of overriding the columns' identifiers inside it.
        .accessibilityElement(children: .contain)
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
                    .environment(\.firstMateInspectorContext, inspectorContext(target))
            }
        }
    }
    @ViewBuilder private func chat(_ target: FirstMateFeatureTarget, topmost: Bool) -> some View {
        if let store = fleet.store(for: target) {
            FirstMateChatScreen(model: model, fleet: fleet, store: store, target: target, topmost: topmost,
                openInfo: { showInfo(target, inspector: $0, assignmentID: $1) }, readTrackingEnabled: true,
                back: regular ? { clearSelection() } : nil, embedded: regular)
                .environment(\.firstMateInspectorContext, inspectorContext(target))
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
        if regular { setInspector(open: true) }
        if case .info = path.last { path.removeLast() }
        path.append(.info(target, assignmentID: assignmentID))
    }
    private func openBriefing() {
        fleet.selectTarget(nil); fleet.chat.select(.lead)
        path = [.lead]
    }
}

// MARK: - iPad columns

extension FirstMateWorkspaceView {
    /// The list (or its rail), the chat, and the inspector, docked as a column
    /// or floating over the chat as a glass sheet.
    @ViewBuilder fileprivate func regularColumns(_ layout: FirstMateIPadLayout) -> some View {
        let animation: Animation? = reduceMotion ? nil : .snappy(duration: 0.3)
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                // Each column is its own accessibility container, so its
                // identifier survives the identifiers of the screens inside.
                ZStack {
                    if layout.showsRail {
                        FirstMateConversationRail(model: model, fleet: fleet, openFeature: openFeature, openLead: openBriefing)
                            .transition(.opacity)
                    } else {
                        conversations.transition(.opacity)
                    }
                }
                .frame(width: layout.leadingWidth)
                .clipped()
                .composerLayoutMeasurement(id: "first-mate-sidebar-column")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("first-mate-sidebar-column")
                ZStack {
                    if showsBriefing { briefing }
                    else if let target = fleet.selectedTarget { chat(target, topmost: true) }
                    else { ContentUnavailableView("Choose a conversation", systemImage: "sailboat").herdrEmptyColumn() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.firstMateRegularChatControls, chatControls(layout))
                .composerLayoutMeasurement(id: "first-mate-chat-column")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("first-mate-chat-column")
                if layout.inspector == .docked {
                    inspectorPanel(layout)
                        .frame(width: layout.inspectorWidth)
                        .herdrHairline(.leading)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            if layout.inspector == .floating {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { setInspector(open: false) }
                    .accessibilityLabel("Close the inspector")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
                inspectorPanel(layout)
                    .frame(width: layout.inspectorWidth)
                    .clipShape(.rect(cornerRadius: 28, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(HerdrTheme.outline) }
                    .shadow(color: .black.opacity(0.45), radius: 40, x: -12, y: 20)
                    .padding(.trailing, 12).padding(.vertical, 10)
                    .offset(x: inspectorDrag)
                    .gesture(DragGesture(minimumDistance: 16)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            inspectorDrag = max(0, value.translation.width)
                        }
                        .onEnded { value in
                            let close = value.translation.width > 90 || value.predictedEndTranslation.width > 220
                            withAnimation(animation) { inspectorDrag = 0 }
                            if close { setInspector(open: false) }
                        })
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(animation, value: layout)
    }

    @ViewBuilder fileprivate func inspectorPanel(_ layout: FirstMateIPadLayout) -> some View {
        ZStack {
            if let target = fleet.selectedTarget, let store = fleet.store(for: target) {
                FirstMateInfoScreen(model: model, fleet: fleet, store: store, target: target,
                    assignmentID: assignmentID(for: target), openFeature: openFeature, embedded: true)
                    .environment(\.firstMateInspectorContext, inspectorContext(target))
                    .id(target)
            } else {
                ContentUnavailableView("Conversation info", systemImage: "info.circle",
                    description: Text("Select a conversation to see its overview and saved evidence."))
                    .herdrEmptyColumn()
                    .overlay(alignment: .topTrailing) { FirstMateInspectorPanelButtons().padding(8) }
            }
        }
        .environment(\.firstMateInspectorPanelControls, FirstMateInspectorPanelControls(
            isFloating: layout.inspector == .floating, canPin: layout.canPin, isPinned: layout.inspector == .docked && inspectorPinned,
            togglePin: { inspectorPinned.toggle(); inspectorOpen = true },
            close: { setInspector(open: false) }))
        .composerLayoutMeasurement(id: "first-mate-info-column")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-info-column")
    }

    fileprivate func chatControls(_ layout: FirstMateIPadLayout) -> FirstMateRegularChatControls {
        FirstMateRegularChatControls(
            listIsRail: layout.showsRail,
            toggleList: { listPreference = layout.showsRail ? .full : .rail },
            inspectorOpen: layout.inspectorOpen,
            toggleInspector: { setInspector(open: !layout.inspectorOpen) },
            showInspector: { tab in
                if let target = fleet.selectedTarget { fleet.store(for: target)?.inspector = tab }
                setInspector(open: true)
            })
    }

    fileprivate func setInspector(open: Bool) {
        inspectorOpen = open
        if !open { inspectorPinned = false }
        inspectorDrag = 0
    }

    fileprivate func inspectorContext(_ target: FirstMateFeatureTarget) -> FirstMateInspectorContext {
        let title = fleet.chat.conversation(for: target, fleet: fleet)?.name
            ?? fleet.store(for: target)?.snapshots[target.featureID]?.feature.title ?? "Feature"
        return FirstMateInspectorContext(model: model, target: target, featureTitle: title, openGit: { gitTarget = $0 },
                                         conversation: fleet.chat.conversation(for: target, fleet: fleet),
                                         machineName: model.machineName(target.machineID))
    }
}

private extension View {
    /// An empty iPad column keeps the dusk and pane glass instead of the
    /// split view's plain black column.
    func herdrEmptyColumn() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, drawsDusk: true).ignoresSafeArea() }
            .foregroundStyle(HerdrTheme.secondaryText)
    }
}
