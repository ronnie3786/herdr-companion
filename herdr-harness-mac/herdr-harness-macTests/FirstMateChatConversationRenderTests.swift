import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// The chat window's conversation column on its own, over the window's dusk
/// and pane glass, with the chat demo's synthetic features: the blocked
/// Receipt export feature (skim, suggested replies, an agent's bubble, a file
/// card), My First Mate's briefing, the `@` picker, and a capsule's readout.
@Suite("First Mate chat conversation renders", .serialized)
@MainActor
struct FirstMateChatConversationRenderTests {
    static let size = CGSize(width: 900, height: 860)
    static let receipts = FirstMateFleetFeatureID(machineID: FirstMateChatWindowSession.demoMachineID, featureID: "demo-receipts")

    private func demoSession() async throws -> (FirstMateChatWindowSession, HerdrAppModel) {
        let model = ChatFixtures.model(demo: true)
        let session = FirstMateChatWindowSession(model: model, shell: ChatFixtures.shell())
        let store = try #require(session.store(for: FirstMateChatWindowSession.demoMachineID))
        await store.refresh()
        return (session, model)
    }

    private func column(_ session: FirstMateChatWindowSession, model: HerdrAppModel) -> some View {
        Self.dusk {
            ZStack(alignment: .top) {
                HerdrGlassBackground(level: HerdrTheme.Glass.pane)
                HerdrHazeBand()
                FirstMateChatConversationView(session: session, model: model, modelFavorites: ModelFavoritesStore())
            }
        }
        // The window root routes mention links; a local handler stands in.
        .environment(\.openURL, OpenURLAction { url in
            FirstMateMention.parse(url) == nil ? .systemAction : .handled
        })
    }

    /// The window's dusk behind glass, as the main window draws it.
    static func dusk(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            HerdrDuskBackdrop()
            content()
        }
        .environment(\.herdrGlassActive, true)
        .environment(\.herdrHazeActive, true)
    }

    @Test("Receipt export: skim, agent bubble, file card and suggested replies")
    func receipts() async throws {
        let (session, model) = try await demoSession()
        session.select(.feature(Self.receipts))
        let snapshot = try #require(session.selectedSnapshot)
        #expect(snapshot.messages.contains { $0.assignmentID != nil })

        let result = try await HerdrRenderHarness.render("fmchat-conversation-receipts.png", size: Self.size) {
            column(session, model: model)
        }
        result.expectSubstantial()
    }

    @Test("My First Mate: the summary with feature pills")
    func lead() async throws {
        let (session, model) = try await demoSession()
        session.select(.lead)
        let result = try await HerdrRenderHarness.render("fmchat-conversation-lead.png", size: Self.size) {
            column(session, model: model)
        }
        result.expectSubstantial()
    }

    @Test("The @ picker open over Receipt export")
    func picker() async throws {
        let (session, model) = try await demoSession()
        session.select(.feature(Self.receipts))
        // The picker follows the draft: a trailing "@" opens it.
        let store = try #require(session.selectedStore)
        store.draft = "@"
        let result = try await HerdrRenderHarness.render("fmchat-conversation-picker.png", size: Self.size) {
            column(session, model: model)
        }
        result.expectSubstantial()
    }

    @Test("A capsule's readout for Receipt export")
    func readout() async throws {
        let (session, _) = try await demoSession()
        let conversation = try #require(session.conversations.first { $0.id == Self.receipts })
        let result = try await HerdrRenderHarness.render("fmchat-conversation-readout.png", size: CGSize(width: 340, height: 220)) {
            Self.dusk {
                FirstMateCapsuleReadout(conversation: conversation, open: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        result.expectSubstantial()
    }
}
