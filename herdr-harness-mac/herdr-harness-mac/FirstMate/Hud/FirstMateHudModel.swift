import Foundation

// The First Mate HUD's rules as pure functions: which features show, their
// order, overflow, the face's count, local answers, and spoken labels. The
// views and the panel only read these, so every rule is unit-tested.

/// One feature on the First Mate HUD: the chat window's conversation plus the
/// feature's start time, which the HUD's order needs.
struct FirstMateHudItem: Identifiable, Equatable, Sendable {
    let conversation: FirstMateConversation
    /// When the feature started, for "start order". Nil sorts after known ones.
    let startedAt: Date?

    var id: FirstMateFleetFeatureID { conversation.id }
    var hudStatus: FirstMateHudStatus { conversation.hudStatus }
    var needsYou: Bool { hudStatus.needsYou }
    var label: String { conversation.label.isEmpty ? conversation.title : conversation.label }
    var emoji: String { conversation.emoji }
    /// The chat window's dot rule: needs you and has an unread message.
    var showsDot: Bool { conversation.showsDot }

    /// 0...100, or nil when the step is unknown. Complete is always 100.
    var percent: Int? { FirstMateHudProgress.percent(status: hudStatus, step: conversation.stepIndex, fraction: conversation.stepFraction) }

    /// The row's state word: the status for needs-you rows, the step for
    /// moving rows ("Building"), or the status when the step is unknown.
    var stateWord: String {
        if needsYou { return FirstMateChatStatusStyle.label(for: hudStatus) }
        if hudStatus == .done { return "Merged" }
        if hudStatus == .working, let step = conversation.stepIndex { return FirstMateChatSteps.doing[step] }
        if hudStatus == .idle, let step = conversation.stepIndex { return FirstMateChatSteps.names[step] }
        return FirstMateChatStatusStyle.label(for: hudStatus)
    }
}

enum FirstMateHudProgress {
    /// `round((step + fraction) / 6 × 100)`, nil when the step is unknown.
    static func percent(status: FirstMateHudStatus, step: Int?, fraction: Double?) -> Int? {
        if status == .done { return 100 }
        guard let step else { return nil }
        let count = Double(FirstMateChatSteps.names.count)
        let clamped = min(max(fraction ?? 0, 0), 1)
        return Int((Double(step) + clamped) / count * 100 + 0.5)
    }

    /// Fill of each of the six segments, 0...1. Unknown steps are all empty;
    /// complete is all full.
    static func segments(status: FirstMateHudStatus, step: Int?, fraction: Double?) -> [Double] {
        let count = FirstMateChatSteps.names.count
        if status == .done { return Array(repeating: 1, count: count) }
        guard let step else { return Array(repeating: 0, count: count) }
        let current = min(max(fraction ?? 0, 0), 1)
        return (0..<count).map { index in
            index < step ? 1 : index == step ? current : 0
        }
    }
}

enum FirstMateHudRoster {
    /// How long a completed feature stays on the HUD as "Merged".
    static let doneLinger: TimeInterval = 120

    /// Every feature the HUD shows, in HUD order.
    ///
    /// Archived and cancelled features never show. A completed feature shows
    /// for ``doneLinger`` after its last activity, then leaves.
    static func items(hosts: [FirstMateFleetHost], readState: FirstMateReadState, now: Date) -> [FirstMateHudItem] {
        var starts: [FirstMateFleetFeatureID: Date] = [:]
        var cancelled = Set<FirstMateFleetFeatureID>()
        for host in hosts {
            for feature in host.features {
                let id = FirstMateFleetFeatureID(machineID: host.machineID, featureID: feature.id)
                starts[id] = HerdrTimestamp.date(from: feature.createdAt)
                if feature.status == "cancelled" { cancelled.insert(id) }
            }
        }
        let items = FirstMateConversationList.build(hosts: hosts, readState: readState).compactMap { conversation -> FirstMateHudItem? in
            guard !conversation.isArchived,
                  conversation.featureStatus != "cancelled",
                  !cancelled.contains(conversation.id) else { return nil }
            if conversation.hudStatus == .done {
                guard let activity = conversation.activityAt, now.timeIntervalSince(activity) < doneLinger else { return nil }
            }
            return FirstMateHudItem(conversation: conversation, startedAt: starts[conversation.id])
        }
        return FirstMateHudOrder.sorted(items)
    }
}

enum FirstMateHudOrder {
    /// Blocked first, then your turn, then ready for review.
    static func urgency(_ status: FirstMateHudStatus) -> Int {
        switch status {
        case .blocked: 0
        case .turn: 1
        case .ready: 2
        case .working, .idle, .done, .unknown: 3
        }
    }

