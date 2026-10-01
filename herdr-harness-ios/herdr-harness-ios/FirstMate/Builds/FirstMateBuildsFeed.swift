import Foundation

/// One feature's Builds on its machine: the Mobile App Hub builds tagged with
/// it and its simulator checkpoints. Views keep it current only while they
/// are on screen and the app is active. Several views may watch at once (the
/// Builds card, the stage chips, the inspector's refresh anchor): each source
/// is refreshed when it is due, never once per watcher.
@MainActor
final class FirstMateBuildsFeed {
    let target: FirstMateFeatureTarget
    let hub: MobileAppHubFeed
    let simulator: FirstMateSimulatorFeed
    private(set) var isDemo = false

    static let hubInterval: Duration = .seconds(60)
    static let tick: Duration = .seconds(1)

    private var hubQuery: MobileAppHubFeed.Query?
    private var hubDue = ContinuousClock.now
    private var simulatorDue = ContinuousClock.now

    init(target: FirstMateFeatureTarget, hub: MobileAppHubFeed = MobileAppHubFeed(), simulator: FirstMateSimulatorFeed) {
        self.target = target
        self.hub = hub
        self.simulator = simulator
    }

    /// Refreshes whatever is due until the calling task is cancelled.
    func watch(hubQuery: MobileAppHubFeed.Query?) async {
        while !Task.isCancelled {
            await refreshDue(hubQuery: hubQuery)
            do { try await Task.sleep(for: Self.tick) } catch { return }
        }
    }

    /// The hub every minute (at once for a new address), the simulator at the
    /// shared feed's pace: quickly while something starts, rarely without SimPortal.
    func refreshDue(hubQuery: MobileAppHubFeed.Query?, now: ContinuousClock.Instant = .now) async {
        guard !isDemo else { return }
        if let hubQuery, hubQuery != self.hubQuery || now >= hubDue {
            self.hubQuery = hubQuery
            hubDue = now + Self.hubInterval
            await hub.load(hubQuery)
            // A watcher that left mid-load must not delay the next one.
            if Task.isCancelled { hubDue = .now }
        }
        if now >= simulatorDue {
            simulatorDue = now + .seconds(3_600)
            await simulator.refresh()
            simulatorDue = Task.isCancelled ? .now : .now + simulator.nextInterval
        }
    }

    /// A simulator was opened or stopped: refresh the rows at the next tick.
    func refreshSimulatorSoon() {
        simulatorDue = .now
    }

    /// Demo mode: synthetic builds, nothing fetched.
    func presentDemo(_ content: FirstMateBuildsDemo.Content) {
        isDemo = true
        if hub.builds != content.hub { hub.present(content.hub) }
        simulator.presentDemo(builds: content.simulator)
    }
}

/// Builds feeds for the app's lifetime, one per feature target, so Overview,
/// Workflow and the simulator cover share the same rows.
@MainActor
final class FirstMateBuildsFeeds {
    static let shared = FirstMateBuildsFeeds()
    private static let limit = 32
    private var feeds: [FirstMateFeatureTarget: FirstMateBuildsFeed] = [:]
    private var order: [FirstMateFeatureTarget] = []

    func feed(for target: FirstMateFeatureTarget, model: HerdrAppModel) -> FirstMateBuildsFeed {
        if let feed = feeds[target] {
            order.removeAll { $0 == target }
            order.append(target)
            return feed
        }
        let machineID = target.machineID
        let simulator = FirstMateSimulatorFeeds.shared.feed(machineID: machineID, featureID: target.featureID) { [weak model] in
            model?.client(forMachine: machineID)?.simulatorPreviews
        }
        let feed = FirstMateBuildsFeed(target: target, simulator: simulator)
        feeds[target] = feed
        order.append(target)
        if order.count > Self.limit {
            feeds[order.removeFirst()] = nil
        }
        return feed
    }

    func existing(_ target: FirstMateFeatureTarget) -> FirstMateBuildsFeed? {
        feeds[target]
    }
}

extension FirstMateInspectorContext {
    /// This feature's Builds feed. In demo mode a new feed starts with the
    /// feature's synthetic builds, before any view reads it; `presentDemoIfNeeded`
    /// covers a snapshot that arrives later.
    @MainActor
    func buildsFeed(snapshot: FirstMateSnapshot? = nil) -> FirstMateBuildsFeed {
        if let feed = FirstMateBuildsFeeds.shared.existing(target) { return feed }
        let feed = FirstMateBuildsFeeds.shared.feed(for: target, model: model)
        presentDemoIfNeeded(feed, snapshot: snapshot)
        return feed
    }

    @MainActor
    func presentDemoIfNeeded(_ feed: FirstMateBuildsFeed, snapshot: FirstMateSnapshot? = nil) {
        guard model.isDemoMode, !feed.isDemo,
              let snapshot = snapshot ?? model.firstMateFleet.store(for: target)?.snapshot,
              let content = FirstMateBuildsDemo.content(for: snapshot, machineName: model.machineName(target.machineID))
        else { return }
        feed.presentDemo(content)
    }

    /// The Mobile App Hub query for this feature, or nil while no hub is set.
    func hubQuery(hubURLText: String) -> MobileAppHubFeed.Query? {
        MobileAppHubSettings.firstMateQuery(hubURLText: hubURLText, featureID: target.featureID)
    }
}
