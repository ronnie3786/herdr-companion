import Foundation

struct FirstMateConnectionIdentity: Equatable {
    let configuration: ServerConfiguration?
    let generation: Int
    let isDemo: Bool
}
