import Foundation

/// Chats read on this Mac ahead of the companion's confirmation.
///
/// Each override is the newest First Mate message the person saw. A chat
/// stays read while the fleet still reports that message as its newest; a new
/// First Mate message makes it unread again even before the next poll.
struct FirstMateReadState: Equatable, Sendable {
    var overrides: [FirstMateFleetFeatureID: String] = [:]

    func isUnread(_ entry: FirstMateFleetEntry, machineID: String) -> Bool {
        entry.unread
            && overrides[FirstMateFleetFeatureID(machineID: machineID, featureID: entry.featureID)] != entry.latestFirstMateMessageID
    }

    mutating func markRead(_ id: FirstMateFleetFeatureID, messageID: String) {
        overrides[id] = messageID
    }

    /// Undoes a failed read, unless a later read has replaced it since.
    mutating func rollBack(_ id: FirstMateFleetFeatureID, messageID: String) {
        guard overrides[id] == messageID else { return }
        overrides[id] = nil
    }
}
