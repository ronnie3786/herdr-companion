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

    private func render(_ name: String, size: CGSize = Self.wide, session: FirstMateChatWindowSession) async throws {
        let result = try await HerdrRenderHarness.renderWindow(name, size: size) {
            ZStack {
                HerdrDuskBackdrop()
                FirstMateChatWindowRoot(session: session, modelFavorites: ModelFavoritesStore())
            }
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

    @Test("At 1000 pt the inspector floats over the chat")
    func overlay() async throws {
        let session = try await session(selecting: .feature(Self.receipts), inspectorPreference: true)
        try await render("fmchat-chrome-overlay-1000.png", size: CGSize(width: 1000, height: 800), session: session)
    }

    @Test("At 700 pt the sidebar is a rail")
    func rail() async throws {
        let session = try await session(selecting: .feature(Self.receipts))
        try await render("fmchat-chrome-rail-700.png", size: CGSize(width: 700, height: 800), session: session)
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
    private func layout(_ width: CGFloat, _ preference: Bool? = nil) -> FirstMateChatWindowLayout {
        FirstMateChatWindowLayout.resolve(width: width, inspectorPreference: preference)
    }

    @Test("The inspector opens by itself at 1280 pt and wider, inline from 1140 pt, floating below")
    func inspectorModes() {
        #expect(layout(1440).inspector == .inline)
        #expect(layout(1280).inspector == .inline)
        #expect(layout(1279).inspector == .hidden)
        #expect(layout(1200).inspector == .hidden)
        #expect(layout(1200, true).inspector == .inline)
        #expect(layout(1140, true).inspector == .inline)
        #expect(layout(1139, true).inspector == .overlay)
        #expect(layout(1000, true).inspector == .overlay)
        #expect(layout(700, true).inspector == .overlay)
        #expect(layout(1440, false).inspector == .hidden)
        #expect(layout(1000).inspector == .hidden)
    }

    @Test("The sidebar becomes a 76 pt rail below 760 pt")
    func sidebarModes() {
        #expect(layout(760).sidebar == .full)
        #expect(layout(760).sidebarWidth == 320)
        #expect(layout(759).sidebar == .rail)
        #expect(layout(700).sidebarWidth == 76)
        #expect(layout(1440).sidebar == .full)
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
