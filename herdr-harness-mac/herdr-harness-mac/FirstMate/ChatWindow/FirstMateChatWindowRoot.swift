import SwiftUI

/// How the chat window arranges its columns. Like Telegram, the conversation
/// list is either an avatar rail or an expanded list at least
/// `minimumExpandedSidebarWidth` wide: dragging the divider narrower holds
/// that width until the drag passes `collapseBelow`, then snaps to the rail.
/// The inspector is a trailing column that extends the window rather than
/// taking width from chat (see `FirstMateChatWindowExtender`).
struct FirstMateChatWindowLayout: Equatable {
    enum Sidebar: Equatable { case full, rail }

    /// The avatar rail: a dot column and a 48 pt avatar, with room for the
    /// traffic lights above.
    static let railWidth: CGFloat = 80
    static let minimumExpandedSidebarWidth: CGFloat = 260
    static let maximumSidebarWidth: CGFloat = 480
    /// A drag proposing less than this snaps to the rail; more expands.
    static let collapseBelow: CGFloat = 170
    /// Chat never gets narrower than this; the list collapses first.
    static let minimumChatWidth: CGFloat = 380
    static let minimumInspectorWidth: CGFloat = 320
    static let maximumInspectorWidth: CGFloat = 720
    /// With no preference, the inspector opens at this width and wider.
    static let autoOpenWidth: CGFloat = 1280
    /// The chat header's height; the inspector's tab bar lines up with it.
    static let headerHeight: CGFloat = 60
    /// The window's minimum without the inspector: a rail beside the
    /// narrowest chat.
    static var minimumWindowWidth: CGFloat { railWidth + minimumChatWidth }

    var sidebar: Sidebar
    var sidebarWidth: CGFloat

    /// `width` excludes the inspector column. `preferredSidebarWidth` is
    /// persisted independently of window resizing, so a narrow window
    /// collapses the list to the rail and widening restores the chosen width.
    static func resolve(width: CGFloat, preferredSidebarWidth: CGFloat) -> FirstMateChatWindowLayout {
        let room = width - minimumChatWidth
        guard preferredSidebarWidth >= minimumExpandedSidebarWidth, room >= minimumExpandedSidebarWidth else {
            return FirstMateChatWindowLayout(sidebar: .rail, sidebarWidth: railWidth)
        }
        let sidebarWidth = min(preferredSidebarWidth, maximumSidebarWidth, room)
        return FirstMateChatWindowLayout(sidebar: .full, sidebarWidth: sidebarWidth)
    }

    /// The preference a divider drag or arrow step proposing `proposed`
    /// stores: the rail below `collapseBelow`, else an expanded width.
    static func snappedSidebarWidth(_ proposed: CGFloat) -> CGFloat {
        guard proposed >= collapseBelow else { return railWidth }
        return min(max(proposed, minimumExpandedSidebarWidth), maximumSidebarWidth)
    }

    /// An arrow-key step from the displayed width: the rail and the minimum
    /// text width are one step apart, like the drag's snap.
    static func steppedSidebarWidth(from displayed: CGFloat, by step: CGFloat) -> CGFloat {
        if displayed < minimumExpandedSidebarWidth {
            return step > 0 ? minimumExpandedSidebarWidth : railWidth
        }
        let proposed = displayed + step
        return proposed < minimumExpandedSidebarWidth ? railWidth : min(proposed, maximumSidebarWidth)
    }

    static func clampedInspectorWidth(_ proposed: CGFloat) -> CGFloat {
        guard proposed.isFinite else { return CGFloat(FirstMateChatPreferences.defaultInspectorWidth) }
        return min(max(proposed, minimumInspectorWidth), maximumInspectorWidth)
    }

    /// Resizing the inspector leaves the displayed list and at least 380 pt
    /// of chat intact. Widening the window makes more inspector room available.
    static func resizedInspectorWidth(_ proposed: CGFloat, total: CGFloat, sidebar: CGFloat) -> CGFloat {
        let room = max(minimumInspectorWidth, total - sidebar - minimumChatWidth)
        return min(clampedInspectorWidth(proposed), room)
    }

    static func inspectorVisible(width: CGFloat, preference: Bool?) -> Bool {
        preference ?? (width >= autoOpenWidth)
    }

