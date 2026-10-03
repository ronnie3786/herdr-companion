import Foundation

/// An external feature route bound to the source that produced it. Unlike a
/// Dock menu request, a missing target remains unavailable and never falls
/// back to My First Mate or a matching feature on another machine.
struct FirstMateChatExactOpenRequest: Equatable, Identifiable {
    let id: UUID
    let target: FirstMateFleetFeatureID
    let identity: FirstMateConnectionIdentity

    init(target: FirstMateFleetFeatureID, identity: FirstMateConnectionIdentity, id: UUID = UUID()) {
        self.id = id
        self.target = target
        self.identity = identity
    }

    @MainActor
    init(target: FirstMateFleetFeatureID, model: HerdrAppModel) {
        self.init(target: target, identity: FirstMateConnectionIdentity(
            configuration: model.isDemoMode ? nil : model.firstMateConfiguration(machineID: target.machineID),
            generation: model.connectionGeneration, isDemo: model.isDemoMode))
    }
}