    /// Needs-you rows on top by urgency, ties in start order; then every
    /// other feature in start order. Keys are stable, so a row moves only
    /// when its status changes.
    static func sorted(_ items: [FirstMateHudItem]) -> [FirstMateHudItem] {
        items.sorted { lhs, rhs in
            let (left, right) = (urgency(lhs.hudStatus), urgency(rhs.hudStatus))
            if left != right { return left < right }
            return startsBefore(lhs, rhs)
        }
    }

    static func startsBefore(_ lhs: FirstMateHudItem, _ rhs: FirstMateHudItem) -> Bool {
        switch (lhs.startedAt, rhs.startedAt) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            if lhs.id.machineID != rhs.id.machineID { return lhs.id.machineID < rhs.id.machineID }
            return lhs.id.featureID < rhs.id.featureID
        }
    }
}

/// What the collapsed row and the expanded list show when there are more
/// features than fit. The principle: what needs you is never hidden; features
/// that are only moving are compressed.
enum FirstMateHudOverflow {
    /// The collapsed row's cap, including the "+N" orb.
    static let maxOrbs = 6
    /// The expanded list summarizes moving rows beyond this many.
    static let movingRowLimit = 4
    /// Moving rows shown above the summary row.
    static let movingRowsShown = 3

    struct Collapsed: Equatable, Sendable {
        /// Orbs in list order.
        var orbs: [FirstMateHudItem]
        /// Features behind the "+N" orb, in list order.
        var tucked: [FirstMateHudItem]
        var hasMore: Bool { !tucked.isEmpty }
    }

    /// Up to ``maxOrbs`` orbs. With more features, the first five show and the
    /// sixth slot becomes "+N". Needs-you features always keep their own orb,
    /// even past the cap; then only moving features are tucked.
    static func collapsed(_ ordered: [FirstMateHudItem], maxOrbs: Int = maxOrbs) -> Collapsed {
        guard ordered.count > maxOrbs else { return Collapsed(orbs: ordered, tucked: []) }
        let needsYou = ordered.filter(\.needsYou)
        let shown = max(maxOrbs - 1, needsYou.count)
        return Collapsed(orbs: Array(ordered.prefix(shown)), tucked: Array(ordered.dropFirst(shown)))
    }

    struct Summary: Equatable, Sendable {
        /// Moving features the summary stands for (empty when showing all).
        var tucked: [FirstMateHudItem]
        /// True once every moving row shows; the row then reads "Show fewer".
        var isShowingAll: Bool
        var count: Int { tucked.count }
        /// The tucked features' average percent, over those with a known step.
        var averagePercent: Int? {
            let known = tucked.compactMap(\.percent)
            guard !known.isEmpty else { return nil }
            return Int(Double(known.reduce(0, +)) / Double(known.count) + 0.5)
        }
    }

    struct Expanded: Equatable, Sendable {
        var needsYou: [FirstMateHudItem]
        var moving: [FirstMateHudItem]
        /// Moving rows draw compact (one line) while every row shows.
        var movingAreCompact: Bool
        var summary: Summary?
    }

    /// Every needs-you row in full. More than four moving rows show three and
    /// a summary row; showing all turns every moving row compact.
    static func expanded(_ ordered: [FirstMateHudItem], showAllMoving: Bool) -> Expanded {
        let needsYou = ordered.filter(\.needsYou)
        let moving = ordered.filter { !$0.needsYou }
        guard moving.count > movingRowLimit else {
            return Expanded(needsYou: needsYou, moving: moving, movingAreCompact: false, summary: nil)
        }
        if showAllMoving {
            return Expanded(needsYou: needsYou, moving: moving, movingAreCompact: true,
                            summary: Summary(tucked: [], isShowingAll: true))
        }
        return Expanded(
            needsYou: needsYou,
            moving: Array(moving.prefix(movingRowsShown)),
            movingAreCompact: false,
            summary: Summary(tucked: Array(moving.dropFirst(movingRowsShown)), isShowingAll: false)
        )
    }
}

/// The count on First Mate's face.
enum FirstMateHudBadge {
    struct Value: Equatable, Sendable {
        var count: Int
        /// The most urgent status among them: blocked, then your turn, then ready.
        var status: FirstMateHudStatus
    }

    /// The needs-you features, or nil at zero.
    static func value(_ items: [FirstMateHudItem]) -> Value? {
        let needsYou = items.filter(\.needsYou)
        guard let urgent = needsYou.min(by: { FirstMateHudOrder.urgency($0.hudStatus) < FirstMateHudOrder.urgency($1.hudStatus) }) else {
            return nil
        }
        return Value(count: needsYou.count, status: urgent.hudStatus)
    }
}

/// Phase 1 routing for typed and spoken words, with no lead First Mate yet:
/// a question about the fleet is answered here from the summary; words that
/// name a feature go to that feature as the person's message.
enum FirstMateHudRouting {
    enum Route: Equatable, Sendable {
        /// Post `text` to the feature as the person's message.
        case send(FirstMateFleetFeatureID, label: String, text: String)
        /// Answer locally.
        case answer(String)
    }

