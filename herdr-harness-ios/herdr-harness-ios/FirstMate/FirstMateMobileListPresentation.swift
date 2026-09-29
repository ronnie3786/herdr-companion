import Foundation

/// Phone presentation only: the shared builder owns identity, recency and read
/// rules. Unlike the Mac HUD, the phone pins six features PLUS an overflow orb.
struct FirstMateMobileListPresentation {
    let rows: [FirstMateConversation]
    let pinned: [FirstMateConversation]
    let overflow: [FirstMateConversation]
    let showsLead: Bool
    let query: String
    static let pinnedLimit = 6

    init(conversations: [FirstMateConversation], scope: FirstMateMachineScope, query: String,
         features: [FirstMateFeatureTarget: FirstMateFeature] = [:], leadIDs: Set<FirstMateFleetFeatureID> = []) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        showsLead = query.isEmpty || "My First Mate".localizedCaseInsensitiveContains(query)
        var seen = Set<FirstMateFleetFeatureID>()
        rows = conversations.filter { row in
            let target = Self.target(row)
            guard !row.isArchived, !leadIDs.contains(row.id), features[target]?.isLead != true,
                  scope.includes(machineID: row.machineID), seen.insert(row.id).inserted else { return false }
            return Self.matches(query, conversation: row, feature: features[target])
        }.sorted(by: Self.moreRecent)
        let needsYou = rows.filter { $0.hudStatus.needsYou }.sorted { left, right in
            let a = Self.urgency(left.hudStatus), b = Self.urgency(right.hudStatus)
            return a == b ? Self.moreRecent(left, right) : a < b
        }
        pinned = Array(needsYou.prefix(Self.pinnedLimit))
        overflow = Array(needsYou.dropFirst(Self.pinnedLimit))
    }

    var emptyMessage: String? {
        guard rows.isEmpty else { return nil }
        if query.isEmpty { return "No features yet. Press ＋ and tell First Mate what to build." }
        return showsLead ? nil : "No conversations match “\(query)”."
    }

    static func target(_ row: FirstMateConversation) -> FirstMateFeatureTarget {
        .init(machineID: row.machineID, featureID: row.featureID)
    }

    static func preview(_ row: FirstMateConversation) -> String {
        row.isWorkingOnReply ? "typing…" : row.previewText
    }

    static func matches(_ query: String, conversation: FirstMateConversation, feature: FirstMateFeature?) -> Bool {
        query.isEmpty || [conversation.name, conversation.title, conversation.label,
                         conversation.previewText, preview(conversation), conversation.machineName,
                         feature?.goal ?? "", feature?.workItemID ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func moreRecent(_ left: FirstMateConversation, _ right: FirstMateConversation) -> Bool {
        if left.activityAt != right.activityAt { return (left.activityAt ?? .distantPast) > (right.activityAt ?? .distantPast) }
        if left.machineID != right.machineID { return left.machineID < right.machineID }
        return left.featureID < right.featureID
    }

    private static func urgency(_ status: FirstMateHudStatus) -> Int {
        switch status { case .blocked: 0; case .turn: 1; case .ready: 2; default: 3 }
    }

    /// Archive inventory is deliberately not fed through the active-only
    /// shared builder. Retain known user presentation without inventing edits.
    static func archived(_ row: FirstMateMobileFleetFeature, known: FirstMateConversation?) -> FirstMateConversation {
        .init(id: .init(machineID: row.machineID, featureID: row.featureID), machineID: row.machineID,
              machineName: row.machineName, featureID: row.featureID, title: row.feature.title,
              label: known?.label ?? row.feature.title, isUserNamed: known?.isUserNamed ?? false,
              emoji: known?.emoji ?? FirstMateDefaultEmoji.emoji(for: row.featureID), isUserEmoji: known?.isUserEmoji ?? false,
              hudStatus: .fallback(featureStatus: row.feature.status), featureStatus: row.feature.status,
              stepIndex: nil, stepFraction: nil, now: nil,
              previewText: FirstMateChatPreview.plainText(row.feature.dashboardSummary?.latestMessage ?? known?.previewText ?? row.feature.goal),
              previewIsFromUser: false, isWorkingOnReply: false,
              activityAt: HerdrTimestamp.date(from: row.feature.dashboardSummary?.activityAt ?? row.feature.updatedAt),
              latestFirstMateMessageID: nil, isUnread: false, isArchived: true)
    }
}
