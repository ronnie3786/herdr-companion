import AppKit
import SwiftUI
import Testing
@testable import herdr_harness_mac

/// The chat window's conversation column on its own, over the window's dusk
/// and pane glass, with the chat demo's synthetic features: the blocked
/// Receipt export feature (skim, suggested replies, an agent's bubble, a file
/// card), My First Mate as the lead's conversation, the shared composer with a
/// draft, and a capsule's readout.
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

    @Test("My First Mate: the lead's conversation, a skimmed answer, and the shared composer")
    func lead() async throws {
        let (session, model) = try await demoSession()
        session.select(.lead)
        #expect(session.leadMachineID == FirstMateChatWindowSession.demoMachineID)
        let store = try #require(session.leadStore)
        #expect(await store.openLead())
        #expect(store.selectedFeatureID == store.leadFeatureID)
        #expect(session.selectedStore === store)
        let result = try await HerdrRenderHarness.render("fmchat-conversation-lead.png", size: Self.size) {
            column(session, model: model)
        }
        result.expectSubstantial()
    }

    @Test("Receipt export with a draft in the shared composer")
    func composerDraft() async throws {
        let (session, model) = try await demoSession()
        session.select(.feature(Self.receipts))
        let store = try #require(session.selectedStore)
        store.draft = "Ship iPhone-only and file the iPad bug."
        let result = try await HerdrRenderHarness.render("fmchat-conversation-composer.png", size: Self.size) {
            column(session, model: model)
        }
        result.expectSubstantial()
    }

    @Test("An empty lead mounts the outgoing bubble before its working row")
    func emptyLeadPending() async throws {
        let (session, model) = try await demoSession()
        session.select(.lead)
        let store = try #require(session.leadStore)
        #expect(await store.openLead())
        var snapshot = try #require(store.leadSnapshot)
        snapshot.messages = []
        store.receive(snapshot)
        let handle = try #require(store.beginOutgoingMessage("Synthetic lead direction", expectedContext: store.operationContext))
        let current = try #require(store.leadSnapshot)
        let messages = FirstMateTranscriptLayout.orderedMessages(store: store, snapshot: current)
        let rows = FirstMateTranscriptLayout.rows(for: messages, typing: true, now: .now, calendar: .current)
        #expect(messages.map(\.id) == [handle.messageID])
        #expect(rows.last?.speaker == .user)
        #expect(FirstMateTranscriptLayout.typingStartsGroup(rows))
        #expect(FirstMateTranscriptLayout.isAwaitingReply(store: store, snapshot: current))
        let result = try await HerdrRenderHarness.render("fmchat-empty-lead-sending.png", size: Self.size) {
            column(session, model: model)
        }
        result.expectSubstantial()
    }

    @Test("Main First Mate screen puts the pending user row before its working feedback")
    func mainPending() async throws {
        let (session, model) = try await demoSession()
        session.select(.feature(Self.receipts))
        let store = try #require(session.selectedStore)
        let snapshot = try #require(session.selectedSnapshot)
        let handle = try #require(store.beginOutgoingMessage("Synthetic pending direction", expectedContext: store.operationContext))
        let messages = FirstMateTranscriptLayout.orderedMessages(store: store, snapshot: snapshot)
        #expect(messages.last?.id == handle.messageID)
        #expect(FirstMateTranscriptLayout.isAwaitingReply(store: store, snapshot: snapshot))
        let result = try await HerdrRenderHarness.render("fmchat-main-sending.png", size: Self.size) {
            FirstMateChatView(store: store, model: model, snapshot: snapshot,
                              canControl: true, modelFavorites: ModelFavoritesStore())
        }
        result.expectSubstantial()
    }

    @Test("Rejected send draws the red textual error, not only a warning banner")
    func failedSendRed() async throws {
        let client = DeferredClient()
        let store = FirstMateStore()
        store.configure(client: client, demo: false)
        await store.refresh()
        _ = store.acquireControlLease(available: true)
        let context = store.operationContext
        let snapshot = try #require(store.snapshot(for: context))
        let handle = try #require(store.beginOutgoingMessage("Synthetic rejection", expectedContext: context))
        let sending = Task { await store.completeOutgoingMessage(handle) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while await client.requests.isEmpty {
            guard clock.now < deadline else { throw APIError.invalidResponse }
            try await Task.sleep(for: .milliseconds(2))
        }
        await client.resolve(.failure(APIError.server(status: 401, message: "Synthetic rejected request")))
        #expect((await sending.value)?.isFailure == true)
        #expect(!FirstMateTranscriptLayout.isAwaitingReply(store: store, snapshot: snapshot))
        #expect(store.sendFailure(for: snapshot.feature.id)?.failureMessage != nil)
        let result = try await HerdrRenderHarness.render("fmchat-send-error.png", size: CGSize(width: 700, height: 110)) {
            FirstMateSendErrorView(store: store, featureID: snapshot.feature.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HerdrTheme.ink)
        }
        result.expectSubstantial(minimumBytes: 900)
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: result.url)))
        let alert = HerdrTheme.resolved(HerdrTheme.alert)
        var alertPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(color.redComponent - alert.redComponent) < 0.14,
                   abs(color.greenComponent - alert.greenComponent) < 0.14,
                   abs(color.blueComponent - alert.blueComponent) < 0.14 { alertPixels += 1 }
            }
        }
        #expect(alertPixels > 25)
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
