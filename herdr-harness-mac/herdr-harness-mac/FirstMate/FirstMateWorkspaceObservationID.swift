import Foundation

struct FirstMateWorkspaceObservationID: Hashable {
    private let storeID: ObjectIdentifier
    private let selectedFeatureID: String?

    @MainActor
    init(store: FirstMateStore) {
        storeID = ObjectIdentifier(store)
        selectedFeatureID = store.selectedFeatureID
    }
}
