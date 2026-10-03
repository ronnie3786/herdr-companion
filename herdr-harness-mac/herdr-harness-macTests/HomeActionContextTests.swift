import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Home frozen action context")
struct HomeActionContextTests {
    @Test("Production evidence receives local Later and Dismiss controls without changing counts or duplicating fixture actions")
    func localActions() {
        var source = HomeSnapshot()
        source.focusCount = 3
        source.focus = [
            .init(id: "attention", title: "Needs input", reason: "Waiting", body: "A question", route: .chats),
            .init(id: "idea", title: "Try this", reason: "Idea", body: "An idea", route: .firstMateLead, isIdea: true)
        ]
        source.radar = [.init(id: "watcher", body: "A watcher update")]
        let result = HomeActionPresentation.snapshot(source, snoozedCount: 1)
        #expect(result.focus[0].actions.contains { $0.command == .snooze("attention") })
        #expect(!result.focus[1].actions.contains { $0.command == .snooze("idea") })
        #expect(result.radar[0].actions.contains { $0.command == .dismiss("watcher") })
        #expect(result.focusCount == 3 && !result.canShowAllClear)
        #expect(result.notices.contains { $0.contains("snoozed on this Mac") })
        let repeated = HomeActionPresentation.snapshot(result, snoozedCount: 0)
        #expect(repeated.focus[0].actions.count == 1 && repeated.radar[0].actions.count == 1)
        #expect(source.focus[0].actions.isEmpty && source.radar[0].actions.isEmpty)
    }

    @Test("An item quote keeps exact owner evidence and observation time across refreshes")
    func freezesExactOwnerEvidence() throws {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let alpha = HomeRoute.firstMate(machineID: "alpha", featureID: "same-feature")
        let beta = HomeRoute.firstMate(machineID: "beta", featureID: "same-feature")
        var snapshot = HomeSnapshot()
        snapshot.updatedAt = observedAt
        snapshot.focus = [
            .init(id: "alpha", title: "Alpha task", reason: "Waiting for direction", body: "Choose the next step.", route: alpha),
            .init(id: "beta", title: "Beta task", reason: "Blocked", body: "A different issue.", route: beta)
        ]
        let context = try #require(HomeActionContext.make(route: alpha, snapshot: snapshot))
        snapshot.focus[0].body = "A newer response."
        snapshot.updatedAt = observedAt.addingTimeInterval(60)
        #expect(context.title == "Alpha task")
        #expect(context.summary == "Waiting for direction\n\nChoose the next step.")
        #expect(context.observedAt == observedAt)
        #expect(!context.summary.contains("different issue"))
        #expect(!context.quote.text.contains("newer response"))
    }

    @Test("A missing exact route cannot become an unrelated overview quote")
    func missingRoute() {
        var snapshot = HomeSnapshot()
        snapshot.statusLine = "Other work is moving."
        #expect(HomeActionContext.make(route: .chat(paneID: "missing::pane"), snapshot: snapshot) == nil)
        #expect(HomeActionContext.make(route: nil, snapshot: snapshot)?.title == "Home overview")
    }

    @Test("Last known chat context says it is stale and preserves the displayed location")
    func staleChat() throws {
        let route = HomeRoute.chat(paneID: "alpha::pane")
        var snapshot = HomeSnapshot()
        snapshot.chats = [.init(id: "chat", title: "A session", reason: "Waiting", location: "Alpha · Sample repo",
                                quote: "May I continue?", route: route, isStale: true)]
        let context = try #require(HomeActionContext.make(route: route, snapshot: snapshot))
        #expect(context.summary.contains("Alpha · Sample repo"))
        #expect(context.summary.contains("May I continue?"))
        #expect(context.summary.hasSuffix("Last known state."))
    }
}
