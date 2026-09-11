import Foundation

struct PaneRetirementRequest: Encodable, Sendable {
    let requestID: String
    let terminalID: String
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case terminalID = "terminalId"
        case sessionID = "sessionId"
    }
}
