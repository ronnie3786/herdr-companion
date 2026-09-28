import SwiftUI

/// How the current First Mate screen marks its chat read: the chats the fleet
/// reports unread on the host's machine, and the action that posts a marker.
///
/// A value, not a bare closure, so the environment only changes when the
/// machine or its unread chats change: a new closure on every host pass
/// would re-render the whole transcript each time. The unread chats are part
/// of the value because the transcript's store and the fleet index poll on
/// different cadences: a message can reach the transcript while the fleet
/// still reports the chat read, and the chat must be marked again when the
/// fleet catches up.
struct FirstMateMarkReadAction: Equatable, Sendable {
    let machineID: String
    /// Feature ID → the newest First Mate message the fleet reports, for each
    /// chat the fleet reports unread on this machine.
    let unreadThrough: [String: String]
    private let owner: ObjectIdentifier
    private let perform: @MainActor @Sendable (_ machineID: String, _ featureID: String, _ messageID: String) -> Void

    init(
        machineID: String,
        unreadThrough: [String: String],
        owner: AnyObject,
        perform: @escaping @MainActor @Sendable (_ machineID: String, _ featureID: String, _ messageID: String) -> Void
    ) {
        self.machineID = machineID
        self.unreadThrough = unreadThrough
        self.owner = ObjectIdentifier(owner)
        self.perform = perform
    }

    /// The fleet's unread chats on `machineID`, after this Mac's read markers.
    static func unreadThrough(hosts: [FirstMateFleetHost], readState: FirstMateReadState, machineID: String) -> [String: String] {
        guard let entries = hosts.first(where: { $0.machineID == machineID })?.fleetEntries else { return [:] }
        var unread: [String: String] = [:]
        for (featureID, entry) in entries where readState.isUnread(entry, machineID: machineID) {
            unread[featureID] = entry.latestFirstMateMessageID ?? ""
        }
        return unread
    }

    /// Marks the chat read through `messageID`, only while the fleet reports
    /// it unread.
    @MainActor
    func callAsFunction(featureID: String, messageID: String) {
        guard unreadThrough[featureID] != nil else { return }
        perform(machineID, featureID, messageID)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner && lhs.machineID == rhs.machineID && lhs.unreadThrough == rhs.unreadThrough
    }
}

extension EnvironmentValues {
    /// Set by the host of the current First Mate screen. `FirstMateChatView`
    /// calls it while it is in the key window and scrolled to the newest
    /// message. Nil (the default, and in renders) does nothing.
    @Entry var firstMateMarkRead: FirstMateMarkReadAction? = nil
}

/// What the current First Mate screen's read hook reacts to: the newest First
/// Mate message, whether the person can see it, and whether the fleet reports
/// the chat unread (and through which message).
struct FirstMateChatReadMarker: Equatable, Sendable {
    let featureID: String
    let messageID: String?
    let isVisible: Bool
    /// The fleet's newest First Mate message while it reports this chat
    /// unread, else nil.
    let fleetUnreadThrough: String?

    /// The message to mark read through, or nil when nothing should post.
    var markTarget: String? {
        guard isVisible, fleetUnreadThrough != nil else { return nil }
        return messageID
    }
}
