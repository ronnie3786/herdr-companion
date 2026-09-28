import SwiftUI

/// How the chat window arranges its columns at a given width: the sidebar
/// (320 pt, or a 76 pt rail below 760 pt), the flexible chat, and the 360 pt
/// inspector, which sits inline from 1140 pt and floats over the chat below.
struct FirstMateChatWindowLayout: Equatable {
    enum Sidebar: Equatable { case full, rail }
    enum Inspector: Equatable { case hidden, inline, overlay }

    static let sidebarWidth: CGFloat = 320
    static let railWidth: CGFloat = 76
    static let inspectorWidth: CGFloat = 360
    /// Below this width the sidebar collapses to the rail.
    static let railBelow: CGFloat = 760
    /// Below this width the inspector overlays the chat instead of taking a column.
    static let overlayBelow: CGFloat = 1140
    /// With no preference, the inspector opens at this width and wider.
    static let autoOpenWidth: CGFloat = 1280
    /// The chat header's height; the inspector's tab bar ends on its bottom edge.
    static let headerHeight: CGFloat = 60

    var sidebar: Sidebar
    var inspector: Inspector

    /// `inspectorPreference` is the person's choice (the header toggle or
    /// ⌘I); nil follows the width.
    static func resolve(width: CGFloat, inspectorPreference: Bool?) -> FirstMateChatWindowLayout {
        let sidebar: Sidebar = width < railBelow ? .rail : .full
        let isOpen = inspectorVisible(width: width, preference: inspectorPreference)
        let inspector: Inspector = !isOpen ? .hidden : width < overlayBelow ? .overlay : .inline
        return FirstMateChatWindowLayout(sidebar: sidebar, inspector: inspector)
    }

    static func inspectorVisible(width: CGFloat, preference: Bool?) -> Bool {
        preference ?? (width >= autoOpenWidth)
    }

    var sidebarWidth: CGFloat { sidebar == .rail ? Self.railWidth : Self.sidebarWidth }
}

/// The First Mate chat window: conversation list, chat, and inspector.
struct FirstMateChatWindowRoot: View {
    let model: HerdrAppModel
    let shell: HerdrShellState
    let modelFavorites: ModelFavoritesStore
    @State private var session: FirstMateChatWindowSession
    @State private var searchFocusRequest = 0

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
            let layout = FirstMateChatWindowLayout.resolve(width: width, inspectorPreference: session.inspectorPreference)
            HStack(spacing: 0) {
                FirstMateChatSidebar(
                    session: session,
                    isRail: layout.sidebar == .rail,
                    searchFocusRequest: searchFocusRequest
                )
                .frame(width: layout.sidebarWidth)
                .background { HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: HerdrTheme.railBackground) }
                .herdrHairline(.trailing)

                chatColumn(layout: layout, width: width)

                if layout.inspector == .inline {
                    FirstMateChatInspectorColumn(
                        session: session,
                        topInset: FirstMateChatWindowLayout.headerHeight - HerdrTheme.ControlHeight.bar
                    )
                    .frame(width: FirstMateChatWindowLayout.inspectorWidth)
                    .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane, base: HerdrTheme.windowBackground) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.24), value: layout)
            .background { shortcuts(width: width) }
            .onKeyPress(.escape) {
                guard layout.inspector == .overlay else { return .ignored }
                session.inspectorPreference = false
                return .handled
            }
        }
        .environment(\.openURL, OpenURLAction { url in openMention(url) })
        .sheet(isPresented: createSheetBinding, onDismiss: session.endCreate) {
            if let store = session.createStore {
                FirstMateCreateSheet(store: store, initialGoal: session.createGoal)
            }
        }
        .onChange(of: shell.firstMateChatOpenRequest, initial: true) { _, request in
            guard let request else { return }
            shell.firstMateChatOpenRequest = nil
            applyOpenRequest(request)
        }
        .onChange(of: session.conversations.map(\.id)) { _, ids in
            fallBackToLeadIfSelectionVanished(ids: ids)
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
            FirstMateChatConversationView(session: session, model: model, modelFavorites: modelFavorites)
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
            Button("Search conversations") { searchFocusRequest &+= 1 }
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

    // MARK: Routing

    private var createSheetBinding: Binding<Bool> {
        Binding(
            get: { session.createStore?.isCreating ?? false },
            set: { if !$0 { session.endCreate() } }
        )
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

    /// Opens a Dock-menu or "Open in window" request. An id the list does not
    /// know opens My First Mate instead; before the list has loaded, the
    /// request waits in the session.
    private func applyOpenRequest(_ request: FirstMateFleetFeatureID) {
        let conversations = session.conversations
        if conversations.isEmpty {
            session.pendingOpen = request
        } else if conversations.contains(where: { $0.id == request }) {
            session.select(.feature(request))
        } else {
            session.select(.lead)
        }
    }

    /// An archived or removed chat that no longer loads falls back to My First Mate.
    private func fallBackToLeadIfSelectionVanished(ids: [FirstMateFleetFeatureID]) {
        guard let selected = session.selectedConversationID, !ids.isEmpty, !ids.contains(selected),
              session.selectedSnapshot == nil else { return }
        session.select(.lead)
    }
}
