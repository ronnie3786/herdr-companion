import SwiftUI

/// How the chat window arranges its surfaces at a given width. The person can
/// drag the conversation list from an avatar rail through wider text layouts;
/// the inspector always floats over chat instead of becoming a sizing column.
struct FirstMateChatWindowLayout: Equatable {
    enum Sidebar: Equatable { case full, rail }
    enum Inspector: Equatable { case hidden, overlay }

    static let minimumSidebarWidth: CGFloat = 76
    static let maximumSidebarWidth: CGFloat = 480
    /// Text returns at this width. The avatar and status dot remain below it.
    static let compactBelow: CGFloat = 220
    /// Protect a useful conversation width when the whole window narrows.
    static let minimumChatWidth: CGFloat = 360
    static let inspectorWidth: CGFloat = 360
    /// With no preference, the inspector opens at this width and wider.
    static let autoOpenWidth: CGFloat = 1280
    /// The chat header's height; the overlay starts below its toggle.
    static let headerHeight: CGFloat = 60

    var sidebar: Sidebar
    var inspector: Inspector
    var sidebarWidth: CGFloat

    /// `preferredSidebarWidth` is persisted independently of window resizing,
    /// so a temporarily narrow window restores the person's wider list later.
    static func resolve(
        width: CGFloat,
        preferredSidebarWidth: CGFloat,
        inspectorPreference: Bool?
    ) -> FirstMateChatWindowLayout {
        let sidebarWidth = resolvedSidebarWidth(preferred: preferredSidebarWidth, availableWidth: width)
        let sidebar: Sidebar = sidebarWidth < compactBelow ? .rail : .full
        let inspector: Inspector = inspectorVisible(width: width, preference: inspectorPreference) ? .overlay : .hidden
        return FirstMateChatWindowLayout(sidebar: sidebar, inspector: inspector, sidebarWidth: sidebarWidth)
    }

