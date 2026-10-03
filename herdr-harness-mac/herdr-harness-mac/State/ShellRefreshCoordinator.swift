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
    private var runID: UUID?
    private(set) var isPolling = false

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

    func refreshSummaries(model: HerdrAppModel, shell: HerdrShellState) async {
        let identity = model.workInboxConnectionIdentity
        async let inbox: Void = shell.workInbox.refresh(for: identity) {
            try await model.fetchWorkInbox(expectedIdentity: identity)
        }
        async let activity: Void = model.refreshActivityFeed()
        _ = await (inbox, activity)
    }

    private func poll(interval: @MainActor @Sendable () -> Duration, refresh: @MainActor @Sendable () async -> Void) async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: interval()) } catch { return }
        }
    }
}
