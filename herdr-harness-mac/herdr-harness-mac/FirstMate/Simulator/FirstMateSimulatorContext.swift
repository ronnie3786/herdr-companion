import SwiftUI

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
