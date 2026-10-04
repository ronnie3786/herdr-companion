import Foundation

/// Authenticated source identity, kept only in memory and never logged.
struct ShellRefreshConnectionIdentity: Hashable {
    let roster: PRReviewFleetIdentity
    let configurationURLs: [String?]

    @MainActor
    static func current(model: HerdrAppModel) -> Self {
        let configurations = model.machines.map { model.prReviewConfiguration(machineID: $0.id) }
        return .init(
            roster: .init(
                isDemo: model.isDemoMode,
                generation: model.connectionGeneration,
                machines: zip(model.machines, configurations).map { machine, configuration in
                    .init(id: machine.id, name: machine.name, urlString: machine.urlString, token: configuration?.token ?? "")
                }
            ),
            configurationURLs: configurations.map { $0?.baseURL.absoluteString }
        )
    }
}

/// Lightweight fleet polling belongs to the stable window shell. The root's
/// structured task cancels all loops when the window hides or the app resigns
/// activity; configuration reconciliation still runs in that state.
@MainActor
final class ShellRefreshCoordinator {
    /// A Work inbox load makes the primary companion run a GitHub search and a Jira query.
    static let inboxMinimumInterval: TimeInterval = 60
    /// Alert history reads up to 500 alerts from every machine.
    static let historyMinimumInterval: TimeInterval = 60

    private var runID: UUID?
    private(set) var isPolling = false
    private let now: () -> Date
    private var historyIdentity: ShellRefreshConnectionIdentity?
    private var historyRefreshedAt: Date?
    private var historyAlertIDs: [String]?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func reconcile(model: HerdrAppModel, shell: HerdrShellState) {
        let identity = ShellRefreshConnectionIdentity.current(model: model)
        let configurations = model.machines.compactMap { machine in
            model.prReviewConfiguration(machineID: machine.id).map { (machine, $0) }
        }
        shell.watchers.configure(configurations.map { machine, configuration in
            .init(machineID: machine.id, machineName: machine.name, client: HerdrAPIClient(configuration: configuration))
        }, identity: identity, demo: model.isDemoMode)
        shell.prReviewFleet.setSources(model.isDemoMode ? [] : configurations.map { machine, configuration in
            .init(machineID: machine.id, machineName: machine.name, client: HerdrAPIClient(configuration: configuration),
                  configuration: configuration)
        }, identity: identity)
        shell.workInbox.configure(identity: model.workInboxConnectionIdentity)
    }

    func run(model: HerdrAppModel, shell: HerdrShellState, canPoll: Bool) async {
        let request = UUID()
        runID = request
        reconcile(model: model, shell: shell)
        isPolling = canPoll
        guard canPoll else { return }
        defer { if runID == request { isPolling = false } }
        async let watchers: Void = poll(interval: { shell.watchers.pollingInterval }) {
            await shell.watchers.refresh()
        }
        async let reviews: Void = poll(interval: { .seconds(30) }) {
            // This reads cached companion summaries. Only explicit review
            // actions request an upstream GitHub status refresh.
            await shell.prReviewFleet.refresh()
        }
        async let summaries: Void = poll(interval: { .seconds(300) }) {
            await self.refreshSummaries(model: model, shell: shell)
        }
        _ = await (watchers, reviews, summaries)
    }

    /// Polls, activations and events share interval floors; `force` is for a
    /// person's explicit refresh.
    func refreshSummaries(model: HerdrAppModel, shell: HerdrShellState, force: Bool = false) async {
        let identity = model.workInboxConnectionIdentity
        let instant = now()
        async let inbox: Void = shell.workInbox.refresh(
            for: identity, minimumInterval: force ? 0 : Self.inboxMinimumInterval, now: instant
        ) {
            try await model.fetchWorkInbox(expectedIdentity: identity)
        }
        await refreshHistory(identity: .current(model: model), alertIDs: model.alerts.map(\.id), force: force) {
            await model.refreshActivityFeed()
        }
        await inbox
    }

    /// Fetches alert history at most once per interval for one connection;
    /// a new connection identity fetches immediately.
    func refreshHistory(identity: ShellRefreshConnectionIdentity, alertIDs: [String], force: Bool = false,
                        refresh: () async -> Void) async {
        if historyIdentity != identity {
            historyIdentity = identity
            historyRefreshedAt = nil
            historyAlertIDs = nil
        }
        let instant = now()
        if !force, let historyRefreshedAt,
           instant.timeIntervalSince(historyRefreshedAt) < Self.historyMinimumInterval { return }
        historyRefreshedAt = instant
        historyAlertIDs = alertIDs
        await refresh()
    }

    /// True when the current alerts differ from those seen by the last history fetch.
    func historyIsBehind(alertIDs: [String]) -> Bool { historyAlertIDs != alertIDs }

    /// A short debounce, or the wait until the history interval allows another fetch.
    func historyDelay() -> Duration {
        let remaining = historyRefreshedAt.map { Self.historyMinimumInterval - now().timeIntervalSince($0) } ?? 0
        return .milliseconds(Int(max(0.5, remaining) * 1_000))
    }

    private func poll(interval: @MainActor @Sendable () -> Duration, refresh: @MainActor @Sendable () async -> Void) async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: interval()) } catch { return }
        }
    }
}
