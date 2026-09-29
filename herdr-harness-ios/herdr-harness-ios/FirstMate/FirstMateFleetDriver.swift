import Foundation

/// Exactly one app-active fleet loop and one selected-store loop. SwiftUI owns
/// the task lifetime; leaving First Mate does not stop the global feature badge.
@MainActor
final class FirstMateFleetDriver {
    private let fleet: FirstMateMobileFleetStore
    private var runID: UUID?
    private var visibleTarget: FirstMateFeatureTarget?
    private var selectedWait: Task<Void, Never>?
    var isFirstMateVisible = false
    var fleetInterval: Duration = .seconds(10)
    var selectedInterval: Duration = .seconds(3)
    var inactiveSelectionInterval: Duration = .seconds(60)

    init(fleet: FirstMateMobileFleetStore) { self.fleet = fleet }

    func setVisibleTarget(_ target: FirstMateFeatureTarget?) {
        // The same target can acquire a new store lifecycle after reconnect.
        // Its presentation signal must still wake the selected-store loop.
        visibleTarget = target
        selectedWait?.cancel()
    }

    func observe(sources: [FirstMateMobileFleetSource], connectionGeneration: Int) async {
        guard !Task.isCancelled else { return }
        let run = UUID()
        runID = run
        selectedWait?.cancel()
        let lifecycle = fleet.activate(sources: sources, connectionGeneration: connectionGeneration)
        defer {
            if runID == run {
                runID = nil
                selectedWait?.cancel()
                selectedWait = nil
                fleet.deactivate(lifecycle: lifecycle)
                fleet.chat.index.deactivate()
            }
        }
        guard !sources.isEmpty else { return }
        // Populate legacy inspector mirrors and the summary index in parallel:
        // a slow initial host must not delay another host's badge. The former
        // ten-second all-store observer is no longer run by the app.
        async let initialStores: Void = fleet.refresh(lifecycle: lifecycle)
        async let initialSummaries: Void = fleet.refreshChatIndex()
        _ = await (initialStores, initialSummaries)
        guard !Task.isCancelled, runID == run, !sources.allSatisfy(\.isDemo) else { return }
        async let summaries: Void = pollSummaries(run: run)
        async let selected: Void = pollSelectedStore(run: run)
        _ = await (summaries, selected)
    }

    private func pollSummaries(run: UUID) async {
        while !Task.isCancelled, runID == run {
            do { try await Task.sleep(for: fleetInterval) } catch { return }
            guard !Task.isCancelled, runID == run else { return }
            await fleet.refreshChatIndex()
            guard !Task.isCancelled, runID == run else { return }
            // The active index intentionally excludes archives. While the
            // archive browser is visible, retain its exact-host full-list path.
            if isFirstMateVisible, fleet.showArchived { await fleet.refresh() }
        }
    }

    private func pollSelectedStore(run: UUID) async {
        while !Task.isCancelled, runID == run {
            if let target = fleet.selectedTarget { await fleet.refreshSelected(target) }
            // Reentrancy: a superseded refresh must not replace the new run's
            // wait handle, even if its client ignored cancellation.
            guard !Task.isCancelled, runID == run else { return }
            let interval = visibleTarget != nil && visibleTarget == fleet.selectedTarget
                ? selectedInterval : inactiveSelectionInterval
            let wait = Task<Void, Never> { _ = try? await Task.sleep(for: interval) }
            selectedWait = wait
            await withTaskCancellationHandler { await wait.value } onCancel: { wait.cancel() }
            if selectedWait == wait { selectedWait = nil }
        }
    }
}
