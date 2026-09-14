import Foundation

enum HerdrHudChatEndError: LocalizedError {
    case busy
    case statusUnavailable
    case stopFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .busy: "Wait for this chat’s history or workspace handoff to finish, then try again."
        case .statusUnavailable: "Reconnect to this chat’s machine to confirm its run has stopped. The chat remains in the HUD."
        case let .stopFailed(message): "Couldn’t stop this chat: \(message) The chat remains in the HUD."
        case .timedOut: "This chat is still finishing its request. It remains in the HUD; try End Chat again shortly."
        }
    }
}
