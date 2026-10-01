import SwiftUI
import Testing
@testable import herdr_harness_mac

/// The First Mate chat window over the seven-feature chat demo, dark, at the
/// reference sizes. The chat column's content comes from the conversation
/// view; these renders check the window's chrome: sidebar, header, and
/// inspector.
@Suite("First Mate chat window renders", .serialized)
@MainActor
struct FirstMateChatWindowRenderTests {
    static let wide = CGSize(width: 1440, height: 900)
    static let receipts = FirstMateFleetFeatureID(machineID: "demo", featureID: "demo-receipts")

    /// A demo session whose store has loaded, showing `selection`.
    private func session(
        selecting selection: FirstMateChatWindowSession.Selection,
        inspector: FirstMateInspector = .overview,
        inspectorPreference: Bool? = nil
    ) async throws -> FirstMateChatWindowSession {
        let model = HerdrRenderFixtures.demoModel()
        let shell = HerdrShellState(userDefaults: try #require(UserDefaults(suiteName: "FirstMateChatRender.\(UUID().uuidString)")))
        let session = FirstMateChatWindowSession(model: model, shell: shell)
        let store = try #require(session.store(for: FirstMateChatWindowSession.demoMachineID))
        await store.refresh()
        session.select(selection)
        if case .feature = selection {
            _ = try #require(session.selectedSnapshot)
            store.inspector = inspector
        }
        session.inspectorPreference = inspectorPreference
        return session
    }

    private func render(
        _ name: String,
        size: CGSize = Self.wide,
        sidebarWidth: Double = FirstMateChatPreferences.defaultSidebarWidth,
        session: FirstMateChatWindowSession,
        interact: (@MainActor (NSWindow) async throws -> Void)? = nil
    ) async throws {
        let defaults = try #require(UserDefaults(suiteName: "FirstMateChatRender.Layout.\(UUID().uuidString)"))
        defaults.set(sidebarWidth, forKey: FirstMateChatPreferences.sidebarWidthKey)
        let result = try await HerdrRenderHarness.renderWindow(name, size: size, interact: interact) {
            ZStack {
                HerdrDuskBackdrop()
                FirstMateChatWindowRoot(session: session, modelFavorites: ModelFavoritesStore())
            }
            .defaultAppStorage(defaults)
            .environment(\.herdrGlassActive, true)
            .environment(\.herdrHazeActive, true)
            .environment(\.herdrFontScale, .medium)
        }
        result.expectSubstantial()
    }

    @Test("My First Mate at 1440 × 900 with the lead Overview")
    func lead() async throws {
        let session = try await session(selecting: .lead)
        #expect(session.conversations.count == 7)
        try await render("fmchat-chrome-lead-1440.png", session: session)
    }

    @Test("The blocked Receipt export chat at 1440 × 900 with the native inspector")
    func receiptsWide() async throws {
        let session = try await session(selecting: .feature(Self.receipts))
        #expect(session.selectedConversation?.hudStatus == .blocked)
        try await render("fmchat-chrome-receipts-1440.png", session: session)
    }

    @Test("Receipt export at 1440 × 900 with the inspector Git button")
    func inspectorGitButton() async throws {
        let session = try await session(selecting: .feature(Self.receipts), inspectorPreference: true)
        try await render("fmchat-chrome-inspector-git-1440.png", session: session)
    }

    @Test("A demo rename and emoji change render in the row and header")
    func renamedConversation() async throws {
        let session = try await session(selecting: .feature(Self.receipts))
        #expect(await session.savePresentation(Self.receipts, label: "Synthetic launch", emoji: "🪁") == nil)
        #expect(session.selectedConversation?.name == "Synthetic launch")
        #expect(session.selectedConversation?.emoji == "🪁")
        try await render("fmchat-chrome-renamed-1440.png", session: session)
    }

    @Test("The editor content renders over dusk glass")
    func presentationEditor() async throws {
        let session = try await session(selecting: .feature(Self.receipts))
        let conversation = try #require(session.selectedConversation)
        let result = try await HerdrRenderHarness.renderWindow("fmchat-presentation-editor.png",
                                                           size: CGSize(width: 520, height: 500)) {
            ZStack {
                HerdrDuskBackdrop()
                FirstMateConversationPresentationEditor(conversation: conversation, save: { _, _ in nil },
                                                        openEmojiPicker: {})
            }
            .environment(\.herdrFontScale, .medium)
        }
        result.expectSubstantial()
    }

    @Test("At 1000 pt an open inspector is a trailing column beside chat")
    func inspectorColumn() async throws {
        let session = try await session(selecting: .feature(Self.receipts), inspectorPreference: true)
        try await render("fmchat-chrome-inspector-1000.png", size: CGSize(width: 1000, height: 800), session: session)
    }

    @Test("A narrow window collapses an expanded list to the rail instead of pushing it off screen")
    func narrowWindowRail() async throws {
        let session = try await session(selecting: .feature(Self.receipts), inspectorPreference: false)
        try await render(
            "fmchat-chrome-narrow-560.png",
            size: CGSize(width: 560, height: 700),
            sidebarWidth: 420,
            session: session
        )
    }

    @Test("Shrinking a wide window keeps the list on screen and collapses it to the rail")
    func liveShrink() async throws {
        let session = try await session(selecting: .feature(Self.receipts), inspectorPreference: false)
        try await render(
            "fmchat-chrome-live-shrink-560.png",
            size: CGSize(width: 1100, height: 760),
            sidebarWidth: 420,
            session: session
        ) { window in
            for width in stride(from: 1060.0, to: 560, by: -60) {
                window.setFrame(CGRect(x: 0, y: 0, width: width, height: 760), display: true)
                try await Task.sleep(for: .milliseconds(30))
            }
            window.setFrame(CGRect(x: 0, y: 0, width: 560, height: 760), display: true)
            try await Task.sleep(for: .milliseconds(60))
            #expect(window.frame.width == 560)
            #expect(window.minSize.width == FirstMateChatWindowLayout.minimumWindowWidth)
        }
    }

    @Test("Opening the inspector extends the window to the right and closing gives the width back")
    func inspectorExtendsWindow() async throws {
        let session = try await session(selecting: .feature(Self.receipts), inspectorPreference: false)
        try await render(
            "fmchat-chrome-extended-1360.png",
            size: CGSize(width: 1000, height: 760),
            session: session
        ) { window in
            window.setFrame(CGRect(x: 40, y: 40, width: 1000, height: 760), display: true)
            try await Task.sleep(for: .milliseconds(100))
            session.inspectorPreference = true
            try await Task.sleep(for: .milliseconds(700))
            #expect(window.frame.width == 1360, "The window grows by the inspector's width")
            #expect(window.frame.minX == 40, "It grows rightwards when the screen has room")
            session.inspectorPreference = false
            try await Task.sleep(for: .milliseconds(700))
            #expect(window.frame.width == 1000, "Closing gives the width back")
            session.inspectorPreference = true
            try await Task.sleep(for: .milliseconds(700))
            #expect(window.frame.width == 1360)
        }
    }

    @Test("A dragged narrow sidebar is an avatar-only rail")
    func rail() async throws {
        let session = try await session(selecting: .feature(Self.receipts))
        try await render(
            "fmchat-chrome-rail-700.png",
            size: CGSize(width: 700, height: 800),
            sidebarWidth: 120,
            session: session
        )
    }

    @Test("The minimum expanded sidebar renders wrapping conversation titles")
    func wrappingTitles() async throws {
        let session = try await session(selecting: .feature(Self.receipts), inspectorPreference: false)
        try await render(
            "fmchat-chrome-wrapping-titles-1000.png",
            size: CGSize(width: 1000, height: 800),
            sidebarWidth: Double(FirstMateChatWindowLayout.minimumExpandedSidebarWidth),
            session: session
        )
    }

    @Test("Each inspector tab on Receipt export", arguments: FirstMateInspector.allCases)
    func inspectorTab(_ tab: FirstMateInspector) async throws {
        let session = try await session(selecting: .feature(Self.receipts), inspector: tab)
        try await render("fmchat-chrome-tab-\(tab.id).png", session: session)
    }
}

@Suite("First Mate chat window layout")
@MainActor
struct FirstMateChatWindowLayoutTests {
    typealias Layout = FirstMateChatWindowLayout

