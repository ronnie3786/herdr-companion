import CoreGraphics
import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("First Mate HUD rules")
@MainActor
struct FirstMateHudTests {
    /// A HUD item with a start time `start` seconds after a fixed instant.
    private func item(
        _ label: String,
        _ hud: FirstMateHudStatus,
        start: TimeInterval? = nil,
        step: Int? = nil,
        fraction: Double? = nil,
        unread: Bool = false,
        machine: String = "local"
    ) -> FirstMateHudItem {
        let conversation = FirstMateConversation(
            id: FirstMateFleetFeatureID(machineID: machine, featureID: label.lowercased()), machineID: machine, machineName: "\(machine) Mac",
            featureID: label.lowercased(), title: label, label: label, emoji: "🧪", hudStatus: hud, featureStatus: "running",
            stepIndex: step, stepFraction: fraction, now: nil, previewText: "", previewIsFromUser: false,
            isWorkingOnReply: false, activityAt: nil, latestFirstMateMessageID: unread ? "msg-\(label)" : nil,
            isUnread: unread, isArchived: false
        )
        return FirstMateHudItem(conversation: conversation, startedAt: start.map { Date(timeIntervalSince1970: 1_900_000_000 + $0) })
    }

    private func moving(_ count: Int) -> [FirstMateHudItem] {
        (0..<count).map { item("Moving \($0)", .working, start: Double($0), step: $0 % 6, fraction: 0.5) }
    }

    // MARK: Order

