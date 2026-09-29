import Foundation

enum APIError: LocalizedError, Sendable {
    case invalidResponse
    case noActiveConnection(machineID: String)
    case server(status: Int, message: APIServerMessage)
    case streamEnded
    case streamBacklogOverflow

    /// Keep the two-value case and existing construction/status catches. The
    /// message envelope additionally retains the server's machine-readable code.
    static func server(status: Int, message: String, code: String? = nil) -> Self {
        .server(status: status, message: APIServerMessage(text: message, code: code))
    }

    var serverCode: String? {
        guard case .server(_, let message) = self else { return nil }
        return message.code
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The Herdr server returned an invalid response."
        case let .noActiveConnection(machineID): "Machine \(machineID) has no active connection."
        case let .server(status, message): message.text.isEmpty ? "Herdr server error (\(status))." : message.text
        case .streamEnded: "The live Herdr connection ended."
        case .streamBacklogOverflow: "Herdr fell behind the live stream and is resyncing."
        }
    }
}