    private func layout(
        _ width: CGFloat,
        sidebarWidth: CGFloat = CGFloat(FirstMateChatPreferences.defaultSidebarWidth)
    ) -> FirstMateChatWindowLayout {
        Layout.resolve(width: width, preferredSidebarWidth: sidebarWidth)
    }

    @Test("The inspector opens by width only when there is no preference")
    func inspectorVisibility() {
        #expect(Layout.inspectorVisible(width: 1440, preference: nil))
        #expect(Layout.inspectorVisible(width: 1280, preference: nil))
        #expect(!Layout.inspectorVisible(width: 1279, preference: nil))
        #expect(Layout.inspectorVisible(width: 700, preference: true))
        #expect(!Layout.inspectorVisible(width: 1440, preference: false))
    }

    @Test("The width opens or closes the inspector once; resizing afterwards keeps the choice")
    func inspectorSettlesOnce() {
        #expect(Layout.settledInspectorPreference(width: 1320, preference: nil) == true)
        #expect(Layout.settledInspectorPreference(width: 1200, preference: nil) == false)
        #expect(Layout.settledInspectorPreference(width: 0, preference: nil) == nil)
        // Settled open at 1320 pt, then dragged to 1200 pt: still open.
        let settled = Layout.settledInspectorPreference(width: 1320, preference: nil)
        #expect(Layout.settledInspectorPreference(width: 1200, preference: settled) == true)
        #expect(Layout.settledInspectorPreference(width: 1440, preference: false) == false)
    }

