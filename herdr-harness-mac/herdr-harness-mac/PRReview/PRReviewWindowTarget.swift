import Foundation

/// The stable identity of one popped-out PR Review window.
///
/// The target deliberately carries only the configured machine and the
/// server-local review id. Titles, repositories, pull request numbers, and
/// list order are presentation, not identity, so two hosts that both call a
/// review `prr_1` produce two distinct windows, while re-opening the same
/// machine/review pair focuses the window SwiftUI already owns for that value.
struct PRReviewWindowTarget: Codable, Hashable, Identifiable, Sendable {
    static let windowIdentifierPrefix = "pr-review-window-"
    static let popOutActionIdentifierPrefix = "pr-review-pop-out-"

    let machineID: String
    let reviewID: String

    var id: String {
        "\(machineID)|\(reviewID)"
    }

    /// Stable accessibility identifiers for the window content and the
    /// context-menu action that opens or focuses it.
    var windowAccessibilityIdentifier: String {
        Self.windowIdentifierPrefix + id
    }

    var popOutActionAccessibilityIdentifier: String {
        Self.popOutActionIdentifierPrefix + id
    }

    init(machineID: String, reviewID: String) {
        self.machineID = machineID
        self.reviewID = reviewID
    }
}

/// How a window's pinned host is currently represented in the connected fleet.
///
/// `missingHost` and `unconfigured` are terminal for the *target*: neither
/// silently retargets another machine, not even the machine that is currently
/// selected as the review host in the main window.
enum PRReviewWindowHostState: Equatable, Sendable {
    case checking
    case demo
    case available
    case missingHost
    case unconfigured

    var isUsable: Bool {
        self == .demo || self == .available
    }
}

enum PRReviewWindowHostResolver {
    /// Order matters: a removed host is checked before any configuration
    /// question so a missing machine can never borrow the default host.
    static func resolve(
        isDemoTarget: Bool,
        targetMachineExists: Bool,
        hasConfiguration: Bool
    ) -> PRReviewWindowHostState {
        if isDemoTarget { return .demo }
        guard targetMachineExists else { return .missingHost }
        return hasConfiguration ? .available : .unconfigured
    }
}
