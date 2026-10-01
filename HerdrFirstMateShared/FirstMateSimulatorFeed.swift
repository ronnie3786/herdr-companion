import SwiftUI

/// One feature's simulator checkpoints on one machine, shared by the
/// inspector's Overview and Workflow tabs. Views poll it only while visible.
@MainActor @Observable
final class FirstMateSimulatorFeed {
    let machineID: String
    let featureID: String
    private(set) var status: FirstMateSimulatorStatus?
    private(set) var builds: [FirstMateSimulatorBuild] = []
    private(set) var selectedBuildID: String?
    private(set) var error: String?
    private(set) var hasLoaded = false
    /// The companion predates simulator previews (404/501).
    private(set) var unsupported = false

    @ObservationIgnored private let makeAPI: @MainActor () -> FirstMateSimulatorAPI?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var isDemo = false

    init(machineID: String, featureID: String,
         configuration: @escaping @MainActor () -> ServerConfiguration?,
         makeAPI: @escaping @MainActor (ServerConfiguration) -> FirstMateSimulatorAPI = { FirstMateSimulatorAPI(configuration: $0) }) {
        self.machineID = machineID
        self.featureID = featureID
        self.makeAPI = { configuration().map(makeAPI) }
    }

    /// For a caller that already holds the machine's API (the iOS client), or nil while it is offline.
    init(machineID: String, featureID: String, api: @escaping @MainActor () -> FirstMateSimulatorAPI?) {
        self.machineID = machineID
        self.featureID = featureID
        self.makeAPI = api
    }

    /// Only a configured machine with at least one checkpoint shows the section.
    var isVisible: Bool { !builds.isEmpty }

    var api: FirstMateSimulatorAPI? { makeAPI() }

    func refresh() async {
        guard !isDemo, let api else { return }
        do {
            let list = try await api.builds(featureID: featureID)
            // Keep an unchanged array so views that diff it stay quiet.
            if list.builds != builds { builds = list.builds }
            if status != list.simulator { status = list.simulator }
            selectedBuildID = list.selectedBuildID
            error = nil
            unsupported = false
            failures = 0
        } catch let failure as FirstMateSimulatorError {
            failures += 1
            unsupported = failure.status == 404 || failure.status == 501
            error = unsupported ? nil : failure.message
        } catch {
            failures += 1
            self.error = "Couldn't refresh simulator builds."
        }
        hasLoaded = true
    }

    /// Refreshes until cancelled: quickly while something is saving or
    /// starting, slowly otherwise, and rarely on a machine without SimPortal.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: nextInterval) } catch { return }
        }
    }

    var nextInterval: Duration {
        if unsupported || status?.configured == false { return .seconds(300) }
        if failures > 0 { return .seconds(min(120, 15 * failures)) }
        let settling = builds.contains { build in
            build.status == "registering" || build.previews.contains { $0.phase == "starting" || $0.phase == "stopping" }
        }
        return settling ? .seconds(4) : .seconds(30)
    }

    /// Builds saved during this workflow stage (a visit), newest first.
    func builds(forVisit visitID: String) -> [FirstMateSimulatorBuild] {
        builds.filter { $0.visitID == visitID }
    }

    /// The simulator copy saved alongside a Mobile App Hub build.
    func build(forHubBuild hubBuildID: String) -> FirstMateSimulatorBuild? {
        builds.first { $0.hubBuildID == hubBuildID }
    }

    /// Synthetic checkpoints for demo mode and renders; nothing is fetched.
    func presentDemo(visitIDs: [String]) {
        presentDemo(builds: FirstMateSimulatorDemo.builds(featureID: featureID, visitIDs: visitIDs))
    }

    /// Shows the given synthetic builds; nothing is fetched.
    func presentDemo(builds: [FirstMateSimulatorBuild], status: FirstMateSimulatorStatus = FirstMateSimulatorDemo.status) {
        isDemo = true
        hasLoaded = true
        if self.status != status { self.status = status }
        if self.builds != builds { self.builds = builds }
    }
}

/// Feeds kept for the app's lifetime, one per machine and feature, so the
/// Overview and Workflow tabs and each simulator view share the same state.
@MainActor
final class FirstMateSimulatorFeeds {
    static let shared = FirstMateSimulatorFeeds()
    private static let limit = 32
    private var feeds: [String: FirstMateSimulatorFeed] = [:]
    private var order: [String] = []

    func feed(machineID: String, featureID: String,
              configuration: @escaping @MainActor () -> ServerConfiguration?) -> FirstMateSimulatorFeed {
        feed(machineID: machineID, featureID: featureID) {
            FirstMateSimulatorFeed(machineID: machineID, featureID: featureID, configuration: configuration)
        }
    }

    func feed(machineID: String, featureID: String,
              api: @escaping @MainActor () -> FirstMateSimulatorAPI?) -> FirstMateSimulatorFeed {
        feed(machineID: machineID, featureID: featureID) {
            FirstMateSimulatorFeed(machineID: machineID, featureID: featureID, api: api)
        }
    }

    private func feed(machineID: String, featureID: String,
                      make: () -> FirstMateSimulatorFeed) -> FirstMateSimulatorFeed {
        let key = machineID + "|" + featureID
        if let feed = feeds[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return feed
        }
        let feed = make()
        feeds[key] = feed
        order.append(key)
        if order.count > Self.limit {
            feeds[order.removeFirst()] = nil
        }
        return feed
    }

    func existing(machineID: String, featureID: String) -> FirstMateSimulatorFeed? {
        feeds[machineID + "|" + featureID]
    }
}
