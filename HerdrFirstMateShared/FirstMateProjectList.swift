import Foundation

struct FirstMateProjectList: Codable, Equatable, Sendable {
    var ok: Bool
    var serverID: String
    var projects: [FirstMateProject]

    enum CodingKeys: String, CodingKey {
        case ok, projects
        case serverID = "server_id"
    }
}
