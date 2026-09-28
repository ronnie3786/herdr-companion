import Foundation

/// The one count behind the Dock badge, the chat window's sidebar, and the
/// main window's First Mate badge, so every number agrees.
enum FirstMateBadge {
    /// Conversations showing an unread dot: every non-archived feature on any
    /// host that needs you and has an unread First Mate message, counted once
    /// per machine and feature.
    ///
    /// A host without `first-mate-fleet-v1` treats every feature that needs you
    /// as unread, which equals `FirstMateAttention.count`. A host whose last
    /// refresh failed keeps its last successful features and summary, so an
    /// outage never reads as resolved.
    static func count(hosts: [FirstMateFleetHost], readState: FirstMateReadState) -> Int {
        FirstMateConversationList.build(hosts: hosts, readState: readState).count(where: \.showsDot)
    }
}
