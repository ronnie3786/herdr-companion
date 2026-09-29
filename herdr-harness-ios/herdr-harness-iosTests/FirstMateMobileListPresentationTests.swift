import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Phone conversation list rules")
@MainActor
struct FirstMateMobileListPresentationTests {
    private func row(_ id: String, machine: String = "alpha", status: FirstMateHudStatus = .blocked,
                     activity: Double = 1, archived: Bool = false, userName: String? = nil) -> FirstMateConversation {
        .init(id: .init(machineID: machine, featureID: id), machineID: machine, machineName: machine == "alpha" ? "Desktop" : "Laptop",
              featureID: id, title: "Feature \(id)", label: userName ?? "Default \(id)", isUserNamed: userName != nil,
              emoji: "🧾", isUserEmoji: true, hudStatus: status, featureStatus: status == .done ? "completed" : "blocked",
              stepIndex: nil, stepFraction: nil, now: nil, previewText: "Review the retained evidence", previewIsFromUser: false,
              isWorkingOnReply: false, activityAt: Date(timeIntervalSince1970: activity), latestFirstMateMessageID: "reply", isUnread: true, isArchived: archived)
    }

    @Test("Flat recency and composite dedup exclude archives and lead identities")
    func rowsAndIdentity() {
        let alpha = row("same", activity: 2), beta = row("same", machine: "beta", activity: 4)
        let lead = row("lead", activity: 9)
        let value = FirstMateMobileListPresentation(conversations: [alpha, row("archived", activity: 6, archived: true), beta, alpha, lead],
            scope: .all, query: "", leadIDs: [lead.id])
        #expect(value.rows.map(\.id) == [beta.id, alpha.id])
        #expect(value.showsLead)
        #expect(!value.rows.contains { $0.featureID == "lead" })
    }

    @Test("Pins use urgency then activity, with six features plus a separate overflow")
    func pinsAndOverflow() {
        let rows = [row("ready-new", status: .ready, activity: 100), row("blocked-old", activity: 1),
                    row("blocked-new", activity: 2), row("turn-old", status: .turn, activity: 3),
                    row("turn-new", status: .turn, activity: 4), row("ready-old", status: .ready, activity: 5),
                    row("ready-mid", status: .ready, activity: 6), row("working", status: .working, activity: 200),
                    row("done", status: .done, activity: 300)]
        let value = FirstMateMobileListPresentation(conversations: rows, scope: .all, query: "")
        #expect(value.pinned.map(\.featureID) == ["blocked-new", "blocked-old", "turn-new", "turn-old", "ready-new", "ready-mid"])
        #expect(value.overflow.map(\.featureID) == ["ready-old"])
        #expect(value.pinned.count == 6 && value.showsLead)
        #expect(value.rows.first?.featureID == "done", "Pinned urgency never changes the flat list's recency order")
    }

    @Test("Search retains title, custom label, preview, machine, goal and ticket semantics")
    func searchAndScope() {
        let alpha = row("alpha-feature", userName: "Custom name"), beta = row("beta-feature", machine: "beta")
        var feature = ChatFixtures.feature(alpha.featureID)
        feature.goal = "Ship a detailed report"
        feature.workItemID = "SYN-314"
        let features = [FirstMateMobileListPresentation.target(alpha): feature]
        for query in ["FEATURE ALPHA", "custom", "retained", "desktop", "detailed", "syn-314"] {
            let value = FirstMateMobileListPresentation(conversations: [alpha, beta], scope: .machine("alpha"), query: query, features: features)
            #expect(value.rows.map(\.id) == [alpha.id])
            #expect(!value.showsLead)
        }
        let lead = FirstMateMobileListPresentation(conversations: [alpha], scope: .all, query: "my first")
        #expect(lead.showsLead && lead.rows.isEmpty && lead.emptyMessage == nil)
        let absent = FirstMateMobileListPresentation(conversations: [], scope: .all, query: "missing")
        #expect(!absent.showsLead && absent.emptyMessage == "No conversations match “missing”.")
        #expect(FirstMateMobileListPresentation(conversations: [], scope: .all, query: "").emptyMessage?.contains("No features yet") == true)
        #expect(alpha.name == "Custom name", "Render the shared presentation name, never raw title-only")
    }

