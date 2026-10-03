import Testing
@testable import herdr_harness_mac

@Suite("Navigation history")
struct NavigationHistoryTests {
    @Test("Recording the current destination again is a no-op")
    func recordingCurrentDestinationIsNoOp() {
        var history = NavigationHistory()

        history.record(.pane("a"))
        history.record(.pane("a"))

        #expect(history.current == .pane("a"))
        #expect(history.backward.isEmpty)
        #expect(!history.canGoBack)
    }

    @Test("Back and forward walk the recorded trail")
    func backAndForwardWalkTrail() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))

        #expect(history.goBack(isAlive: alive) == .pane("b"))
        #expect(history.goBack(isAlive: alive) == .pane("a"))
        #expect(history.current == .pane("a"))
        #expect(history.forward == [.pane("b"), .pane("c")])
        #expect(history.goForward(isAlive: alive) == .pane("b"))
    }

    @Test("A new destination clears the forward stack")
    func newDestinationClearsForwardStack() {
        var history = trail(.pane("a"), .pane("b"))
        _ = history.goBack(isAlive: alive)

        history.record(.fleet)

        #expect(!history.canGoForward)
        #expect(history.backward == [.pane("a")])
    }

    @Test("Mixed scope and pane destinations round-trip")
    func mixedDestinationsRoundTrip() {
        let destinations: [HerdrDestination] = [
            .pane("a"), .firstMate, .git("a"), .activity,
        ]
        var history = trail(destinations)

        #expect(history.goBack(isAlive: alive) == .git("a"))
        #expect(history.goBack(isAlive: alive) == .firstMate)
        #expect(history.goBack(isAlive: alive) == .pane("a"))
        #expect(history.goForward(isAlive: alive) == .firstMate)
        #expect(history.goForward(isAlive: alive) == .git("a"))
        #expect(history.goForward(isAlive: alive) == .activity)
    }

    @Test("The stack is capped and drops the oldest")
    func stackCapDropsOldestDestination() {
        var history = NavigationHistory()
        for index in 0..<(NavigationHistory.capacity + 10) {
            history.record(.pane("pane-\(index)"))
        }

        #expect(history.backward.count == NavigationHistory.capacity)
        #expect(history.backward.first == .pane("pane-9"))
        #expect(history.current == .pane("pane-59"))
    }

    @Test("Back skips destinations the fleet has dropped")
    func backSkipsDroppedDestinations() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))

        #expect(history.goBack(isAlive: { $0 != .pane("b") }) == .pane("a"))
        #expect(history.current == .pane("a"))
        #expect(!history.forward.contains(.pane("b")))
        #expect(history.forward == [.pane("c")])
    }

    @Test("Back returns nil and leaves the current destination alone when nothing survives")
    func backWithNoSurvivingDestinationsLeavesCurrentAlone() {
        var history = trail(.pane("a"), .pane("b"))

        #expect(history.goBack(isAlive: { _ in false }) == nil)
        #expect(history.current == .pane("b"))
        history.prune(isAlive: { _ in false })
        #expect(!history.canGoBack)
    }

    @Test("Pruning drops dead entries from both stacks and keeps the current one")
    func pruningDropsDeadEntriesButKeepsCurrent() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))
        _ = history.goBack(isAlive: alive)

        history.prune(isAlive: { $0 == .pane("b") })

        #expect(history.current == .pane("b"))
        #expect(history.backward.isEmpty)
        #expect(history.forward.isEmpty)
    }

    @Test("Pruning a fully live history is a no-op")
    func pruningFullyLiveHistoryIsNoOp() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))
        _ = history.goBack(isAlive: alive)
        let originalHistory = history

        history.prune(isAlive: alive)

        #expect(history == originalHistory)
    }

    @Test("Forward mirrors back")
    func forwardSkipsDroppedDestinationsAndLeavesCurrentWhenNoneSurvive() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))
        _ = history.goBack(isAlive: alive)
        _ = history.goBack(isAlive: alive)

        #expect(history.goForward(isAlive: { $0 != .pane("b") }) == .pane("c"))
        #expect(history.current == .pane("c"))
        #expect(history.backward == [.pane("a")])

        var noSurvivors = trail(.pane("a"), .pane("b"))
        _ = noSurvivors.goBack(isAlive: alive)
        #expect(noSurvivors.goForward(isAlive: { _ in false }) == nil)
        #expect(noSurvivors.current == .pane("a"))
    }

    @Test("An empty history reports neither direction")
    func emptyHistoryReportsNeitherDirection() {
        var history = NavigationHistory()

        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.goBack(isAlive: alive) == nil)
        #expect(history.goForward(isAlive: alive) == nil)
    }

    @Test("Snapshot round-trips through NavigationHistory init")
    func snapshotRoundTripsThroughNavigationHistory() {
        var history = trail(.pane("a"), .pane("b"), .pane("c"))
        _ = history.goBack(isAlive: alive)

        let restored = NavigationHistory(snapshot: history.snapshot)

        #expect(restored.backward == history.backward)
        #expect(restored.current == history.current)
        #expect(restored.forward == history.forward)
    }

    @Test("An unrecognized kind is dropped without disturbing its neighbors")
    func unrecognizedKindIsDroppedWithoutDisturbingNeighbors() {
        let snapshot = NavigationHistorySnapshot(
            version: NavigationHistorySnapshot.currentVersion,
            backward: [
                HerdrDestinationRecord(.pane("a"))!,
                HerdrDestinationRecord(kind: "widgetPane", id: "z"),
                HerdrDestinationRecord(.pane("c"))!,
            ],
            current: nil,
            forward: []
        )

        let restored = NavigationHistory(snapshot: snapshot)

        #expect(restored.backward == [.pane("a"), .pane("c")])
    }

    @Test("Retired Active Work history is skipped while neighboring destinations survive")
    func retiredActiveWorkHistoryIsSkipped() {
        let retired = HerdrDestinationRecord(kind: "activeWork", id: nil)
        let snapshot = NavigationHistorySnapshot(
            version: NavigationHistorySnapshot.currentVersion,
            backward: [HerdrDestinationRecord(.pane("a"))!, retired],
            current: retired,
            forward: [retired, HerdrDestinationRecord(.fleet)!]
        )
        var restored = NavigationHistory(snapshot: snapshot)
        #expect(restored.current == nil)
        #expect(restored.backward == [.pane("a")])
        #expect(restored.forward == [.fleet])
        #expect(restored.goBack(isAlive: alive) == .pane("a"))
        #expect(HerdrDetailScope(rawValue: "activeWork") == nil)
    }

    @Test("Retired overviews migrate to Home and adjacent entries collapse")
    func migratesHomeHistory() {
        let snapshot = NavigationHistorySnapshot(version: NavigationHistorySnapshot.currentVersion,
            backward: [.init(kind: "pane", id: "a"), .init(kind: "dashboard", id: nil), .init(kind: "agentBoard", id: nil)],
            current: .init(kind: "activity", id: nil),
            forward: [.init(kind: "dashboard", id: nil), .init(kind: "fleet", id: nil)])
        let restored = NavigationHistory(snapshot: snapshot)
        #expect(restored.backward == [.pane("a")])
        #expect(restored.current == .home)
        #expect(restored.forward == [.fleet])
        #expect(HerdrDestinationRecord(.home)?.kind == "home")
    }

    @Test("Restoring caps backward to the entries nearest to current")
    func restoringCapsBackwardToEntriesNearestCurrent() {
        let oversized = (0..<(NavigationHistory.capacity + 10)).map {
            HerdrDestinationRecord(.pane("pane-\($0)"))!
        }
        let snapshot = NavigationHistorySnapshot(
            version: NavigationHistorySnapshot.currentVersion,
            backward: oversized,
            current: nil,
            forward: []
        )

        let restored = NavigationHistory(snapshot: snapshot)

        #expect(restored.backward.count == NavigationHistory.capacity)
        #expect(restored.backward.first == .pane("pane-10"))
    }

    @Test("Restoring a snapshot yields a usable Back")
    func restoringSnapshotYieldsUsableBack() {
        let snapshot = NavigationHistorySnapshot(
            version: NavigationHistorySnapshot.currentVersion,
            backward: [HerdrDestinationRecord(.pane("a"))!],
            current: HerdrDestinationRecord(.fleet),
            forward: []
        )
        var restored = NavigationHistory(snapshot: snapshot)

        #expect(restored.canGoBack)
        #expect(restored.goBack(isAlive: alive) == .pane("a"))
    }

    @Test("Retired workspace and attention entries drop out of a restored snapshot")
    func retiredDestinationsDropOut() {
        let snapshot = NavigationHistorySnapshot(
            version: NavigationHistorySnapshot.currentVersion,
            backward: [
                HerdrDestinationRecord(.pane("a"))!,
                HerdrDestinationRecord(kind: "workspace", id: "w1"),
                HerdrDestinationRecord(kind: "attention", id: nil),
            ],
            current: HerdrDestinationRecord(kind: "attention", id: nil),
            forward: [HerdrDestinationRecord(kind: "workspace", id: "w2")]
        )
        let restored = NavigationHistory(snapshot: snapshot)

        #expect(restored.backward == [.pane("a")])
        #expect(restored.current == nil)
        #expect(restored.forward.isEmpty)
    }

    private func trail(_ destinations: HerdrDestination...) -> NavigationHistory {
        trail(destinations)
    }

    private func trail(_ destinations: [HerdrDestination]) -> NavigationHistory {
        var history = NavigationHistory()
        destinations.forEach { history.record($0) }
        return history
    }

    private func alive(_ destination: HerdrDestination) -> Bool {
        _ = destination
        return true
    }
}
