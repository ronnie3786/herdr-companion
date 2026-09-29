import Foundation

/// A sheet confirmation owns the exact store/lifecycle captured when opened,
/// not whichever connection later happens to have the same machine identifier.
struct FirstMateMobileArchiveRequest: Identifiable {
    let id = UUID()
    let target: FirstMateFeatureTarget
    let store: FirstMateStore
    let context: FirstMateStore.OperationContext
    let feature: FirstMateFeature
    let name: String
    let machineName: String

    @MainActor
    static func capture(target: FirstMateFeatureTarget, fleet: FirstMateMobileFleetStore, name: String? = nil) -> Self? {
        guard let store = fleet.store(for: target), let feature = fleet.feature(for: target), !feature.isLead else { return nil }
        return .init(target: target, store: store, context: store.operationContext, feature: feature,
                     name: name ?? fleet.chat.knownPresentation(for: target)?.name ?? feature.title,
                     machineName: fleet.host(for: target)?.machineName ?? target.machineID)
    }

    @MainActor
    func isCurrent(in fleet: FirstMateMobileFleetStore) -> Bool {
        fleet.store(for: target) === store && store.operationContext == context
    }
}
