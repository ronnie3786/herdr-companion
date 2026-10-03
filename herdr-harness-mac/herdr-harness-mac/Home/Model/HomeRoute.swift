import Foundation

/// Every destination keeps the identity of its owner. Display names are never routing keys.
enum HomeRoute: Hashable, Sendable {
    case firstMate(machineID: String, featureID: String)
    case review(machineID: String, reviewID: String)
    case reviewRequest(url: String)
    case watcher(machineID: String, watcherID: String)
    case chat(paneID: String)
    case machine(machineID: String)
    case firstMateLead, watchers, reviews, chats
}

enum HomeCommand: Hashable, Sendable {
    case open(HomeRoute)
    case ask(String, context: HomeRoute?)
    /// These are Mac-local presentation choices, never completion or server mutations.
    case snooze(String), dismiss(String), skip
}

struct HomeAction: Equatable, Identifiable, Sendable {
    enum Style: Sendable { case primary, secondary, reply, ghost }
    var id: String
    var title: String
    var style: Style = .secondary
    var command: HomeCommand
}