    @Test("Needs-you rows lead by urgency, ties and moving rows in start order")
    func order() {
        let items = [
            item("Idle", .idle, start: 0),
            item("Ready late", .ready, start: 9),
            item("Working", .working, start: 1),
            item("Turn", .turn, start: 5),
            item("Blocked", .blocked, start: 7),
            item("Ready early", .ready, start: 2),
            item("Unknown start", .working),
        ]
        #expect(FirstMateHudOrder.sorted(items).map(\.label) == [
            "Blocked", "Turn", "Ready early", "Ready late", "Idle", "Working", "Unknown start",
        ])
    }

    @Test("Percent is (step + fraction) / 6, complete is 100, unknown is nil")
    func percent() {
        #expect(FirstMateHudProgress.percent(status: .blocked, step: 3, fraction: 0.45) == 58)
        #expect(FirstMateHudProgress.percent(status: .working, step: 0, fraction: 0) == 0)
        #expect(FirstMateHudProgress.percent(status: .working, step: 5, fraction: 1) == 100)
        #expect(FirstMateHudProgress.percent(status: .done, step: nil, fraction: nil) == 100)
        #expect(FirstMateHudProgress.percent(status: .working, step: nil, fraction: 0.5) == nil)
        #expect(FirstMateHudProgress.segments(status: .working, step: 2, fraction: 0.5) == [1, 1, 0.5, 0, 0, 0])
        #expect(FirstMateHudProgress.segments(status: .idle, step: nil, fraction: nil) == [0, 0, 0, 0, 0, 0])
    }

    @Test("The roster drops archived, cancelled, and long-merged features")
    func roster() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let recent = HerdrTimestamp.string(from: now.addingTimeInterval(-60))
        let old = HerdrTimestamp.string(from: now.addingTimeInterval(-600))
        var cancelled = ChatFixtures.entry("cancelled", hud: .idle)
        cancelled.status = "cancelled"
        let host = ChatFixtures.host("alpha", entries: [
            ChatFixtures.entry("blocked", hud: .blocked),
            ChatFixtures.entry("archived", hud: .blocked, archived: true),
            ChatFixtures.entry("merged-now", hud: .done, activityAt: recent),
            ChatFixtures.entry("merged-long-ago", hud: .done, activityAt: old),
            cancelled,
            ChatFixtures.entry("working", hud: .working),
        ])
        let ids = FirstMateHudRoster.items(hosts: [host], readState: .init(), now: now).map(\.id.featureID)
        #expect(ids == ["blocked", "merged-now", "working"] || ids == ["blocked", "working", "merged-now"])
        #expect(Set(ids) == ["blocked", "merged-now", "working"])
    }

    // MARK: Overflow

    @Test("Six or fewer features all get an orb")
    func collapsedFits() {
        let layout = FirstMateHudOverflow.collapsed(moving(6))
        #expect(layout.orbs.count == 6)
        #expect(!layout.hasMore)
    }

    @Test("Past six, five orbs show and the sixth slot is +N")
    func collapsedOverflow() {
        let items = [item("Blocked", .blocked, start: 0)] + moving(9)
        let layout = FirstMateHudOverflow.collapsed(FirstMateHudOrder.sorted(items))
        #expect(layout.orbs.count == 5)
        #expect(layout.tucked.count == 5)
        #expect(layout.orbs.first?.label == "Blocked")
    }

    @Test("Needs-you features are never tucked, even past the cap")
    func collapsedNeedsYouNeverHidden() {
        let needsYou = (0..<7).map { item("Needs \($0)", .turn, start: Double($0)) }
        let layout = FirstMateHudOverflow.collapsed(FirstMateHudOrder.sorted(needsYou + moving(3)))
        #expect(layout.orbs.count == 7)
        #expect(layout.orbs.allSatisfy { $0.needsYou })
        #expect(layout.tucked.count == 3)
        #expect(!layout.tucked.contains { $0.needsYou })
    }

    @Test("Four moving rows show in full; more show three and a summary")
    func expandedSummary() {
        let four = FirstMateHudOverflow.expanded(moving(4), showAllMoving: false)
        #expect(four.moving.count == 4)
        #expect(four.summary == nil)

        let items = FirstMateHudOrder.sorted([item("Blocked", .blocked, start: 0)] + moving(8))
        let expanded = FirstMateHudOverflow.expanded(items, showAllMoving: false)
        #expect(expanded.needsYou.map(\.label) == ["Blocked"])
        #expect(expanded.moving.count == 3)
        #expect(!expanded.movingAreCompact)
        #expect(expanded.summary?.count == 5)
        #expect(expanded.summary?.isShowingAll == false)

        let all = FirstMateHudOverflow.expanded(items, showAllMoving: true)
        #expect(all.moving.count == 8)
        #expect(all.movingAreCompact)
        #expect(all.summary?.isShowingAll == true)
    }

    @Test("The summary averages the tucked features' known percent")
    func summaryAverage() {
        let summary = FirstMateHudOverflow.Summary(tucked: [
            item("A", .working, step: 0, fraction: 0),
            item("B", .working, step: 3, fraction: 0),
            item("C", .working),
        ], isShowingAll: false)
        #expect(summary.averagePercent == 25)
        #expect(summary.count == 3)
    }

    @Test("Fourteen features with everything showing fit 680 pt below the list top")
    func fourteenFit() {
        let items = FirstMateHudOrder.sorted((0..<4).map { item("Needs \($0)", .blocked, start: Double($0)) } + moving(10))
        let height = FirstMateHudGeometry.listContentHeight(FirstMateHudOverflow.expanded(items, showAllMoving: true))
        #expect(FirstMateHudGeometry.listTop + height + FirstMateHudGeometry.faceRadius <= 680)
    }

    // MARK: Badge

    @Test("The face counts needs-you features, colored by the most urgent")
    func badge() {
        #expect(FirstMateHudBadge.value(moving(3)) == nil)
        let value = FirstMateHudBadge.value([item("Ready", .ready), item("Turn", .turn), item("Working", .working)])
        #expect(value == .init(count: 2, status: .turn))
        #expect(FirstMateHudBadge.value([item("Ready", .ready), item("Blocked", .blocked)])?.status == .blocked)
    }

    // MARK: Routing

    @Test("A question about the fleet is answered from the summary")
    func fleetQuestion() {
        let items = [
            item("Receipt export", .blocked, start: 0, step: 3),
            item("Push alert settings", .turn, start: 1),
            item("Offline sync", .working, start: 2, step: 1),
        ]
        let route = FirstMateHudRouting.route("What needs me?", items: items)
        #expect(route == .answer("Two need you: Receipt export is blocked in QA, and Push alert settings has a question."))
        #expect(FirstMateHudRouting.route("whats up", items: items) == route)
        #expect(FirstMateHudRouting.route("What\u{2019}s up", items: items) == route)
    }

    @Test("Words that name a feature go to it, longest name first")
    func namedFeature() {
        let items = [item("Review", .working, start: 0), item("Review search results", .ready, start: 1)]
        let route = FirstMateHudRouting.route("Tell review search results to ship it", items: items)
        #expect(route == .send(items[1].id, label: "Review search results", text: "Tell review search results to ship it"))
        #expect(FirstMateHudRouting.route("review: go ahead", items: items) == .send(items[0].id, label: "Review", text: "review: go ahead"))
    }

    @Test("Nothing named and no question says so plainly")
    func noMatch() {
        let items = [item("Offline sync", .working)]
        #expect(FirstMateHudRouting.route("ship it", items: items) == .answer(FirstMateHudRouting.noMatchAnswer))
        #expect(FirstMateHudRouting.route("status", items: []) == .answer("Nothing needs you, and no features are running."))
        // Two features with one name match neither.
        let twins = [item("Sync", .working, machine: "alpha"), item("Sync", .working, machine: "beta")]
        #expect(FirstMateHudRouting.namedItem(in: "sync now", items: twins) == nil)
    }

    @Test("A calm fleet reads as nothing needing you")
    func calmSummary() {
        #expect(FirstMateHudRouting.summary(moving(3)) == "Nothing needs you. Three features are moving.")
        #expect(FirstMateHudRouting.summary([item("Receipt export", .ready)]) == "One needs you: Receipt export is ready for review.")
    }

    @Test("Each orb and row says what it is and what it does")
    func speech() {
        let blocked = item("Receipt export", .blocked, step: 3, fraction: 0.45, unread: true)
        #expect(FirstMateHudSpeech.accessibilityLabel(blocked)
                == "Receipt export: blocked in QA, 58 percent. Unread message. Opens the session.")
        #expect(FirstMateHudSpeech.accessibilityLabel(blocked, opensMessage: true)
                == "Receipt export: blocked in QA, 58 percent. Unread message. Opens the message.")
        #expect(FirstMateHudSpeech.accessibilityLabel(item("Theme", .idle))
                == "Theme: ready to plan. Opens the session.")
    }

    @Test("Moving rows name their step; needs-you rows their status")
    func stateWords() {
        #expect(item("A", .working, step: 1).stateWord == "Building")
        #expect(item("B", .blocked, step: 3).stateWord == "Blocked")
        #expect(item("C", .idle, step: 0).stateWord == "Plan")
        #expect(item("D", .done).stateWord == "Merged")
        #expect(item("E", .working).stateWord == "Working")
    }

    // MARK: Geometry

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("The list opens trailing with room, leading near the right edge")
    func listSide() {
        let roomy = FirstMateHudGeometry.layout(.init(faceCenter: CGPoint(x: 900, y: 800), visibleFrame: screen,
                                                      column: .expanded(contentHeight: 200), card: nil))
        #expect(roomy.listSide == .trailing)
        let edge = FirstMateHudGeometry.layout(.init(faceCenter: CGPoint(x: 1380, y: 800), visibleFrame: screen,
                                                     column: .expanded(contentHeight: 200), card: nil))
        #expect(edge.listSide == .leading)
        #expect(edge.panelFrame.maxX <= screen.maxX + FirstMateHudGeometry.margin)
    }

    @Test("The face keeps its place on screen whatever opens")
    func faceStays() {
        let face = CGPoint(x: 700, y: 700)
        for column in [FirstMateHudGeometry.Column.collapsed(orbCount: 6), .expanded(contentHeight: 300)] {
            for card in [nil, FirstMateHudGeometry.Card(size: CGSize(width: 352, height: 420), anchorY: -39)] {
                let output = FirstMateHudGeometry.layout(.init(faceCenter: face, visibleFrame: screen, column: column, card: card))
                #expect(output.panelFrame.minX + output.faceCenter.x == face.x)
                #expect(output.panelFrame.maxY - output.faceCenter.y == face.y)
            }
        }
    }

    @Test("A card near the bottom slides up to stay on screen")
    func cardClamps() throws {
        let output = FirstMateHudGeometry.layout(.init(
            faceCenter: CGPoint(x: 700, y: 200), visibleFrame: screen, column: .collapsed(orbCount: 3),
            card: .init(size: CGSize(width: 352, height: 420), anchorY: -39)))
        let card = try #require(output.cardFrame)
        let screenBottom = output.panelFrame.maxY - card.maxY
        #expect(screenBottom >= screen.minY + FirstMateHudGeometry.margin - 0.5)
        #expect(output.cardSide == .trailing)
    }

    @Test("A face dragged off screen comes back whole")
    func clampFace() {
        let clamped = FirstMateHudGeometry.clampFace(CGPoint(x: -40, y: 2000), visibleFrame: screen)
        #expect(clamped.x == FirstMateHudGeometry.faceRadius + FirstMateHudGeometry.margin)
        #expect(clamped.y == screen.maxY - FirstMateHudGeometry.faceRadius - FirstMateHudGeometry.margin)
        #expect(FirstMateHudGeometry.clampFace(CGPoint(x: 1000, y: 800), visibleFrame: screen) == CGPoint(x: 1000, y: 800))
    }

    @Test("A long list scrolls instead of leaving the screen")
    func listViewport() {
        let output = FirstMateHudGeometry.layout(.init(faceCenter: CGPoint(x: 700, y: 400), visibleFrame: screen,
                                                       column: .expanded(contentHeight: 900), card: nil))
        #expect(output.listViewportHeight < 900)
        #expect(output.panelFrame.minY >= screen.minY)
    }

    // MARK: Plumbing

    @Test("While the HUD shows, the fleet keeps its active 10 s poll in the background")
    func pollingInterval() {
        let active = Duration.seconds(10), background = Duration.seconds(30)
        let hud = FirstMateHudController.hudPollingInterval
        #expect(FirstMateFleetDriver.pollingInterval(isActive: false, hud: nil, active: active, background: background) == .seconds(30))
        #expect(FirstMateFleetDriver.pollingInterval(isActive: true, hud: nil, active: active, background: background) == .seconds(10))
        #expect(FirstMateFleetDriver.pollingInterval(isActive: false, hud: hud, active: active, background: background) == .seconds(10))
        #expect(FirstMateFleetDriver.pollingInterval(isActive: true, hud: .seconds(5), active: active, background: background) == .seconds(5))
    }

    @Test("The demo fleet comes in 6, 10, and 14 features")
    func demoSizes() {
        let now = Date()
        let demo = FirstMateChatDemoSource(now: now)
        for count in [6, 10, 14] {
            let host = FirstMateHudDemo.host(base: demo.host, count: count, now: now)
            #expect(FirstMateHudRoster.items(hosts: [host], readState: .init(), now: now).count == count)
        }
    }

    @Test("Labels stop at 24 characters; emoji keep whole graphemes")
    func editing() {
        #expect(FirstMateHudEditing.firstEmoji(in: "abc 🧾 x") == "🧾")
        #expect(FirstMateHudEditing.firstEmoji(in: "👍🏽") == "👍🏽")
        #expect(FirstMateHudEditing.firstEmoji(in: "no emoji") == nil)
        #expect(FirstMateHudPreferences.demoCount(arguments: ["app", "-HerdrFirstMateHudDemoCount", "14"]) == 14)
        #expect(FirstMateHudPreferences.demoCount(arguments: ["app"]) == nil)
    }
}