    static let noMatchAnswer = "I couldn't tell which feature that's for. Name one, like “Receipt export”, or ask what needs you."

    static func route(_ text: String, items: [FirstMateHudItem]) -> Route {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let item = namedItem(in: trimmed, items: items) {
            return .send(item.id, label: item.label, text: trimmed)
        }
        if isFleetQuestion(trimmed) { return .answer(summary(items)) }
        if items.isEmpty { return .answer("No First Mate features are running.") }
        return .answer(noMatchAnswer)
    }

    /// The feature whose label or title the text names, as whole words,
    /// ignoring case. The longest name wins, so "Review search results" beats
    /// "Review". Ambiguous names (two features share one) match neither.
    static func namedItem(in text: String, items: [FirstMateHudItem]) -> FirstMateHudItem? {
        let haystack = " " + normalized(text) + " "
        var best: (item: FirstMateHudItem, length: Int)?
        var ambiguous = false
        for item in items {
            let names = Set([item.label, item.conversation.title].map(normalized).filter { $0.count >= 3 })
            for name in names where haystack.contains(" " + name + " ") {
                if let current = best, current.length == name.count, current.item.id != item.id {
                    ambiguous = true
                } else if best == nil || name.count > best!.length {
                    best = (item, name.count)
                    ambiguous = false
                }
            }
        }
        return ambiguous ? nil : best?.item
    }

    private static let questionPhrases = [
        "what needs me", "what needs you", "who needs me", "what's waiting", "whats waiting", "what is waiting",
        "anything need", "anything for me", "what's up", "whats up", "status", "summary", "what's going on",
        "whats going on", "catch me up", "where are we", "what's blocked", "whats blocked", "what is blocked",
    ]

    static func isFleetQuestion(_ text: String) -> Bool {
        let lowered = normalized(text)
        return questionPhrases.contains { lowered.contains(normalized($0)) }
    }

    /// "Two need you: Receipt export is blocked in QA, and Push alert
    /// settings has a question."
    static func summary(_ items: [FirstMateHudItem]) -> String {
        let needsYou = FirstMateHudOrder.sorted(items.filter(\.needsYou))
        let moving = items.count - needsYou.count
        guard !needsYou.isEmpty else {
            switch moving {
            case 0: return "Nothing needs you, and no features are running."
            case 1: return "Nothing needs you. One feature is moving."
            default: return "Nothing needs you. \(countWord(moving, capitalized: true)) features are moving."
            }
        }
        let phrases = needsYou.prefix(4).map(phrase)
        let head = needsYou.count == 1 ? "One needs you" : "\(countWord(needsYou.count, capitalized: true)) need you"
        var sentence = head + ": " + listSentence(Array(phrases))
        if needsYou.count > 4 { sentence += ", and \(needsYou.count - 4) more" }
        return sentence + "."
    }

    /// "Receipt export is blocked in QA".
    static func phrase(_ item: FirstMateHudItem) -> String {
        let step = item.conversation.stepIndex.map { " in " + FirstMateChatSteps.names[$0] } ?? ""
        switch item.hudStatus {
        case .blocked: return "\(item.label) is blocked\(step)"
        case .turn: return "\(item.label) has a question"
        case .ready: return "\(item.label) is ready for review"
        case .working: return "\(item.label) is working\(step)"
        case .idle: return "\(item.label) is ready to plan"
        case .done: return "\(item.label) is complete"
        case .unknown: return item.label
        }
    }

    static func listSentence(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return parts[0] + ", and " + parts[1]
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts.last!
        }
    }

    static func countWord(_ count: Int, capitalized: Bool = false) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        guard words.indices.contains(count) else { return String(count) }
        let word = words[count]
        return capitalized ? word.prefix(1).uppercased() + word.dropFirst() : word
    }

    /// Lowercased, punctuation to spaces, single-spaced. Curly apostrophes
    /// (dictation's) read as straight ones.
    static func normalized(_ text: String) -> String {
        let mapped = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "'" ? Character(scalar) : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
}

enum FirstMateHudSpeech {
    /// "Receipt export: blocked in QA, 58 percent. Unread message. Opens the
    /// session."
    static func accessibilityLabel(_ item: FirstMateHudItem, opensMessage: Bool = false) -> String {
        var text = item.label + ": " + FirstMateChatStatusStyle.label(for: item.hudStatus).lowercased()
        if let step = item.conversation.stepIndex, item.hudStatus != .done {
            text += " in " + FirstMateChatSteps.names[step]
        }
        if let percent = item.percent { text += ", \(percent) percent" }
        text += "."
        if item.showsDot { text += " Unread message." }
        text += opensMessage && item.showsDot ? " Opens the message." : " Opens the session."
        return text
    }
}