    @Test("The list is either the rail or at least its minimum text width")
    func sidebarModes() {
        #expect(layout(1000).sidebar == .full)
        #expect(layout(1000).sidebarWidth == 320)
        #expect(layout(1000, sidebarWidth: Layout.minimumExpandedSidebarWidth).sidebar == .full)
        #expect(layout(1000, sidebarWidth: Layout.minimumExpandedSidebarWidth - 1).sidebar == .rail)
        #expect(layout(1000, sidebarWidth: 120).sidebarWidth == Layout.railWidth)
        #expect(layout(1000, sidebarWidth: 480).sidebarWidth == 480)
        #expect(layout(1000, sidebarWidth: 999).sidebarWidth == Layout.maximumSidebarWidth)
        #expect(FirstMateRowTopLine.titleLineLimit == 2)
    }

    @Test("A drag holds the minimum text width, then snaps to the rail past the collapse point")
    func dragSnaps() {
        #expect(Layout.snappedSidebarWidth(400) == 400)
        #expect(Layout.snappedSidebarWidth(Layout.minimumExpandedSidebarWidth - 40) == Layout.minimumExpandedSidebarWidth)
        #expect(Layout.snappedSidebarWidth(Layout.collapseBelow) == Layout.minimumExpandedSidebarWidth)
        #expect(Layout.snappedSidebarWidth(Layout.collapseBelow - 1) == Layout.railWidth)
        #expect(Layout.snappedSidebarWidth(-50) == Layout.railWidth)
        #expect(Layout.snappedSidebarWidth(900) == Layout.maximumSidebarWidth)
        // Arrow keys: the rail and the minimum text width are one step apart.
        #expect(Layout.steppedSidebarWidth(from: Layout.railWidth, by: 20) == Layout.minimumExpandedSidebarWidth)
        #expect(Layout.steppedSidebarWidth(from: Layout.railWidth, by: -20) == Layout.railWidth)
        #expect(Layout.steppedSidebarWidth(from: Layout.minimumExpandedSidebarWidth, by: -20) == Layout.railWidth)
        #expect(Layout.steppedSidebarWidth(from: 300, by: 20) == 320)
        #expect(Layout.steppedSidebarWidth(from: 470, by: 20) == Layout.maximumSidebarWidth)
    }

    @Test("A narrow window collapses the list to the rail and widening restores it")
    func narrowWindowBounds() {
        let tight = layout(700, sidebarWidth: 480)
        #expect(tight.sidebar == .full)
        #expect(700 - tight.sidebarWidth == Layout.minimumChatWidth)
        let narrow = layout(Layout.minimumChatWidth + Layout.minimumExpandedSidebarWidth - 1, sidebarWidth: 480)
        #expect(narrow.sidebar == .rail)
        #expect(narrow.sidebarWidth == Layout.railWidth)
        #expect(layout(Layout.minimumWindowWidth, sidebarWidth: 480).sidebar == .rail)
        #expect(layout(1200, sidebarWidth: 480).sidebarWidth == 480, "The persisted preference returns when the window widens")
    }

    @Test("Columns always fill exactly the offered width")
    func columnWidths() {
        #expect(FirstMateChatColumnsLayout.columnWidths(total: 1000, sidebar: 320, inspector: 0) == [320, 680, 0])
        #expect(FirstMateChatColumnsLayout.columnWidths(total: 1000, sidebar: 320, inspector: 360) == [320, 320, 360])
        #expect(FirstMateChatColumnsLayout.columnWidths(total: 200, sidebar: 320, inspector: 360) == [200, 0, 0])
        // While the edge slides, chat keeps its width and the inspector grows.
        #expect(FirstMateChatColumnsLayout.columnWidths(total: 1100, sidebar: 320, inspector: 360, pinnedChat: 680) == [320, 680, 100])
        #expect(FirstMateChatColumnsLayout.columnWidths(total: 1500, sidebar: 320, inspector: 360, pinnedChat: 680) == [320, 820, 360])
    }

