import Foundation

struct FirstMateNavigationIdentity: Equatable {
    let connection: FirstMateConnectionIdentity
    let requestID: UUID?
    let controlFeatureID: String?
}
