import Foundation
import Observation

/// Feedback belongs to the latest explicit list mutation and its captured
/// owner. Polling is not an operation and must not erase a genuine failure.
@MainActor @Observable
final class FirstMateListMutationFeedback {
    struct Operation {
        let id = UUID()
        let target: FirstMateFeatureTarget
        let store: FirstMateStore
        let lifecycle: FirstMateStore.LifecycleIdentity
    }
    private var current: Operation?
    private var failure: String?

    func begin(target: FirstMateFeatureTarget, store: FirstMateStore) -> Operation {
        let operation = Operation(target: target, store: store, lifecycle: store.lifecycle)
        current = operation
        failure = nil
        return operation
    }

    func complete(_ operation: Operation, succeeded: Bool, error: String?, fleet: FirstMateMobileFleetStore) {
        guard current?.id == operation.id, isCurrentOwner(operation, fleet: fleet) else { return }
        failure = succeeded ? nil : error ?? "The conversation could not be unarchived."
    }

    func message(in fleet: FirstMateMobileFleetStore) -> String? {
        guard let current, isCurrentOwner(current, fleet: fleet) else { return nil }
        return failure
    }

    func reset() { current = nil; failure = nil }

    private func isCurrentOwner(_ operation: Operation, fleet: FirstMateMobileFleetStore) -> Bool {
        fleet.store(for: operation.target) === operation.store && operation.store.lifecycle == operation.lifecycle
    }
}
