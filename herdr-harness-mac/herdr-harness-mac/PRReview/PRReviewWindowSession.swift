import Foundation
import Observation

/// Presentation state a pop-out copies from the main review exactly once.
///
/// Only user-owned presentation travels. Selection is copied only when the
/// main store is showing exactly this machine/review pair, and never for an
/// Ask AI question draft, which stays private to whichever window owns it.
struct PRReviewWindowSeed: Equatable {
    var tab: PRReviewTab
    var selectedPath: String?
    var viewMode: PRReviewViewMode
    var impactFilter: PRReviewImpactFilter
    var hideViewed: Bool
    var search: String
    var showArchived: Bool

    @MainActor
    static func capture(from main: PRReviewStore, target: PRReviewWindowTarget) -> PRReviewWindowSeed? {
        guard main.currentMachineID == target.machineID,
              main.selectedReviewID == target.reviewID
        else { return nil }
        return PRReviewWindowSeed(
            tab: main.tab,
            selectedPath: main.selectedPath,
            viewMode: main.viewMode,
            impactFilter: main.impactFilter,
            hideViewed: main.hideViewed,
            search: main.search,
            showArchived: main.showArchived
        )
    }
}

/// Owns everything a single popped-out review window needs: its own review
/// store, its own presentation flags, and its own cancellable refresh
/// lifecycle. It never observes or mutates the main window's shell store, so
/// main-window navigation cannot retarget it and closing it cannot disturb
/// the main review, its Ask AI drafts, or any other window.
@MainActor
@Observable
final class PRReviewWindowSession {
    let target: PRReviewWindowTarget
    let store: PRReviewStore

    private(set) var hostState: PRReviewWindowHostState = .checking
    private(set) var hasQuestionDraft = false
    private(set) var isCreating = false
    private(set) var isAddingSkill = false
    private(set) var isPolling = false

    @ObservationIgnored private var activationIdentity: String?
    @ObservationIgnored private var life = 0
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private let pollingInterval: @MainActor (PRReviewStore) -> Duration

    init(
        target: PRReviewWindowTarget,
        store: PRReviewStore = PRReviewStore(),
        pollingInterval: @escaping @MainActor (PRReviewStore) -> Duration = { $0.pollingInterval }
    ) {
        self.target = target
        self.store = store
        self.pollingInterval = pollingInterval
    }

    var canControl: Bool {
        hostState.isUsable
    }

    /// Activates the window for one host identity.
    ///
    /// SwiftUI calls this from a `task(id:)` probe, so re-activations for the
    /// same identity are no-ops and repeated opening of a target never reseeds
    /// presentation or restarts a second polling loop. A different identity
    /// (a re-added machine, another connection) replaces the store
    /// configuration and invalidates every in-flight response from the old one.
    func activate(
        identity: String,
        hostState: PRReviewWindowHostState,
        client: (any PRReviewClient)?,
        seed: PRReviewWindowSeed?
    ) async {
        guard activationIdentity != identity else { return }
        activationIdentity = identity
        life &+= 1
        stopPolling()
        self.hostState = hostState

        guard hostState.isUsable else { return }

        store.configure(client: client, machineID: target.machineID, demo: hostState == .demo)
        store.select(target.reviewID)
        apply(seed)

        let generation = life
        await store.refresh()
        guard life == generation else { return }
        startPolling()
    }

    /// Event-stream refresh, mirroring the main window: the list is refetched
    /// for status changes while the pinned review keeps its selected file.
    func refreshFromEventTick() async {
        guard hostState.isUsable, store.hasLoaded else { return }
        let generation = life
        await store.refresh()
        guard life == generation else { return }
        await store.refreshSelected()
    }

    func setQuestionDraft(_ value: Bool) {
        hasQuestionDraft = value
    }

    func setCreating(_ value: Bool) {
        isCreating = value
    }

    func setAddingSkill(_ value: Bool) {
        isAddingSkill = value
    }

    func startPolling() {
        guard pollingTask == nil, hostState.isUsable else { return }
        isPolling = true
        let generation = life
        pollingTask = Task { @MainActor [weak self] in
            while true {
                guard let self, self.life == generation else { break }
                do {
                    try await Task.sleep(for: self.pollingInterval(self.store))
                } catch {
                    break
                }
                guard self.life == generation, !Task.isCancelled else { break }
                await self.store.refreshSelected()
            }
            self?.finishPolling(generation: generation)
        }
    }

    /// Cancels the loop and invalidates any in-flight activation so a window
    /// that is closing cannot install a late response or restart polling.
    func stop() {
        life &+= 1
        activationIdentity = nil
        stopPolling()
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    private func finishPolling(generation: Int) {
        guard life == generation else { return }
        pollingTask = nil
        isPolling = false
    }

    private func apply(_ seed: PRReviewWindowSeed?) {
        guard let seed else { return }
        store.tab = seed.tab
        store.viewMode = seed.viewMode
        store.impactFilter = seed.impactFilter
        store.hideViewed = seed.hideViewed
        store.search = seed.search
        store.showArchived = seed.showArchived
        store.selectedPath = seed.selectedPath
    }
}
