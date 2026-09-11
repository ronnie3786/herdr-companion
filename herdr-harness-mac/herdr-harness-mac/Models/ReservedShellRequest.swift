import Foundation

struct ReservedShellRequest: Encodable, Sendable {
    let terminalID: String
    let action: String

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminalId"
        case action
    }
}