    @Test("Working preview and reason dots follow the projected conversation")
    func previewAndDot() {
        let base = row("feature")
        let working = FirstMateReplyProgress.presenting(base, workingOnReply: true)
        #expect(base.showsDot && !working.showsDot)
        #expect(FirstMateMobileListPresentation.preview(working) == "typing…")
        #expect(FirstMateMobileListPresentation.preview(base) == base.previewText)
        #expect(working.featureStatus == base.featureStatus)
        let done = row("done", status: .done)
        #expect(FirstMateReplyProgress.presenting(done, workingOnReply: true) == done)
    }

    @Test("A failed send clears only local progress without needing a fleet-cache invalidation")
    func failedProgressIsNotCached() async throws {
        let feature = ChatFixtures.feature("feature", status: "blocked")
        let client = SyntheticChatFleetClient(features: [feature], fleet: [ChatFixtures.entry("feature", hud: .blocked, latestFirstMate: "m1")])
        client.snapshots = [feature.id: FirstMateSnapshot(feature: feature, messages: [
            .init(id: "m1", featureID: feature.id, role: "assistant", text: "Needs you", status: "delivered", createdAt: feature.updatedAt),
        ])]
        client.beforeSend = { throw APIError.server(status: 409, message: "Synthetic rejection") }
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "FailedListProgress.\(UUID())")!)
        let machine = ChatFixtures.machine("alpha")
        fleet.activate(sources: [.init(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: "synthetic"), client: client)], connectionGeneration: 1)
        await fleet.refreshAll()
        let store = try #require(fleet.store(forMachineID: "alpha"))
        let revision = fleet.chat.index.contentRevision
        let handle = try #require(store.beginOutgoingMessage("Continue", expectedContext: store.operationContext))
        #expect(fleet.badgeCount == 0 && fleet.conversations.first?.isWorkingOnReply == true)
        _ = await store.completeOutgoingMessage(handle)
        #expect(fleet.chat.index.contentRevision == revision)
        #expect(fleet.badgeCount == 1 && fleet.conversations.first?.isWorkingOnReply == false)
        #expect(FirstMateMobileListPresentation(conversations: fleet.conversations, scope: .all, query: "").pinned.count == 1)
    }

    @Test("Local pending state bypasses the fleet cache for list, pins, preview and global badge")
    func liveProgressProjection() async throws {
        let feature = ChatFixtures.feature("feature", status: "blocked")
        let snapshot = FirstMateSnapshot(feature: feature, messages: [
            .init(id: "m1", featureID: feature.id, role: "assistant", text: "Needs your direction", status: "delivered", createdAt: feature.updatedAt),
        ])
        let client = SyntheticChatFleetClient(features: [feature], fleet: [ChatFixtures.entry("feature", hud: .blocked, latestFirstMate: "m1")])
        client.snapshots = [feature.id: snapshot]
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "ListProgress.\(UUID())")!)
        let machine = ChatFixtures.machine("alpha")
        fleet.activate(sources: [.init(machine: machine, configuration: ServerConfiguration(urlString: machine.urlString, token: "synthetic"), client: client)], connectionGeneration: 1)
        await fleet.refreshAll()
        let store = try #require(fleet.store(forMachineID: "alpha"))
        #expect(fleet.badgeCount == 1)
        let handle = try #require(store.beginOutgoingMessage("Continue", expectedContext: store.operationContext))
        #expect(fleet.conversations.first?.isWorkingOnReply == true && fleet.badgeCount == 0)
        let pendingRow = try #require(fleet.conversations.first)
        #expect(FirstMateMobileListPresentation.preview(pendingRow) == "typing…")
        #expect(FirstMateMobileListPresentation(conversations: fleet.conversations, scope: .all, query: "").pinned.isEmpty)
        _ = await store.completeOutgoingMessage(handle)
        #expect(fleet.conversations.first?.isWorkingOnReply == true, "Accepted receipt bridges until fresh activity, not just transport completion")
        fleet.selectScope(.machine("absent")); fleet.search = "not found"
        #expect(fleet.badgeCount == 0)
        client.fleet = .success([ChatFixtures.entry("feature", hud: .blocked, latestFirstMate: "m2")])
        await fleet.refreshChatIndex()
        #expect(fleet.badgeCount == 1 && fleet.conversations.first?.isWorkingOnReply == false)
        #expect(fleet.conversations.first?.featureStatus == "blocked")
    }
}
