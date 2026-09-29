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
        session: FirstMateChatWindowSession
    ) async throws {
        let defaults = try #require(UserDefaults(suiteName: "FirstMateChatRender.Layout.\(UUID().uuidString)"))
        defaults.set(sidebarWidth, forKey: FirstMateChatPreferences.sidebarWidthKey)
        let result = try await HerdrRenderHarness.renderWindow(name, size: size) {
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

    @Test("At 1000 pt the inspector floats over chat without changing its column width")
    func overlay() async throws {
        let session = try await session(selecting: .feature(Self.receipts), inspectorPreference: true)
        try await render("fmchat-chrome-overlay-1000.png", size: CGSize(width: 1000, height: 800), session: session)
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
            sidebarWidth: Double(FirstMateChatWindowLayout.compactBelow),
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
    private func layout(
        _ width: CGFloat,
        _ inspectorPreference: Bool? = nil,
        sidebarWidth: CGFloat = CGFloat(FirstMateChatPreferences.defaultSidebarWidth)
    ) -> FirstMateChatWindowLayout {
        FirstMateChatWindowLayout.resolve(
            width: width,
            preferredSidebarWidth: sidebarWidth,
            inspectorPreference: inspectorPreference
        )
    }

    @Test("Every visible inspector overlays chat, including at wide window sizes")
    func inspectorModes() {
        #expect(layout(1440).inspector == .overlay)
        #expect(layout(1280).inspector == .overlay)
        #expect(layout(1279).inspector == .hidden)
        #expect(layout(1200).inspector == .hidden)
        #expect(layout(1200, true).inspector == .overlay)
        #expect(layout(1000, true).inspector == .overlay)
        #expect(layout(700, true).inspector == .overlay)
        #expect(layout(1440, false).inspector == .hidden)
        #expect(layout(1000).inspector == .hidden)
    }

    @Test("The width opens or closes the inspector once; resizing afterwards keeps the choice")
    func inspectorSettlesOnce() {
        #expect(FirstMateChatWindowLayout.settledInspectorPreference(width: 1320, preference: nil) == true)
        #expect(FirstMateChatWindowLayout.settledInspectorPreference(width: 1200, preference: nil) == false)
        #expect(FirstMateChatWindowLayout.settledInspectorPreference(width: 0, preference: nil) == nil)
        // Settled open at 1320 pt, then dragged to 1200 pt: still open.
        let settled = FirstMateChatWindowLayout.settledInspectorPreference(width: 1320, preference: nil)
        #expect(FirstMateChatWindowLayout.settledInspectorPreference(width: 1200, preference: settled) == true)
        #expect(layout(1200, settled).inspector == .overlay)
        #expect(FirstMateChatWindowLayout.settledInspectorPreference(width: 1440, preference: false) == false)
    }

    @Test("The sidebar follows its dragged width and restores text at the compact threshold")
    func sidebarModes() {
        #expect(layout(700).sidebar == .full)
        #expect(layout(700).sidebarWidth == 320)
        #expect(layout(1000, sidebarWidth: 219).sidebar == .rail)
        #expect(layout(1000, sidebarWidth: 219).sidebarWidth == 219)
        #expect(layout(1000, sidebarWidth: 220).sidebar == .full)
        #expect(layout(1000, sidebarWidth: 480).sidebarWidth == 480)
        #expect(layout(1000, sidebarWidth: 999).sidebarWidth == 480)
        #expect(layout(1000, sidebarWidth: 1).sidebarWidth == 76)
        #expect(FirstMateRowTopLine.titleLineLimit == 2)
    }

    @Test("A narrow window constrains the sidebar without taking the chat below its minimum")
    func narrowWindowBounds() {
        let constrained = layout(680, sidebarWidth: 480)
        #expect(constrained.sidebarWidth == 320)
        #expect(680 - constrained.sidebarWidth == FirstMateChatWindowLayout.minimumChatWidth)
        #expect(layout(1000, sidebarWidth: 480).sidebarWidth == 480,
                "The persisted preference returns when the window widens")
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
