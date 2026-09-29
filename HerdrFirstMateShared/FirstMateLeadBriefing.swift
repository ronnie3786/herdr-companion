import Foundation

/// The My First Mate briefing, built on this Mac from the fleet summary until
/// the lead First Mate exists (Phase 2). It is a summary, not a message from
/// an agent, and views must label it that way.
enum FirstMateLeadBriefing {
    enum Segment: Equatable, Sendable {
        case text(String)
        case mention(FirstMateConversation)
    }

    struct Briefing: Equatable, Sendable {
        /// "Good morning", "Good afternoon" or "Good evening".
        var greeting: String
        /// The whole briefing, greeting included, with features as mentions.
        var segments: [Segment]

        var plainText: String {
            segments.map { segment in
                switch segment {
                case .text(let text): text
                case .mention(let conversation): conversation.name
                }
            }.joined()
        }
    }

    static func greeting(for date: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    /// "{Greeting}. 3 features need you: A is blocked in QA, B needs a call, and
    /// C is ready for review. D and E are moving, and F shipped yesterday."
    ///
    /// Needs-you features are grouped blocked, your turn, then ready for
    /// review, each in list order. "Moving" is working plus ready to plan; only
    /// the most recently finished feature is mentioned.
    static func build(conversations: [FirstMateConversation], now: Date, calendar: Calendar) -> Briefing {
        let greeting = greeting(for: now, calendar: calendar)
        var builder = SegmentBuilder()
        builder.text(greeting + ". ")
        let needs = [FirstMateHudStatus.blocked, .turn, .ready].flatMap { status in
            conversations.filter { $0.hudStatus == status }
        }
        if needs.isEmpty {
            builder.text("Nothing needs you right now.")
        } else {
            builder.text("\(needs.count) \(needs.count == 1 ? "feature needs" : "features need") you: ")
            builder.list(needs) { builder, conversation in
                builder.mention(conversation)
                switch conversation.hudStatus {
                case .blocked:
                    if let step = conversation.stepIndex {
                        builder.text(" is blocked in \(FirstMateChatSteps.names[step])")
                    } else {
                        builder.text(" is blocked")
                    }
                case .turn: builder.text(" needs a call")
                default: builder.text(" is ready for review")
                }
            }
            builder.text(".")
        }
        let moving = conversations.filter { !$0.hudStatus.needsYou && $0.hudStatus != .done }
        let shipped = conversations.filter { $0.hudStatus == .done }
            .max { ($0.activityAt ?? .distantPast) < ($1.activityAt ?? .distantPast) }
        if !moving.isEmpty || shipped != nil {
            builder.text(" ")
            if !moving.isEmpty {
                builder.list(moving) { builder, conversation in builder.mention(conversation) }
                builder.text(moving.count == 1 ? " is moving" : " are moving")
                if shipped != nil { builder.text(", and ") }
            }
            if let shipped {
                builder.mention(shipped)
                builder.text(" shipped" + shippedWhen(shipped.activityAt, now: now, calendar: calendar))
            }
            builder.text(".")
        }
        return Briefing(greeting: greeting, segments: builder.segments)
    }

    /// The lead row's status line.
    static func leadRowPreview(conversations: [FirstMateConversation]) -> String {
        let count = conversations.count { $0.hudStatus.needsYou }
        switch count {
        case 0: return "Nothing needs you"
        case 1: return "1 feature needs you"
        default: return "\(count) features need you"
        }
    }

    /// The lead chat header's subtitle, for example "3 need you, 3 moving,
    /// 1 done". Empty groups are left out.
    static func headerSubtitle(conversations: [FirstMateConversation]) -> String {
        let needs = conversations.count { $0.hudStatus.needsYou }
        let done = conversations.count { $0.hudStatus == .done }
        let moving = conversations.count - needs - done
        let parts = [(needs, "need you"), (moving, "moving"), (done, "done")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "No features yet" : parts.joined(separator: ", ")
    }

    private static func shippedWhen(_ date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "" }
        switch FirstMateChatTime.daysBefore(date, now: now, calendar: calendar) {
        case 0: return " today"
        case 1: return " yesterday"
        default:
            let parts = calendar.dateComponents([.month, .day], from: date)
            let month = (parts.month ?? 1) - 1
            let name = calendar.monthSymbols.indices.contains(month) ? calendar.monthSymbols[month] : ""
            return " on \(name) \(parts.day ?? 1)"
        }
    }

    private struct SegmentBuilder {
        private(set) var segments: [Segment] = []

        mutating func text(_ value: String) {
            guard !value.isEmpty else { return }
            if case .text(let previous) = segments.last {
                segments[segments.count - 1] = .text(previous + value)
            } else {
                segments.append(.text(value))
            }
        }

        mutating func mention(_ conversation: FirstMateConversation) {
            segments.append(.mention(conversation))
        }

        /// A serial-comma list: "A", "A and B", "A, B, and C".
        mutating func list(_ items: [FirstMateConversation], _ item: (inout SegmentBuilder, FirstMateConversation) -> Void) {
            for (index, conversation) in items.enumerated() {
                if index > 0 {
                    if items.count == 2 {
                        text(" and ")
                    } else {
                        text(index == items.count - 1 ? ", and " : ", ")
                    }
                }
                item(&self, conversation)
            }
        }
    }
}
