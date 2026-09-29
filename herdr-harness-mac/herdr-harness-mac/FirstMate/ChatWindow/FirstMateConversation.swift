import Foundation

/// One feature's row in the chat window's conversation list.
struct FirstMateConversation: Identifiable, Equatable, Sendable {
    let id: FirstMateFleetFeatureID
    let machineID: String
    let machineName: String
    let featureID: String
    let title: String
    let label: String
    let emoji: String
    var hudStatus: FirstMateHudStatus
    /// The raw feature status, for views that keep the native wording.
    let featureStatus: String
    /// 0...5, or nil when the step is unknown.
    let stepIndex: Int?
    let stepFraction: Double?
    let now: String?
    /// One line of plain text, prefixed "You: " when the person sent it.
    let previewText: String
    let previewIsFromUser: Bool
    var isWorkingOnReply: Bool
    let activityAt: Date?
    let latestFirstMateMessageID: String?
    let isUnread: Bool
    let isArchived: Bool

    /// The dot rule: a conversation shows its dot only when it needs you and
    /// has an unread message. Working, ready-to-plan, and complete never do.
    var showsDot: Bool { hudStatus.needsYou && isUnread }
}

enum FirstMateConversationList {
    /// Every non-archived feature across hosts, newest activity first, once
    /// per machine and feature.
    ///
    /// Fleet hosts use their summary; any listed feature the summary has not
    /// reported yet, and every feature on a host without the capability, uses
    /// the fallback: a client-side status and emoji, an unknown step, and
    /// "unread" meaning "needs you", so the dot equals `FirstMateAttention`.
    static func build(hosts: [FirstMateFleetHost], readState: FirstMateReadState) -> [FirstMateConversation] {
        var seen = Set<FirstMateFleetFeatureID>()
        var conversations: [FirstMateConversation] = []
        func append(_ conversation: FirstMateConversation) {
            guard !conversation.isArchived, seen.insert(conversation.id).inserted else { return }
            conversations.append(conversation)
        }
        for host in hosts {
            let features = Dictionary(host.features.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if host.supportsFleet, let entries = host.fleetEntries {
                // The summary's own order is not the list order; sorting below
                // decides. Iterate in a stable order for de-duplication.
                for entry in entries.values.sorted(by: { $0.featureID < $1.featureID }) {
                    append(conversation(entry: entry, feature: features[entry.featureID], host: host, readState: readState))
                }
            }
            for feature in host.features where host.fleetEntries?[feature.id] == nil || !host.supportsFleet {
                append(conversation(fallback: feature, host: host))
            }
        }
        return conversations.sorted { lhs, rhs in
            switch (lhs.activityAt, rhs.activityAt) {
            case let (left?, right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if lhs.machineID != rhs.machineID { return lhs.machineID < rhs.machineID }
                return lhs.featureID < rhs.featureID
            }
        }
    }

    private static func conversation(
        entry: FirstMateFleetEntry,
        feature: FirstMateFeature?,
        host: FirstMateFleetHost,
        readState: FirstMateReadState
    ) -> FirstMateConversation {
        let title = entry.title.isEmpty ? feature?.title ?? entry.label : entry.title
        let preview: String
        let fromUser: Bool
        if let latest = entry.latestMessage {
            fromUser = latest.isFromUser
            if fromUser {
                preview = "You: " + FirstMateChatPreview.plainText(latest.text)
            } else if let say = latest.skimSay.map(FirstMateChatPreview.plainText), !say.isEmpty {
                preview = say
            } else {
                preview = FirstMateChatPreview.plainText(latest.text)
            }
        } else {
            fromUser = false
            preview = entry.now.map(FirstMateChatPreview.plainText) ?? ""
        }
        let activity = entry.activityAt ?? entry.latestMessage?.createdAt ?? entry.updatedAt ?? feature?.updatedAt
        return FirstMateConversation(
            id: FirstMateFleetFeatureID(machineID: host.machineID, featureID: entry.featureID),
            machineID: host.machineID,
            machineName: host.machineName,
            featureID: entry.featureID,
            title: title,
            label: entry.label.isEmpty ? title : entry.label,
            emoji: entry.emoji,
            hudStatus: entry.hudStatus,
            featureStatus: entry.status,
            stepIndex: entry.stepIndex,
            stepFraction: entry.stepIndex == nil ? nil : entry.stepFraction,
            now: entry.now,
            previewText: preview,
            previewIsFromUser: fromUser,
            isWorkingOnReply: entry.workingOnReply,
            activityAt: activity.flatMap(HerdrTimestamp.date(from:)),
            latestFirstMateMessageID: entry.latestFirstMateMessageID,
            isUnread: readState.isUnread(entry, machineID: host.machineID),
            isArchived: entry.isArchived || feature?.isArchived == true
        )
    }

    private static func conversation(fallback feature: FirstMateFeature, host: FirstMateFleetHost) -> FirstMateConversation {
        let hudStatus = FirstMateHudStatus.fallback(featureStatus: feature.status)
        let summary = feature.dashboardSummary
        let activity = summary?.activityAt ?? summary?.latestMessageAt ?? feature.updatedAt
        return FirstMateConversation(
            id: FirstMateFleetFeatureID(machineID: host.machineID, featureID: feature.id),
            machineID: host.machineID,
            machineName: host.machineName,
            featureID: feature.id,
            title: feature.title,
            label: FirstMateFleetEntry.defaultLabel(title: feature.title),
            emoji: FirstMateDefaultEmoji.emoji(for: feature.id),
            hudStatus: hudStatus,
            featureStatus: feature.status,
            stepIndex: nil,
            stepFraction: nil,
            now: hudStatus.needsYou ? summary?.needsUserPrompt.map(FirstMateChatPreview.plainText) : nil,
            previewText: summary?.latestMessage.map(FirstMateChatPreview.plainText) ?? "",
            previewIsFromUser: false,
            isWorkingOnReply: feature.coordinatorOwner != nil,
            activityAt: HerdrTimestamp.date(from: activity),
            latestFirstMateMessageID: nil,
            isUnread: hudStatus.needsYou,
            isArchived: feature.isArchived
        )
    }
}

/// Turns a Markdown message into the one plain line a list row shows.
enum FirstMateChatPreview {
    static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence {
                line = stripBlockMarkers(line)
                line = stripInline(line)
            }
            if !line.isEmpty { lines.append(line) }
        }
        return lines.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func stripBlockMarkers(_ line: String) -> String {
        var line = line
        let patterns = [#"^#{1,6}\s+"#, #"^>\s?"#, #"^[-*+]\s+\[[ xX]\]\s+"#, #"^[-*+]\s+"#, #"^\d+[.)]\s+"#]
        for pattern in patterns {
            line = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // A horizontal rule or table divider carries no words.
        if line.range(of: #"^[\s|:*_-]+$"#, options: .regularExpression) != nil { return "" }
        return line
    }

    /// Characters Markdown lets a backslash escape. Escaped ones are parked on
    /// private-use scalars so emphasis and link rules never see them.
    private static let escapable = Array("\\`*_{}[]()#+-.!|>~")

    private static func stripInline(_ line: String) -> String {
        var line = line
        for (index, character) in escapable.enumerated() {
            line = line.replacingOccurrences(of: "\\" + String(character), with: placeholder(index))
        }
        let replacements: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),         // images keep their alt text
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),          // links and mentions keep their text
            (#"<((?:https?|herdr)://[^>\s]+)>"#, "$1"),
            (#"`+([^`]*)`+"#, "$1"),
            (#"(\*\*|__)(.+?)\1"#, "$2"),
            (#"(?<![\w*])\*(?!\s)([^*]+?)\*(?![\w*])"#, "$1"),
            (#"(?<![\w_])_(?!\s)([^_]+?)_(?![\w_])"#, "$1"),
            (#"~~(.+?)~~"#, "$1"),
        ]
        for (pattern, template) in replacements {
            line = line.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        line = line.replacingOccurrences(of: "|", with: " ")
        for (index, character) in escapable.enumerated() {
            line = line.replacingOccurrences(of: placeholder(index), with: String(character))
        }
        return line
    }

    private static func placeholder(_ index: Int) -> String {
        String(Character(Unicode.Scalar(0xE000 + UInt32(index))!))
    }
}
