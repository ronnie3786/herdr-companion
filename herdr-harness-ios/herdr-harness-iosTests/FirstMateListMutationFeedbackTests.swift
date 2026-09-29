import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("List mutation feedback ownership")
@MainActor
struct FirstMateListMutationFeedbackTests {
    private func setup() -> (FirstMateMobileFleetStore, FirstMateStore, FirstMateFeatureTarget) {
        let fleet = FirstMateMobileFleetStore(defaults: UserDefaults(suiteName: "MutationFeedback.\(UUID())")!)
        let machine = ChatFixtures.machine("alpha")
        fleet.activate(sources: [.init(machine: machine, configuration: nil, client: nil, isDemo: true)], connectionGeneration: 1)
        let store = fleet.store(forMachineID: "alpha")!
        return (fleet, store, .init(machineID: "alpha", featureID: store.features[0].id))
    }

    @Test("Failure persists through unrelated polling; retry and success clear the actual banner")
    func retrySuccess() async {
        let (fleet, store, target) = setup()
        let feedback = FirstMateListMutationFeedback()
        let first = feedback.begin(target: target, store: store)
        feedback.complete(first, succeeded: false, error: "Synthetic unarchive failure", fleet: fleet)
        #expect(feedback.message(in: fleet) == "Synthetic unarchive failure")
        await fleet.refresh()
        #expect(feedback.message(in: fleet) == "Synthetic unarchive failure")
        let retry = feedback.begin(target: target, store: store)
        #expect(feedback.message(in: fleet) == nil)
        feedback.complete(retry, succeeded: true, error: store.error, fleet: fleet)
        #expect(feedback.message(in: fleet) == nil)
        feedback.complete(first, succeeded: false, error: "Late old failure", fleet: fleet)
        #expect(feedback.message(in: fleet) == nil)
    }

    @Test("Competing operations cannot let older feedback replace the newer result")
    func competingOperations() {
        let (fleet, store, target) = setup()
        let feedback = FirstMateListMutationFeedback()
        let first = feedback.begin(target: target, store: store)
        let other = feedback.begin(target: .init(machineID: target.machineID, featureID: "other"), store: store)
        feedback.complete(other, succeeded: false, error: "Current operation failed", fleet: fleet)
        feedback.complete(first, succeeded: true, error: nil, fleet: fleet)
        #expect(feedback.message(in: fleet) == "Current operation failed")
    }

    @Test("Replacement/removal and explicit reset fence stale completions and old banners")
    func lifecycle() {
        let (fleet, store, target) = setup()
        let feedback = FirstMateListMutationFeedback()
        let old = feedback.begin(target: target, store: store)
        feedback.complete(old, succeeded: false, error: "Old owner failure", fleet: fleet)
        let machine = ChatFixtures.machine("alpha")
        fleet.activate(sources: [.init(machine: machine, configuration: nil, client: nil, isDemo: true)], connectionGeneration: 2)
        #expect(feedback.message(in: fleet) == nil)
        feedback.complete(old, succeeded: false, error: "Late old owner", fleet: fleet)
        #expect(feedback.message(in: fleet) == nil)
        let current = feedback.begin(target: target, store: fleet.store(forMachineID: "alpha")!)
        feedback.reset()
        feedback.complete(current, succeeded: false, error: "After reset", fleet: fleet)
        #expect(feedback.message(in: fleet) == nil)
        fleet.retireAll()
        #expect(feedback.message(in: fleet) == nil)
    }
}
