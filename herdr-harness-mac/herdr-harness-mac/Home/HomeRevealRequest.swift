import Foundation

/// A one-time reveal, separate from selection. Reopening the selected item still scrolls.
struct HomeRevealRequest: Equatable, Identifiable, Sendable {
    enum Target: Hashable, Sendable {
        case watcher(machineID: String, watcherID: String)
        case review(machineID: String, reviewID: String)
        case machine(machineID: String)

        var machineID: String {
            switch self {
            case .watcher(let machineID, _), .review(let machineID, _), .machine(let machineID): machineID
            }
        }
    }

    var id = UUID()
    var target: Target
    /// Display context only. Exact identity is always retained in target.
    var ownerName: String? = nil

    var missingMessage: String {
        let owner: String
        if let ownerName, !ownerName.isEmpty, ownerName != target.machineID {
            owner = "\(ownerName) (\(target.machineID))"
        } else {
            owner = target.machineID
        }
        switch target {
        case .watcher(_, let watcherID):
            return "Watcher \(watcherID) is unavailable on the requested machine, \(owner). Check that companion or refresh Watchers."
        case .review(_, let reviewID):
            return "Review \(reviewID) is unavailable on the requested machine, \(owner). Check that companion or refresh PR Review."
        case .machine:
            return "Machine \(owner) is no longer configured. Add it again in Machines to reconnect."
        }
    }
}

/// Drives a view task only when the request or relevant source identities change.
struct HomeRevealAttempt: Equatable {
    var request: HomeRevealRequest?
    var isReady: Bool
    var available: Set<HomeRevealRequest.Target>
}

struct HomeRevealLedger {
    enum Resolution: Equatable {
        case waiting, alreadyHandled, available, missing(String)
    }

    private var handled: Set<UUID> = []

    func resolve(_ request: HomeRevealRequest, isReady: Bool, available: Set<HomeRevealRequest.Target>) -> Resolution {
        if handled.contains(request.id) { return .alreadyHandled }
        guard isReady else { return .waiting }
        return available.contains(request.target) ? .available : .missing(request.missingMessage)
    }

    mutating func markHandled(_ request: HomeRevealRequest) { handled.insert(request.id) }
}
