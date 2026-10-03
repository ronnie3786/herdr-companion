import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Home local presentation")
@MainActor
struct HomeStoreTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "HomeStoreTests.\(UUID().uuidString)")!
    }

    private func item(_ id: String, fingerprint: String = "question-1") -> HomeFocusItem {
        HomeFocusItem(id: id, title: id, reason: "Your call", body: HomeText("Question for \(id)"),
                      route: .firstMate(machineID: "garden", featureID: id), fingerprint: fingerprint)
    }

    private func source(_ items: [HomeFocusItem]) -> HomeSnapshot {
        var value = HomeSnapshot()
        value.focus = items
        value.focusCount = items.count
        value.reviewCount = 3
        value.waitingChatCount = 2
        return value
    }

    @Test("Skip rotates without resolving and unrelated refresh preserves the selected card")
    func skipAndRefresh() {
        let store = HomeStore(defaults: defaults(), now: { start })
        let snapshot = source([item("A"), item("B"), item("C")])
        store.receive(snapshot)
        store.skip()
        #expect(store.selectedFocusID == "B")
        #expect(store.snapshot.focus.map(\.id) == ["B", "C", "A"])
        store.receive(snapshot)
        #expect(store.selectedFocusID == "B")
        #expect(store.snapshot.focusCount == 3)
        #expect(store.snapshot.focus.map(\.id) == ["B", "C", "A"])
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
        store.refreshLocalTime(now: start.addingTimeInterval(3_600))
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