    @Test("Opening the inspector grows the window rightwards, moving left only at the screen's edge")
    func extenderFrames() {
        let screen = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        let (roomy, roomyShift) = FirstMateChatWindowExtender.grownFrame(NSRect(x: 100, y: 50, width: 1000, height: 800), by: 360, within: screen)
        #expect(roomy == NSRect(x: 100, y: 50, width: 1360, height: 800))
        #expect(roomyShift == 0)

        let (edge, edgeShift) = FirstMateChatWindowExtender.grownFrame(NSRect(x: 600, y: 50, width: 1000, height: 800), by: 360, within: screen)
        #expect(edge == NSRect(x: 440, y: 50, width: 1360, height: 800))
        #expect(edgeShift == 160)
        let restored = FirstMateChatWindowExtender.shrunkFrame(edge, by: 360, restoring: edgeShift, within: screen)
        #expect(restored == NSRect(x: 600, y: 50, width: 1000, height: 800))

        let (full, fullShift) = FirstMateChatWindowExtender.grownFrame(NSRect(x: 0, y: 0, width: 1700, height: 900), by: 360, within: screen)
        #expect(full == NSRect(x: 0, y: 0, width: 1800, height: 900), "A screen too narrow clamps the width")
        #expect(fullShift == 0)
    }

    @Test("Root width updates use whole positive points")
    func quantizedRootWidth() {
        #expect(FirstMateChatWindowLayout.quantizedWidth(699.49) == 699)
        #expect(FirstMateChatWindowLayout.quantizedWidth(699.5) == 700)
        #expect(FirstMateChatWindowLayout.quantizedWidth(-1) == 0)
        #expect(FirstMateChatWindowLayout.quantizedWidth(.infinity) == 0)
    }

    @Test("Bubble measurements clear together when the subview set changes")
    func bubbleMeasurementInvalidation() {
        var cache = FirstMateBubbleStack.Cache()
        cache.intrinsic = .init(width: 320, sizes: [CGSize(width: 200, height: 40)])
        cache.fitted = .init(width: 200, sizes: [CGSize(width: 200, height: 56)])
        cache.invalidate()
        #expect(cache.intrinsic == nil)
        #expect(cache.fitted == nil)
    }

    @Test("A mention opens on the current chat's machine first, then any machine that lists it")
    func mentionMachine() {
        let alpha = conversation("shared", machine: "alpha")
        let beta = conversation("shared", machine: "beta")
        let only = conversation("only-beta", machine: "beta")
        let list = [alpha, beta, only]
        let onBeta = FirstMateFleetFeatureID(machineID: "beta", featureID: "other")
        #expect(FirstMateChatWindowRoot.machineID(for: "shared", selected: onBeta, conversations: list) == "beta")
        #expect(FirstMateChatWindowRoot.machineID(for: "shared", selected: nil, conversations: list) == "alpha")
        let onAlpha = FirstMateFleetFeatureID(machineID: "alpha", featureID: "other")
        #expect(FirstMateChatWindowRoot.machineID(for: "only-beta", selected: onAlpha, conversations: list) == "beta")
        #expect(FirstMateChatWindowRoot.machineID(for: "missing", selected: onAlpha, conversations: list) == nil)
    }

    @Test("Rows read as name, status, and new message")
    func rowAccessibility() {
        #expect(FirstMateConversationRow.accessibilityLabel(for: conversation("a", title: "Receipt export", hud: .blocked, unread: true))
                == "Receipt export, Blocked, new message")
        #expect(FirstMateConversationRow.accessibilityLabel(for: conversation("b", title: "Receipt export", hud: .blocked, unread: false))
                == "Receipt export, Blocked")
        #expect(FirstMateConversationRow.accessibilityLabel(for: conversation("c", title: "Offline sync", hud: .working, unread: true, step: 2))
                == "Offline sync, In review")
    }

    @Test("The lead Overview groups Needs you, Moving, and Done, leaving out empty groups")
    func leadGroups() {
        let list = [
            conversation("a", hud: .working), conversation("b", hud: .blocked), conversation("c", hud: .idle),
            conversation("d", hud: .ready), conversation("e", hud: .turn),
        ]
        let groups = FirstMateLeadOverviewView.groups(list)
        #expect(groups.map(\.title) == ["Needs you", "Moving"])
        #expect(groups[0].conversations.map(\.featureID) == ["b", "d", "e"])
        #expect(groups[1].conversations.map(\.featureID) == ["a", "c"])
        #expect(FirstMateLeadOverviewView.groups([conversation("f", hud: .done)]).map(\.title) == ["Done"])
    }

    private func conversation(
        _ id: String,
        machine: String = "demo",
        title: String? = nil,
        hud: FirstMateHudStatus = .working,
        unread: Bool = false,
        step: Int? = nil
    ) -> FirstMateConversation {
        FirstMateConversation(
            id: FirstMateFleetFeatureID(machineID: machine, featureID: id),
            machineID: machine, machineName: machine, featureID: id,
            title: title ?? "Synthetic \(id)", label: title ?? "Synthetic \(id)", emoji: "🧭",
            hudStatus: hud, featureStatus: "running", stepIndex: step, stepFraction: nil, now: nil,
            previewText: "", previewIsFromUser: false, isWorkingOnReply: false, activityAt: nil,
            latestFirstMateMessageID: nil, isUnread: unread, isArchived: false
        )
    }
}

