import Foundation

/// These controls change only Mac-local presentation and therefore belong
/// to the interactive host rather than the read-only source projection.
enum HomeActionPresentation {
    static func snapshot(_ source: HomeSnapshot, snoozedCount: Int, unresolvedReplyCount: Int = 0) -> HomeSnapshot {
        var snapshot = source
        snapshot.focus = source.focus.map { original in
            var item = original
            let command = HomeCommand.snooze(item.id)
            if !item.isIdea, !item.actions.contains(where: { $0.command == command }) {
                item.actions.append(.init(id: "later", title: "Later", style: .ghost, command: command))
            }
            return item
        }
        snapshot.radar = source.radar.map { original in
            var item = original
            let command = HomeCommand.dismiss(item.id)
            if !item.actions.contains(where: { $0.command == command }) {
                item.actions.append(.init(id: "dismiss", title: "Dismiss", style: .ghost, command: command))
            }
            return item
        }
        if snoozedCount > 0 {
            snapshot.notices.append("\(snoozedCount) \(snoozedCount == 1 ? "attention item is" : "attention items are") snoozed on this Mac. Snoozing does not resolve the underlying work.")
        }
        if unresolvedReplyCount > 0 {
            snapshot.notices.append("\(unresolvedReplyCount) \(unresolvedReplyCount == 1 ? "reply still needs" : "replies still need") a delivery check below.")
            if snapshot.canShowAllClear {
                snapshot.canShowAllClear = false
                snapshot.mood = .attentive
                snapshot.statusLine = "A reply still needs a check."
                snapshot.summary = ["Your work is moving. Check the reply status below before sending again."]
            }
        }
        return snapshot
    }
}

/// The context card freezes only the observed evidence relevant to the
/// person's question. Refreshes never rewrite an already staged quote.
enum HomeActionContext {
    static func make(route: HomeRoute?, snapshot: HomeSnapshot) -> HomeChatContext? {
        let observedAt = snapshot.updatedAt ?? .now
        if let route {
            if let item = snapshot.focus.first(where: { $0.route == route }) {
                return .init(title: item.title, summary: joined([item.reason, item.body.plainText,
                    item.isStale ? "Last known state." : ""]), observedAt: observedAt)
            }
            if let item = snapshot.chats.first(where: { $0.route == route }) {
                return .init(title: item.title, summary: joined([item.reason, item.location, item.quote,
                    item.isStale ? "Last known state." : ""]), observedAt: observedAt)
            }
            if let item = snapshot.radar.first(where: { radar in
                radar.body.runs.contains { if case .chip(let chip) = $0 { return chip.route == route }; return false }
            }) {
                return .init(title: "On Home's radar", summary: item.body.plainText, observedAt: observedAt)
            }
            if let item = snapshot.recap.first(where: { $0.route == route }) {
                return .init(title: "Recent update on Home", summary: item.body.plainText, observedAt: item.date ?? observedAt)
            }
            return nil
        }
        let summary = joined([snapshot.statusLine] + snapshot.summary.map(\.plainText) + [snapshot.moving.plainText])
        guard !summary.isEmpty else { return nil }
        return .init(title: "Home overview", summary: summary, observedAt: observedAt)
    }

    private static func joined(_ parts: [String]) -> String {
        var seen = Set<String>()
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n\n")
    }
}
