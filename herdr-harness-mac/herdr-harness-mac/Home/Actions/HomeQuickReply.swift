import Foundation

/// Credentials remain private in memory and are never used as view/task IDs.
struct HomeQuickReplyOwner: Equatable, Sendable {
    var route: HomeRoute
    var generation: Int
    var configuration: ServerConfiguration?
    var isDemo: Bool
    var sessionID: String? = nil
}

/// Only the shared, validated skim reader may produce these choices.
struct HomeQuickReplyQuestion: Equatable, Sendable {
    var owner: HomeQuickReplyOwner
    var messageID: String
    var reply: String
    var sessionID: String?
    var actions: [SkimReplyAction]
}

struct HomeQuickReplyPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case loading, ready, sending, accepted
        case unavailable(String)
        case failed(String, retryable: Bool)
        case deliveryUnconfirmed(String, retryable: Bool)

        var message: String? {
            switch self {
            case .loading: "Checking reply options…"
            case .ready: nil
            case .sending: "Sending reply…"
            case .accepted: "Reply sent."
            case .unavailable(let message), .failed(let message, _), .deliveryUnconfirmed(let message, _): message
            }
        }

        var canRetry: Bool {
            switch self {
            case .failed(_, let retryable), .deliveryUnconfirmed(_, let retryable): retryable
            default: false
            }
        }

        var preservesSubmission: Bool {
            switch self {
            case .sending, .accepted, .failed, .deliveryUnconfirmed: true
            default: false
            }
        }
    }

    var question: HomeQuickReplyQuestion?
    var phase: Phase
    var actions: [SkimReplyAction] { phase == .ready ? question?.actions ?? [] : [] }
}

struct HomeQuickReplyLoad: Sendable {
    var question: HomeQuickReplyQuestion?
    var unavailableReason: String? = nil
}

enum HomeQuickReplyResult: Equatable, Sendable {
    case accepted
    case failed(String, retryable: Bool)
    case deliveryUnconfirmed(String, retryable: Bool)

    var phase: HomeQuickReplyPresentation.Phase {
        switch self {
        case .accepted: .accepted
        case .failed(let message, let retryable): .failed(message, retryable: retryable)
        case .deliveryUnconfirmed(let message, let retryable): .deliveryUnconfirmed(message, retryable: retryable)
        }
    }
}

/// The production implementation reuses the existing conversation submission
/// owners. Tests can suspend reads and writes without opening streams.
@MainActor
struct HomeQuickReplyOperations {
    var owner: (HomeRoute) -> HomeQuickReplyOwner?
    var load: (HomeQuickReplyOwner) async throws -> HomeQuickReplyLoad
    var submit: (HomeQuickReplyQuestion, SkimReplyAction) async -> HomeQuickReplyResult
    var retry: (HomeQuickReplyOwner) async -> HomeQuickReplyResult
    var retain: ([HomeQuickReplyOwner]) -> Void = { _ in }
}