/// Creating a feature and "Open in window" requests over the chat demo.
@Suite("First Mate chat window routing")
@MainActor
struct FirstMateChatWindowRoutingTests {
    private func loadedDemoSession() async throws -> (FirstMateChatWindowSession, FirstMateStore) {
        let model = HerdrRenderFixtures.demoModel()
        let shell = HerdrShellState(userDefaults: try #require(UserDefaults(suiteName: "FirstMateChatRouting.\(UUID().uuidString)")))
        let session = FirstMateChatWindowSession(model: model, shell: shell)
        let store = try #require(session.store(for: FirstMateChatWindowSession.demoMachineID))
        await store.refresh()
        return (session, store)
    }

    @Test("A feature created from My First Mate opens in the window when the sheet closes")
    func createdFeatureOpens() async throws {
        let (session, store) = try await loadedDemoSession()
        session.select(.lead)
        session.beginCreate(goal: "Synthetic goal for a new feature")
        let origin = try #require(session.createOrigin)
        #expect(origin.machineID == FirstMateChatWindowSession.demoMachineID)
        let created = await store.create(
            title: "Synthetic feature", goal: "Synthetic goal for a new feature",
            cwd: "/tmp/synthetic", requestID: UUID().uuidString
        )
        #expect(created)
        let opened = try #require(session.finishCreate(from: origin))
        #expect(opened.machineID == FirstMateChatWindowSession.demoMachineID)
        #expect(opened.featureID == store.selectedFeatureID)
        #expect(session.selection == .feature(opened))
        #expect(session.selectedSnapshot != nil)
        #expect(!session.selectionIsUnresolvable)
        #expect(session.createStore == nil)
    }

    @Test("A cancelled create sheet stays on My First Mate")
    func cancelledCreateStays() async throws {
        let (session, _) = try await loadedDemoSession()
        session.select(.lead)
        session.beginCreate(goal: "Synthetic goal")
        let origin = session.createOrigin
        #expect(session.finishCreate(from: origin) == nil)
        #expect(session.selection == .lead)
        #expect(session.createStore == nil)
    }

    @Test("An open request for a feature the list does not show yet opens it on its machine")
    func openRequestForUnlistedFeature() async throws {
        let (session, store) = try await loadedDemoSession()
        let listed = try #require(session.conversations.first?.id)
        session.applyOpenRequest(listed)
        #expect(session.selection == .feature(listed))

        let unlisted = FirstMateFleetFeatureID(machineID: FirstMateChatWindowSession.demoMachineID, featureID: "demo-just-created")
        session.applyOpenRequest(unlisted)
        #expect(session.selection == .feature(unlisted))
        // Until the store refreshes, the request may still load.
        #expect(!session.selectionIsUnresolvable)
        // The store's refresh does not know it and selects another feature,
        // so the window falls back to My First Mate instead of loading forever.
        await store.refresh()
        #expect(session.selectionIsUnresolvable)

        let elsewhere = FirstMateFleetFeatureID(machineID: "synthetic-elsewhere", featureID: "demo-receipts")
        session.applyOpenRequest(elsewhere)
        #expect(session.selection == .lead)
    }

    @Test("A chat that is not listed but holds a snapshot stays resolvable")
    func heldSnapshotStays() async throws {
        let (session, store) = try await loadedDemoSession()
        let id = try #require(session.conversations.first?.id)
        #expect(!FirstMateChatWindowSession.selectionIsUnresolvable(id, conversations: session.conversations, store: store))
        let unlisted = session.conversations.filter { $0.id != id }
        #expect(!FirstMateChatWindowSession.selectionIsUnresolvable(id, conversations: unlisted, store: store))
        #expect(FirstMateChatWindowSession.selectionIsUnresolvable(id, conversations: unlisted, store: nil))
        #expect(!FirstMateChatWindowSession.selectionIsUnresolvable(id, conversations: [], store: nil))
    }
}
