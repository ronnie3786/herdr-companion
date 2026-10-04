import Foundation
import Observation
import Testing
@testable import herdr_harness_mac

@Suite("Home local presentation")
@MainActor
struct HomeStoreTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "HomeStoreTests.\(UUID().uuidString)")!
    }

    private func item(_ id: String, fingerprint: String = "question-1", priority: Int = 50) -> HomeFocusItem {
        HomeFocusItem(id: id, title: id, reason: "Your call", body: HomeText("Question for \(id)"),
                      route: .firstMate(machineID: "garden", featureID: id), priority: priority, fingerprint: fingerprint)
    }

    private func source(_ items: [HomeFocusItem]) -> HomeSnapshot {
        var value = HomeSnapshot()
        value.focus = items
        value.focusCount = items.count
        value.reviewCount = 3
        value.waitingChatCount = 2
        return value
    }

    @Test("Skip advances through the priority order and unrelated refresh preserves the selected card")
    func skipAndRefresh() {
        let store = HomeStore(defaults: defaults(), now: { start })
        let snapshot = source([item("A"), item("B"), item("C")])
        store.receive(snapshot)
        #expect(store.selectedFocusID == "A")
        store.skip()
        #expect(store.selectedFocusID == "B")
        #expect(store.snapshot.focus.map(\.id) == ["A", "B", "C"])
        store.receive(snapshot)
        #expect(store.selectedFocusID == "B")
        #expect(store.snapshot.focusCount == 3)
        store.skip()
        store.skip()
        #expect(store.selectedFocusID == "A", "Skipping past the last card comes back around")
    }

    @Test("Work that arrives later takes the front until the person chooses a card")
    func laterPriorityWork() {
        let store = HomeStore(defaults: defaults(), now: { start })
        store.receive(source([item("ready-review", priority: 40)]))
        store.receive(source([item("blocked", priority: 10), item("ready-review", priority: 40)]))
        #expect(store.snapshot.focus.map(\.id) == ["blocked", "ready-review"])
        #expect(store.selectedFocusID == "blocked")
        store.skip()
        store.receive(source([item("outage", priority: 0), item("blocked", priority: 10), item("ready-review", priority: 40)]))
        #expect(store.snapshot.focus.map(\.id) == ["outage", "blocked", "ready-review"])
        #expect(store.selectedFocusID == "ready-review", "A chosen card stays in front while new work joins in order")
    }

    @Test("Undo returns a snoozed card to its priority place and selects it")
    func undoKeepsPriorityPlace() {
        let store = HomeStore(defaults: defaults(), now: { start })
        store.receive(source([item("A", priority: 10), item("B", priority: 20), item("C", priority: 30)]))
        store.snooze("A")
        #expect(store.selectedFocusID == "B")
        store.undoLastSnooze()
        #expect(store.snapshot.focus.map(\.id) == ["A", "B", "C"])
        #expect(store.selectedFocusID == "A")
    }

    @Test("A status dismisses only itself, and an expired snooze withdraws its Undo")
    func statusLifetime() {
        let store = HomeStore(defaults: defaults(), now: { start })
        let snapshot = source([item("A"), item("B")])
        store.receive(snapshot)
        store.snooze("A")
        let snoozed = store.statusRevision
        #expect(store.canUndoSnooze)
        store.showStatus("That item is no longer on Home.")
        #expect(!store.canUndoSnooze, "Undo belongs to the status that offered it")
        store.dismissStatus(revision: snoozed)
        #expect(store.status == "That item is no longer on Home.")
        store.dismissStatus(revision: store.statusRevision)
        #expect(store.status == nil)
        store.snooze("B")
        #expect(store.canUndoSnooze)
        store.receive(snapshot, now: start.addingTimeInterval(7_200))
        #expect(store.status == nil)
        #expect(!store.canUndoSnooze)
        #expect(store.snapshot.focus.map(\.id) == ["A", "B"])
    }

    @Test("An identical refresh publishes nothing")
    func identicalRefreshIsSilent() {
        let store = HomeStore(defaults: defaults(), now: { start })
        let snapshot = source([item("A"), item("B")])
        store.receive(snapshot)
        store.skip()
        let changed = ChangeFlag()
        withObservationTracking {
            _ = store.snapshot
            _ = store.selectedFocusID
        } onChange: {
            changed.set()
        }
        store.receive(snapshot)
        #expect(!changed.value)
    }

    @Test("Snooze keeps global counts, expires, and new evidence reappears immediately")
    func snoozeEvidenceAndExpiry() {
        let store = HomeStore(defaults: defaults(), now: { start })
        store.receive(source([item("A"), item("B")]))
        store.snooze("A")
        #expect(store.snapshot.focus.map(\.id) == ["B"])
        #expect(store.snapshot.focusCount == 2)
        #expect(store.canUndoSnooze)
        store.receive(source([item("A", fingerprint: "question-2"), item("B")]))
        #expect(store.snapshot.focus.contains { $0.id == "A" })
        store.snooze("A")
        store.receive(source([item("A", fingerprint: "question-2"), item("B")]), now: start.addingTimeInterval(3_600))
        #expect(store.snapshot.focus.contains { $0.id == "A" })
        #expect(!store.canUndoSnooze)
    }

    @Test("Undo and evidence-scoped radar dismissals persist without changing server data")
    func localPreferences() {
        let preferences = defaults()
        let store = HomeStore(defaults: preferences, now: { start })
        var snapshot = source([item("A")])
        snapshot.radar = [.init(id: "watcher-A", body: "A failed run", fingerprint: "run-1")]
        store.receive(snapshot)
        store.snooze("A")
        store.dismissRadar("watcher-A")
        let reloaded = HomeStore(defaults: preferences, now: { start })
        reloaded.receive(snapshot)
        #expect(reloaded.snapshot.focus.isEmpty)
        #expect(reloaded.snapshot.radar.isEmpty)
        #expect(reloaded.snapshot.focusCount == 1)
        store.undoLastSnooze()
        #expect(store.selectedFocusID == "A")
        snapshot.radar[0].fingerprint = "run-2"
        reloaded.receive(snapshot)
        #expect(reloaded.snapshot.radar.count == 1)
    }

    @Test("Search filters visible evidence but never global badges")
    func search() {
        let store = HomeStore(defaults: defaults(), now: { start })
        store.receive(source([item("Garden"), item("Weather")]))
        store.search = "weather"
        #expect(store.snapshot.focus.map(\.id) == ["Weather"])
        #expect(store.snapshot.focusCount == 2)
        #expect(store.snapshot.reviewCount == 3)
        #expect(store.snapshot.waitingChatCount == 2)
        store.search = "absent"
        #expect(store.snapshot.focus.isEmpty)
        #expect(store.snapshot.focusCount == 2)
        store.search = ""
        #expect(store.snapshot.focus.count == 2)
    }

    @Test("A removed selection moves to the next surviving card")
    func removedSelection() {
        let store = HomeStore(defaults: defaults(), now: { start })
        store.receive(source([item("A"), item("B"), item("C")]))
        store.selectFocus("B")
        store.receive(source([item("A"), item("C")]))
        #expect(store.selectedFocusID == "C")
    }

    @Test("Search keeps the priority order and returns to the chosen card when cleared")
    func searchPreservesOrder() {
        let store = HomeStore(defaults: defaults(), now: { start })
        let snapshot = source([item("A"), item("B"), item("C")])
        store.receive(snapshot)
        store.skip()
        store.search = "for A"
        #expect(store.snapshot.focus.map(\.id) == ["A"])
        #expect(store.selectedFocusID == "A")
        store.receive(snapshot)
        store.search = ""
        #expect(store.snapshot.focus.map(\.id) == ["A", "B", "C"])
        #expect(store.selectedFocusID == "B")
        #expect(store.snapshot.focusCount == 3)
    }

    @Test("Visit cutoff stays fixed throughout the visit and survives store replacement")
    func visitBoundary() {
        let preferences = defaults()
        let store = HomeStore(defaults: preferences, now: { start })
        store.beginVisit()
        #expect(store.previousVisit == nil)
        store.beginVisit(now: start.addingTimeInterval(10))
        #expect(store.previousVisit == nil)
        store.endVisit()
        store.beginVisit(now: start.addingTimeInterval(20))
        #expect(store.previousVisit == start)
        let next = HomeStore(defaults: preferences, now: { start.addingTimeInterval(30) })
        next.beginVisit()
        #expect(next.previousVisit == start.addingTimeInterval(20))
    }

    @Test("Preferences prune expired and seven-day absent evidence")
    func prune() {
        var stored = HomeLocalPreferences()
        stored.lastSeen = ["old": start.addingTimeInterval(-8 * 86_400), "recent": start]
        stored.snoozes = ["recent": .init(fingerprint: "q", expiresAt: start)]
        stored.dismissals = ["old": .init(fingerprint: "run"), "recent": .init(fingerprint: "run")]
        stored.prune(now: start)
        #expect(stored.snoozes.isEmpty)
        #expect(stored.dismissals.keys.sorted() == ["recent"])
    }
}

/// Observation reports changes on a Sendable callback.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
