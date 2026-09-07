import Foundation

struct RemoteNoteMutationResponse: Decodable, Sendable {
    let ok: Bool
    let note: RemoteNote
}