    /// The width decides whether the inspector starts open only once, on the
    /// window's first layout; after that it changes only when the person
    /// toggles it, never because the window was resized.
    static func settledInspectorPreference(width: CGFloat, preference: Bool?) -> Bool? {
        guard preference == nil, width > 0 else { return preference }
        return inspectorVisible(width: width, preference: nil)
    }

    /// Whole points suppress redundant root updates from fractional resize
    /// noise without delaying any width that can affect the column layout.
    static func quantizedWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return width.rounded()
    }
}

/// Places the list, chat, and inspector side by side from the width this
/// layout is offered right now. Chat gets the exact remainder, so it is never
/// probed at other widths while typing, and a shrinking window can never
/// leave the columns wider than the window.
struct FirstMateChatColumnsLayout: Layout {
    var sidebarWidth: CGFloat
    var inspectorWidth: CGFloat
    /// While the window's edge slides, chat holds this width and the
    /// inspector shows only what the window has added so far.
    var pinnedChatWidth: CGFloat?

    var animatableData: CGFloat {
        get { inspectorWidth }
        set { inspectorWidth = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = proposal.height ?? 0
        let width = proposal.width ?? (sidebarWidth + FirstMateChatWindowLayout.minimumChatWidth + inspectorWidth)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = Self.columnWidths(
            total: bounds.width,
            sidebar: sidebarWidth,
            inspector: inspectorWidth,
            pinnedChat: pinnedChatWidth
        )
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width = index < widths.count ? widths[index] : 0
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    /// Sidebar, chat, inspector. The list and the inspector keep their widths
    /// as long as they fit; chat takes what is left. A pinned chat width
    /// instead gives the inspector what is left, up to its full width.
    static func columnWidths(total: CGFloat, sidebar: CGFloat, inspector: CGFloat, pinnedChat: CGFloat? = nil) -> [CGFloat] {
        let total = max(0, total)
        let sidebar = min(max(0, sidebar), total)
        let inspector = if let pinnedChat {
            min(max(0, total - sidebar - pinnedChat), max(0, inspector))
        } else {
            min(max(0, inspector), total - sidebar)
        }
        return [sidebar, total - sidebar - inspector, inspector]
    }
}

/// The First Mate chat window: conversation list, chat, and inspector.
struct FirstMateChatWindowRoot: View {
    let model: HerdrAppModel
    let shell: HerdrShellState
    let modelFavorites: ModelFavoritesStore
    @State private var session: FirstMateChatWindowSession
    @State private var searchFocusRequest = 0
    @State private var composerFocusRequest = 0
    @State private var createOrigin: FirstMateChatCreateOrigin?
    @AppStorage(FirstMateChatPreferences.sidebarWidthKey)
    private var storedSidebarWidth = FirstMateChatPreferences.defaultSidebarWidth
    @State private var liveSidebarWidth: CGFloat?
    @AppStorage(FirstMateChatPreferences.inspectorWidthKey)
    private var storedInspectorWidth = FirstMateChatPreferences.defaultInspectorWidth
    @State private var liveInspectorWidth: CGFloat?
    @State private var availableWidth = FirstMateChatWindowLayout.minimumWindowWidth
    @State private var extender = FirstMateChatWindowExtender()
    /// Where the inspector is heading: the person's last toggle, applied.
    @State private var inspectorOpen = false
    /// Whether the inspector column exists; it stays while it slides closed.
    @State private var inspectorPresented = false
    /// The column's width when it is not sliding with the window's edge.
    @State private var inspectorTarget: CGFloat = 0
    /// Set while the window's edge moves: the list and chat keep these
    /// widths and the inspector gets whatever the window adds beyond them.
    @State private var inspectorSlide: InspectorSlide?
    /// The inspector's first state comes from the window's first width.
    @State private var didSettleInspector = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.scenePhase) private var scenePhase

    init(model: HerdrAppModel, shell: HerdrShellState, modelFavorites: ModelFavoritesStore) {
        self.init(session: FirstMateChatWindowSession(model: model, shell: shell), modelFavorites: modelFavorites)
    }

    /// A window over an existing session (render tests seed its selection).
    init(session: FirstMateChatWindowSession, modelFavorites: ModelFavoritesStore) {
        model = session.model
        shell = session.shell
        self.modelFavorites = modelFavorites
        _session = State(initialValue: session)
    }

    struct InspectorSlide: Equatable {
        var layout: FirstMateChatWindowLayout
        var chatWidth: CGFloat
    }

    var body: some View {
        let content = windowLayout(layout: currentLayout)
            .environment(\.openURL, OpenURLAction { url in openMention(url) })
        let presented = presentationSheets(content)
        let routed = routingObservers(presented)
        activityObservers(routed)
    }

    private func presentationSheets<Content: View>(_ content: Content) -> some View {
        content.sheet(isPresented: createSheetBinding, onDismiss: finishCreate) {
            if let store = session.createStore {
                FirstMateCreateSheet(store: store, initialGoal: session.createGoal)
            }
        }
        .sheet(item: $session.presentationEditTarget) { conversation in
            FirstMateConversationPresentationEditor(conversation: conversation) { label, emoji in
                await session.savePresentation(conversation.id, label: label, emoji: emoji)
            }
        }
        .sheet(item: $session.archiveCandidate) { target in
            FirstMateFleetArchiveSheet(index: shell.firstMateFleet, target: target,
                demoStore: session.isDemo ? session.store(for: target.machineID) : nil) {
                session.didArchive(target)
            }
        }
    }

    private func routingObservers<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: session.createStore.map(ObjectIdentifier.init), initial: true) { _, store in
            createOrigin = store == nil ? nil : session.createOrigin
        }
        .onChange(of: shell.firstMateChatExactOpenRequest, initial: true) { _, request in
            guard let request else { return }
            shell.firstMateChatExactOpenRequest = nil
            session.applyExactOpenRequest(request)
        }
        .onChange(of: shell.firstMateChatOpenRequest, initial: true) { _, request in
            guard let request else { return }
            shell.firstMateChatOpenRequest = nil
            session.applyOpenRequest(request)
        }
        .onChange(of: shell.firstMateChatOpenLeadRequest) { _, _ in
            session.select(.lead, focusComposer: true)
        }
        .onChange(of: session.selectionIsUnresolvable) { _, unresolvable in
            if unresolvable { session.select(.lead) }
        }
        .onChange(of: session.inspectorPreference ?? false) { _, open in
            setInspector(open: open)
        }
    }

    private func activityObservers<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: controlActiveState, initial: true) { _, activeState in
            session.setActivity(isKey: activeState == .key, isBackground: scenePhase == .background)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            session.setActivity(isKey: controlActiveState == .key, isBackground: phase == .background)
        }
        .task { await session.run() }
        .accessibilityIdentifier("first-mate-chat-window")
    }

    /// The list's layout: frozen while the inspector slides, else resolved
    /// from the width left beside the inspector.
    private var currentLayout: FirstMateChatWindowLayout {
        if let inspectorSlide { return inspectorSlide.layout }
        return FirstMateChatWindowLayout.resolve(
            width: availableWidth - (inspectorPresented ? inspectorTarget : 0),
            preferredSidebarWidth: liveSidebarWidth ?? CGFloat(storedSidebarWidth)
        )
    }

    private var preferredInspectorWidth: CGFloat {
        FirstMateChatWindowLayout.clampedInspectorWidth(CGFloat(storedInspectorWidth))
    }

    /// The window's minimum grows by the inspector once it has settled open,
    /// so dragging the window narrower never squeezes chat below its floor.
    private var minimumWidth: CGFloat {
        FirstMateChatWindowLayout.minimumWindowWidth
            + (inspectorPresented && inspectorSlide == nil ? inspectorTarget : 0)
    }

    private func windowLayout(layout: FirstMateChatWindowLayout) -> some View {
        FirstMateChatColumnsLayout(
            sidebarWidth: layout.sidebarWidth,
            inspectorWidth: inspectorPresented ? inspectorTarget : 0,
            pinnedChatWidth: inspectorSlide?.chatWidth
        ) {
            FirstMateChatSidebar(
                session: session,
                isRail: layout.sidebar == .rail,
                searchFocusRequest: searchFocusRequest,
                onNewFeature: startNewFeature
            )
            .background { HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground) }
            .herdrHairline(.trailing)

            chatColumn(layout: layout)

            if inspectorPresented {
                inspectorColumn
            }
        }
        // `minWidth: 0` keeps the measured width equal to the window's even
        // when a column briefly asks for more, so shrinking always lands.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Above both surfaces so the full six-point strip remains draggable
        // even where chat would otherwise win hit testing.
        .overlay(alignment: .leading) {
            sidebarResizeHandle(displayedWidth: layout.sidebarWidth)
                .offset(x: layout.sidebarWidth - 3)
        }
        .overlay(alignment: .trailing) {
            if inspectorPresented, inspectorOpen, inspectorSlide == nil {
                inspectorResizeHandle
                    .offset(x: -inspectorTarget + 3)
            }
        }
        .background { shortcuts }
        .background { FirstMateChatWindowReader(extender: extender) }
        .onKeyPress(.escape) {
            guard inspectorOpen else { return .ignored }
            session.inspectorPreference = false
            return .handled
        }
        .onGeometryChange(for: CGFloat.self) {
            FirstMateChatWindowLayout.quantizedWidth($0.size.width)
        } action: { width in
            guard width > 0 else { return }
            availableWidth = width
            settleInspector(width: width)
        }
        .frame(minWidth: minimumWidth)
    }

    // MARK: Columns

    private func chatColumn(layout: FirstMateChatWindowLayout) -> some View {
        VStack(spacing: 0) {
            FirstMateChatHeader(session: session, inspectorVisible: inspectorOpen) {
                toggleInspector()
            }
            .contextMenu {
                if case .feature(let id) = session.selection {
                    Button("Rename or Change Emoji…", systemImage: "pencil") { session.requestPresentationEdit(id) }
                    Button("Archive feature…", systemImage: "archivebox") { session.requestArchive(id) }
                }
            }
            FirstMateChatConversationView(session: session, model: model, modelFavorites: modelFavorites)
                .environment(\.firstMateComposerFocusRequest, composerFocusRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) { HerdrHazeBand() }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, base: HerdrTheme.windowBackground) }
        .clipped()
    }

    /// The inspector at its full width, pinned to the window's trailing edge
    /// so it rides out with the edge; chat covers whatever has not arrived.
    private var inspectorColumn: some View {
        FirstMateChatInspectorColumn(
            session: session,
            topInset: FirstMateChatWindowLayout.headerHeight - HerdrTheme.ControlHeight.bar
        )
        .frame(width: liveInspectorWidth ?? preferredInspectorWidth)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .clipped()
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, base: HerdrTheme.windowBackground) }
        .herdrHairline(.leading)
    }

    // MARK: Inspector

    /// On the first real width, the inspector opens inside the window when it
    /// is already wide enough (1280 pt); no edge moves.
    private func settleInspector(width: CGFloat) {
        guard !didSettleInspector else { return }
        didSettleInspector = true
        let preference = FirstMateChatWindowLayout.settledInspectorPreference(
            width: width,
            preference: session.inspectorPreference
        )
        let open = preference ?? false
        inspectorOpen = open
        inspectorPresented = open
        inspectorTarget = open ? preferredInspectorWidth : 0
        session.inspectorPreference = preference
    }

    /// Opening extends the window by the inspector's width and closing gives
    /// it back, so chat keeps its width either way. A window that cannot
    /// resize (full screen) shows the column inside its current width.
    private func setInspector(open: Bool) {
        guard didSettleInspector, open != inspectorOpen else { return }
        inspectorOpen = open
        let inspectorWidth = liveInspectorWidth ?? preferredInspectorWidth
        let layout = currentLayout
        let widths = FirstMateChatColumnsLayout.columnWidths(
            total: availableWidth,
            sidebar: layout.sidebarWidth,
            inspector: inspectorPresented ? inspectorTarget : 0,
            pinnedChat: inspectorSlide?.chatWidth
        )
        let slide = inspectorSlide ?? InspectorSlide(layout: layout, chatWidth: widths[1])
        let animation: Animation? = reduceMotion ? nil : .snappy(duration: FirstMateChatWindowExtender.duration)
        if open {
            inspectorSlide = slide
            inspectorPresented = true
            inspectorTarget = inspectorWidth
            let started = extender.resize(by: inspectorWidth, animated: !reduceMotion) {
                inspectorSlide = nil
            }
            if !started {
                inspectorSlide = nil
                inspectorTarget = 0
                withAnimation(animation) { inspectorTarget = inspectorWidth }
            }
        } else {
            inspectorSlide = slide
            let started = extender.resize(by: -inspectorWidth, animated: !reduceMotion) {
                inspectorPresented = false
                inspectorTarget = 0
                inspectorSlide = nil
            }
            if !started {
                inspectorSlide = nil
                withAnimation(animation) {
                    inspectorTarget = 0
                } completion: {
                    if !inspectorOpen { inspectorPresented = false }
                }
            }
        }
    }

    // MARK: Keyboard

    /// ⌘K focuses search and ⌘I toggles the inspector while this window is
    /// key. The app menus bind the same keys (Navigate ▸ Open Chat, Format ▸
    /// Italic); the window's own shortcuts are meant to answer first here.
    private var shortcuts: some View {
        ZStack {
            Button("Search conversations") { focusSearch() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Toggle inspector") { toggleInspector() }
                .keyboardShortcut("i", modifiers: .command)
        }
        .buttonStyle(.herdrPlain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func toggleInspector() {
        session.inspectorPreference = !inspectorOpen
    }

    /// Search remains keyboard reachable from the rail: ⌘K first expands the
    /// list to its minimum text width, then focuses its field.
    private func focusSearch() {
        if currentLayout.sidebar == .rail {
            storedSidebarWidth = Double(FirstMateChatWindowLayout.minimumExpandedSidebarWidth)
        }
        searchFocusRequest &+= 1
    }

    /// A draggable split handle with keyboard and VoiceOver parity. Like
    /// Telegram's, it holds the list at its minimum text width until the drag
    /// passes the collapse point, then snaps to the rail (and back). The
    /// persisted preference is not reduced when the whole window temporarily
    /// forces the rail, so widening the window restores the chosen size.
    private func sidebarResizeHandle(displayedWidth: CGFloat) -> some View {
        FirstMateChatResizeHandle(
            displayedWidth: displayedWidth,
            widthDirection: 1,
            label: "Conversation list width",
            value: displayedWidth < FirstMateChatWindowLayout.minimumExpandedSidebarWidth
                ? "Avatars only" : "\(Int(displayedWidth)) points",
            identifier: "first-mate-chat-sidebar-resize-handle",
            help: "Drag to resize the conversation list; drag past its minimum to show avatars only",
            onResize: { proposed, finished in
                let width = FirstMateChatWindowLayout.snappedSidebarWidth(proposed)
                if finished {
                    storedSidebarWidth = Double(width)
                    liveSidebarWidth = nil
                } else {
                    liveSidebarWidth = width
                }
            },
            onStep: { step in
                storedSidebarWidth = Double(FirstMateChatWindowLayout.steppedSidebarWidth(from: displayedWidth, by: step))
            }
        )
        .disabled(inspectorSlide != nil)
    }

    private var inspectorResizeHandle: some View {
        FirstMateChatResizeHandle(
            displayedWidth: inspectorTarget,
            widthDirection: -1,
            label: "Inspector width",
            value: "\(Int(inspectorTarget)) points",
            identifier: "first-mate-chat-inspector-resize-handle",
            help: "Drag left to widen the inspector or right to narrow it",
            onResize: resizeInspector,
            onStep: { resizeInspector(to: inspectorTarget + $0, finished: true) }
        )
    }

    private func resizeInspector(to proposed: CGFloat, finished: Bool) {
        let width = FirstMateChatWindowLayout.resizedInspectorWidth(
            proposed, total: availableWidth, sidebar: currentLayout.sidebarWidth
        )
        inspectorTarget = width
        if finished {
            storedInspectorWidth = Double(width)
            liveInspectorWidth = nil
        } else {
            liveInspectorWidth = width
        }
    }

    // MARK: Routing

    /// The sidebar ＋: My First Mate, with its composer focused.
    private func startNewFeature() {
        session.select(.lead, focusComposer: true)
        composerFocusRequest &+= 1
    }

    private var createSheetBinding: Binding<Bool> {
        Binding(
            get: { session.createStore?.isCreating ?? false },
            set: { if !$0 { finishCreate() } }
        )
    }

    /// Runs when the sheet closes (the binding and `onDismiss` both call it;
    /// the second call finds nothing to do).
    private func finishCreate() {
        session.finishCreate(from: createOrigin)
        createOrigin = nil
    }

    /// `herdr://first-mate` mention links open in this window and never reach
    /// the app's deep-link handler; every other link keeps the system action.
    private func openMention(_ url: URL) -> OpenURLAction.Result {
        guard let target = FirstMateMention.parse(url) else { return .systemAction }
        if let machineID = Self.machineID(
            for: target.featureID,
            selected: session.selectedConversationID,
            conversations: session.conversations
        ) {
            session.open(target, machineID: machineID)
        }
        return .handled
    }

    /// A mention names a feature, not a machine: prefer the current chat's
    /// machine, then any machine that lists the feature.
    static func machineID(
        for featureID: String,
        selected: FirstMateFleetFeatureID?,
        conversations: [FirstMateConversation]
    ) -> String? {
        if let selected {
            let sameMachine = FirstMateFleetFeatureID(machineID: selected.machineID, featureID: featureID)
            if conversations.contains(where: { $0.id == sameMachine }) { return selected.machineID }
        }
        return conversations.first { $0.featureID == featureID }?.machineID
    }
}

extension EnvironmentValues {
    /// Bumped when the chat window asks My First Mate's composer to take
    /// focus (the sidebar ＋). The conversation view focuses its composer
    /// whenever the value changes.
    @Entry var firstMateComposerFocusRequest = 0
}

/// Where a create sheet started: the machine and the feature its store had
/// selected, so a new selection afterwards is the created feature.
struct FirstMateChatCreateOrigin: Equatable {
    let machineID: String
    let selectedFeatureID: String?
}

extension FirstMateChatWindowSession {
    /// The showing create sheet's origin, or nil when no sheet shows.
    var createOrigin: FirstMateChatCreateOrigin? {
        guard let createStore,
              let machineID = createMachineIDs.first(where: { store(for: $0) === createStore }) else { return nil }
        return FirstMateChatCreateOrigin(machineID: machineID, selectedFeatureID: createStore.selectedFeatureID)
    }

    /// Closes the create sheet. A feature it created (its store now selects a
    /// different, unarchived feature it holds) opens here, and the fleet and
    /// the main window refresh so the list shows it right away.
    @discardableResult
    func finishCreate(from origin: FirstMateChatCreateOrigin?) -> FirstMateFleetFeatureID? {
        defer { endCreate() }
        guard let origin, let createStore,
              let featureID = createStore.selectedFeatureID, featureID != origin.selectedFeatureID,
              let snapshot = createStore.snapshots[featureID], !snapshot.feature.isArchived else { return nil }
        let created = FirstMateFleetFeatureID(machineID: origin.machineID, featureID: featureID)
        select(.feature(created), focusComposer: true)
        didMutate(machineID: origin.machineID)
        return created
    }

    /// Opens a Dock-menu or "Open in window" request. Before the list has
    /// loaded, the request waits. A feature the list does not show yet (one
    /// just created elsewhere) still opens on its machine's store, and the
    /// fleet refreshes; ``selectionIsUnresolvable`` falls back to My First
    /// Mate if the store turns out not to have it. A machine this window
    /// cannot reach opens My First Mate.
    func applyOpenRequest(_ request: FirstMateFleetFeatureID) {
        let conversations = conversations
        if conversations.isEmpty {
            pendingOpen = request
            wakeRefresh()
        } else if conversations.contains(where: { $0.id == request }) {
            select(.feature(request), focusComposer: true)
        } else if store(for: request.machineID) != nil {
            select(.feature(request), focusComposer: true)
            didMutate(machineID: request.machineID)
        } else {
            select(.lead)
        }
    }

    /// The selected chat will never load: it is not in the list, holds no
    /// snapshot, and its machine has no store, or the store's refresh
    /// rejected it (it selected another feature) or failed. An archived or
    /// removed chat whose snapshot is still held stays open.
    var selectionIsUnresolvable: Bool {
        guard exactOpenRequest == nil else { return false }
        return Self.selectionIsUnresolvable(
            selectedConversationID,
            conversations: conversations,
            store: selectedConversationID.flatMap { store(for: $0.machineID) }
        )
    }

    static func selectionIsUnresolvable(
        _ id: FirstMateFleetFeatureID?,
        conversations: [FirstMateConversation],
        store: FirstMateStore?
    ) -> Bool {
        guard let id, !conversations.isEmpty, !conversations.contains(where: { $0.id == id }) else { return false }
        guard let store else { return true }
        if store.snapshots[id.featureID] != nil { return false }
        return store.selectedFeatureID != id.featureID || (store.hasLoaded && store.error != nil)
    }
}
