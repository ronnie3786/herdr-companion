import Foundation

struct FirstMateProjectResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var project: FirstMateProject
}
