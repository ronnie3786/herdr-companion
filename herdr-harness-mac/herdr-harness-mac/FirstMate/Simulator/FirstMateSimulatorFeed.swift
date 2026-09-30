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

    @ObservationIgnored private let configuration: @MainActor () -> ServerConfiguration?
    @ObservationIgnored private let makeAPI: @MainActor (ServerConfiguration) -> FirstMateSimulatorAPI
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var isDemo = false

    init(machineID: String, featureID: String,
         configuration: @escaping @MainActor () -> ServerConfiguration?,
         makeAPI: @escaping @MainActor (ServerConfiguration) -> FirstMateSimulatorAPI = { FirstMateSimulatorAPI(configuration: $0) }) {
        self.machineID = machineID
        self.featureID = featureID
        self.configuration = configuration
        self.makeAPI = makeAPI
    }

    /// Only a configured machine with at least one checkpoint shows the section.
    var isVisible: Bool { !builds.isEmpty }

    var api: FirstMateSimulatorAPI? { configuration().map(makeAPI) }

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
        isDemo = true
        hasLoaded = true
        status = FirstMateSimulatorDemo.status
        builds = FirstMateSimulatorDemo.builds(featureID: featureID, visitIDs: visitIDs)
    }
}

/// Feeds kept for the app's lifetime, one per machine and feature, so the
/// Overview and Workflow tabs and each window share the same state.
@MainActor
final class FirstMateSimulatorFeeds {
    static let shared = FirstMateSimulatorFeeds()
    private static let limit = 32
    private var feeds: [String: FirstMateSimulatorFeed] = [:]
    private var order: [String] = []

    func feed(machineID: String, featureID: String,
              configuration: @escaping @MainActor () -> ServerConfiguration?) -> FirstMateSimulatorFeed {
        let key = machineID + "|" + featureID
        if let feed = feeds[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return feed
        }
        let feed = FirstMateSimulatorFeed(machineID: machineID, featureID: featureID, configuration: configuration)
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

/// What the inspector needs to show a feature's simulator checkpoints. The
/// window hosting the inspector provides it; without it no simulator UI shows.
struct FirstMateSimulatorContext {
    let machineID: String
    let feed: FirstMateSimulatorFeed
    let isDemo: Bool

    func target(for build: FirstMateSimulatorBuild) -> FirstMateSimulatorWindowTarget {
        FirstMateSimulatorWindowTarget(machineID: machineID, featureID: build.featureID, buildID: build.id)
    }
}

private struct FirstMateSimulatorContextKey: EnvironmentKey {
    static let defaultValue: FirstMateSimulatorContext? = nil
}

extension EnvironmentValues {
    var firstMateSimulator: FirstMateSimulatorContext? {
        get { self[FirstMateSimulatorContextKey.self] }
        set { self[FirstMateSimulatorContextKey.self] = newValue }
    }
}

extension View {
    /// Provides the simulator checkpoints of `featureID` on `machineID` to the inspector below.
    func firstMateSimulator(model: HerdrAppModel, machineID: String?, featureID: String?) -> some View {
        let context: FirstMateSimulatorContext? = if let machineID, let featureID {
            FirstMateSimulatorContext(
                machineID: machineID,
                feed: FirstMateSimulatorFeeds.shared.feed(machineID: machineID, featureID: featureID,
                                                          configuration: { [weak model] in model?.firstMateConfiguration(machineID: machineID) }),
                isDemo: model.isDemoMode)
        } else {
            nil
        }
        return environment(\.firstMateSimulator, context)
    }
}

/// Keeps a feed current while its section is on screen and the app is active.
private struct FirstMateSimulatorRefreshModifier: ViewModifier {
    let context: FirstMateSimulatorContext?
    let demoVisitIDs: [String]
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.task(id: TaskKey(feed: context.map { ObjectIdentifier($0.feed) }, active: scenePhase == .active)) {
            guard let context else { return }
            if context.isDemo {
                context.feed.presentDemo(visitIDs: demoVisitIDs)
                return
            }
            guard scenePhase == .active else { return }
            await context.feed.poll()
        }
    }

    private struct TaskKey: Equatable {
        let feed: ObjectIdentifier?
        let active: Bool
    }
}

extension View {
    func firstMateSimulatorRefresh(_ context: FirstMateSimulatorContext?, demoVisitIDs: [String]) -> some View {
        modifier(FirstMateSimulatorRefreshModifier(context: context, demoVisitIDs: demoVisitIDs))
    }
}
