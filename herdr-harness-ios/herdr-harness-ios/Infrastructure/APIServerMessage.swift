import Foundation

/// Server error text and its optional stable code. Kept together inside the
/// existing two-value APIError.server case so status-based shared catches keep
/// recognizing unsupported endpoints, conflicts and uncertain outgoing sends.
struct APIServerMessage: Equatable, Sendable {
    let text: String
    let code: String?
}
