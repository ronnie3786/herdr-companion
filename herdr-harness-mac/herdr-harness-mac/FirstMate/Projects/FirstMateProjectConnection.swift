import Foundation

/// An immutable authenticated destination for a form or request. Never render
/// the configuration or use its token as a view identity.
struct FirstMateProjectConnection {
    let machineID: String
    let machineName: String
    let configuration: ServerConfiguration
    let epoch: UUID
    let serverID: String?
    let client: any FirstMateClient
}