    static func resolvedSidebarWidth(preferred: CGFloat, availableWidth: CGFloat) -> CGFloat {
        let preference = min(max(preferred, minimumSidebarWidth), maximumSidebarWidth)
        let availableMaximum = max(minimumSidebarWidth, availableWidth - minimumChatWidth)
        return min(preference, availableMaximum)
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
    @State private var sidebarDragStartWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// The floating inspector's fill, nearly opaque (`rgba(23,22,29,.97)`).
    static let overlayFill = Color(.sRGB, red: 23 / 255, green: 22 / 255, blue: 29 / 255, opacity: 0.97)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let preferredSidebarWidth = liveSidebarWidth ?? CGFloat(storedSidebarWidth)
            let layout = FirstMateChatWindowLayout.resolve(
                width: width,
                preferredSidebarWidth: preferredSidebarWidth,
                inspectorPreference: session.inspectorPreference
            )
            HStack(spacing: 0) {
                FirstMateChatSidebar(
                    session: session,
                    isRail: layout.sidebar == .rail,
                    searchFocusRequest: searchFocusRequest,
                    onNewFeature: startNewFeature
                )
                .frame(width: layout.sidebarWidth)
                .background { HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground) }
                .herdrHairline(.trailing)

                chatColumn(layout: layout, width: width)
            }
            // Above both surfaces so the full six-point strip remains
            // draggable even where chat would otherwise win hit testing.
            .overlay(alignment: .leading) {
                sidebarResizeHandle(availableWidth: width, displayedWidth: layout.sidebarWidth)
                    .offset(x: layout.sidebarWidth - 3)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: layout.inspector)
            .background { shortcuts(width: width) }
            .onKeyPress(.escape) {
                guard layout.inspector == .overlay else { return .ignored }
                session.inspectorPreference = false
                return .handled
            }
            .onChange(of: width, initial: true) { _, width in
                session.inspectorPreference = FirstMateChatWindowLayout.settledInspectorPreference(
                    width: width,
                    preference: session.inspectorPreference
                )
            }
        }
        .environment(\.openURL, OpenURLAction { url in openMention(url) })
        .sheet(isPresented: createSheetBinding, onDismiss: finishCreate) {
            if let store = session.createStore {
                FirstMateCreateSheet(store: store, initialGoal: session.createGoal)
            }
        }
        .sheet(item: $session.archiveCandidate) { target in
            FirstMateArchiveConfirmation(feature: target.feature) { reason in
                await session.archive(target, reason: reason)
            }
        }
        .onChange(of: session.createStore.map(ObjectIdentifier.init), initial: true) { _, store in
            createOrigin = store == nil ? nil : session.createOrigin
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
        .task { await session.run() }
        .accessibilityIdentifier("first-mate-chat-window")
    }

    // MARK: Columns

    private func chatColumn(layout: FirstMateChatWindowLayout, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            FirstMateChatHeader(session: session, inspectorVisible: layout.inspector != .hidden) {
                toggleInspector(width: width)
            }
            .contextMenu {
                if case .feature(let id) = session.selection {
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
        .overlay(alignment: .topTrailing) {
            if layout.inspector == .overlay {
                // Below the header, so its toggle stays reachable; no scrim.
                GeometryReader { column in
                    FirstMateChatInspectorColumn(session: session, topInset: 0)
                        .frame(width: max(0, min(FirstMateChatWindowLayout.inspectorWidth, column.size.width - 24)))
                        .background(Self.overlayFill)
                        .compositingGroup()
                        .shadow(color: .black.opacity(0.4), radius: 20, x: -9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                .padding(.top, FirstMateChatWindowLayout.headerHeight)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
    }

    // MARK: Keyboard

    /// ⌘K focuses search and ⌘I toggles the inspector while this window is
    /// key. The app menus bind the same keys (Navigate ▸ Open Chat, Format ▸
    /// Italic); the window's own shortcuts are meant to answer first here.
    private func shortcuts(width: CGFloat) -> some View {
        ZStack {
            Button("Search conversations") { focusSearch(width: width) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Toggle inspector") { toggleInspector(width: width) }
                .keyboardShortcut("i", modifiers: .command)
        }
        .buttonStyle(.herdrPlain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func toggleInspector(width: CGFloat) {
        let isOpen = FirstMateChatWindowLayout.inspectorVisible(width: width, preference: session.inspectorPreference)
        session.inspectorPreference = !isOpen
    }

    /// Search remains keyboard reachable from the compact rail: ⌘K first
    /// restores the smallest text width, then focuses its field.
    private func focusSearch(width: CGFloat) {
        if FirstMateChatWindowLayout.resolvedSidebarWidth(
            preferred: CGFloat(storedSidebarWidth),
            availableWidth: width
        ) < FirstMateChatWindowLayout.compactBelow {
            storedSidebarWidth = Double(FirstMateChatWindowLayout.compactBelow)
        }
        searchFocusRequest &+= 1
    }

    /// A draggable split handle with keyboard and VoiceOver parity. The
    /// persisted preference is not reduced when the whole window temporarily
    /// constrains it, so widening the window restores the chosen size.
    private func sidebarResizeHandle(availableWidth: CGFloat, displayedWidth: CGFloat) -> some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if sidebarDragStartWidth == nil { sidebarDragStartWidth = displayedWidth }
                        let proposed = (sidebarDragStartWidth ?? displayedWidth) + value.translation.width
                        liveSidebarWidth = FirstMateChatWindowLayout.resolvedSidebarWidth(
                            preferred: proposed,
                            availableWidth: availableWidth
                        )
                    }
                    .onEnded { _ in
                        if let liveSidebarWidth { storedSidebarWidth = Double(liveSidebarWidth) }
                        liveSidebarWidth = nil
                        sidebarDragStartWidth = nil
                    }
            )
            .focusable()
            .onKeyPress(.leftArrow) { adjustSidebar(by: -20, availableWidth: availableWidth) }
            .onKeyPress(.rightArrow) { adjustSidebar(by: 20, availableWidth: availableWidth) }
            .accessibilityElement()
            .accessibilityLabel("Conversation list width")
            .accessibilityValue("\(Int(displayedWidth)) points")
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 20 : direction == .decrement ? -20 : 0
                adjustSidebar(by: step, availableWidth: availableWidth)
            }
            .accessibilityIdentifier("first-mate-chat-sidebar-resize-handle")
            .help("Drag to resize the conversation list")
    }

    private func adjustSidebar(by step: Double, availableWidth: CGFloat) -> KeyPress.Result {
        guard step != 0 else { return .ignored }
        storedSidebarWidth = Double(FirstMateChatWindowLayout.resolvedSidebarWidth(
            preferred: CGFloat(storedSidebarWidth + step),
            availableWidth: availableWidth
        ))
        return .handled
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
        Self.selectionIsUnresolvable(
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
