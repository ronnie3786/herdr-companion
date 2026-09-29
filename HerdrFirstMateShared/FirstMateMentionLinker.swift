import SwiftUI

/// Crew agents in the chat window: a role emoji and a status on the HUD scale,
/// so an agent's avatar edge, picker row, and mention run read like a feature's.
enum FirstMateCrewStyle {
    static func emoji(forRole role: String) -> String {
        switch role.lowercased() {
        case "planner": "🗺️"
        case "designer": "🎨"
        case "reviewer": "🔎"
        case "researcher": "📚"
        case "tester": "🧪"
        case "builder": "🛠️"
        default: "✦"
        }
    }

    /// A raw assignment status on the HUD scale.
    static func status(forAssignment status: String) -> FirstMateHudStatus {
        switch status {
        case "blocked", "failed": .blocked
        case "awaiting_direction": .turn
        case "running", "coordinating", "recovering", "processing": .working
        case "completed", "done", "passed": .done
        default: .idle
        }
    }

    /// The agent's word: queued reads "Queued", finished reads "Done".
    static func word(forAssignment status: String) -> String {
        switch self.status(forAssignment: status) {
        case .idle: "Queued"
        case .done: "Done"
        case let other: FirstMateChatStatusStyle.label(for: other)
        }
    }
}

/// The names the chat window turns into mention runs, and how each one looks.
///
/// Features come from the conversation list; agents from the open feature's
/// crew. Plain-name matching (exact, whole words, longest first, never in code
/// or links) is on for First Mate's replies and off for your own bubbles, where
/// only the mentions you picked become runs.
struct FirstMateMentionCatalog: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var name: String
        var emoji: String
        var status: FirstMateHudStatus
        var target: FirstMateMentionTarget
    }

    var entries: [Entry]
    var matchesPlainNames = true

    init(entries: [Entry], matchesPlainNames: Bool = true) {
        self.entries = entries
        self.matchesPlainNames = matchesPlainNames
    }

    /// Every listed feature (by displayed name, title, and short label)
    /// and the crew of `snapshot`.
    init(conversations: [FirstMateConversation], snapshot: FirstMateSnapshot?) {
        var entries: [Entry] = []
        for conversation in conversations {
            let target = FirstMateMentionTarget.feature(featureID: conversation.featureID)
            var seen = Set<String>()
            for name in [conversation.name, conversation.title, conversation.label] where !name.isEmpty && seen.insert(name).inserted {
                entries.append(Entry(name: name, emoji: conversation.emoji, status: conversation.hudStatus, target: target))
            }
        }
        for assignment in snapshot?.assignments ?? [] where !assignment.title.isEmpty {
            entries.append(Entry(
                name: assignment.title,
                emoji: FirstMateCrewStyle.emoji(forRole: assignment.role),
                status: FirstMateCrewStyle.status(forAssignment: assignment.status),
                target: .agent(featureID: assignment.featureID, assignmentID: assignment.id)
            ))
        }
        self.init(entries: entries)
    }

    var withoutPlainNames: Self { Self(entries: entries, matchesPlainNames: false) }

    var candidates: [FirstMateMentionCandidate] {
        entries.map { FirstMateMentionCandidate(name: $0.name, target: $0.target) }
    }

    func entry(for target: FirstMateMentionTarget) -> Entry? {
        entries.first { $0.target == target }
    }
}

/// An attribute pass after Markdown parsing, modeled on `PaneResponseLinker`:
/// `herdr://first-mate` links and plain names become tinted runs (emoji and
/// name on the status tint) that link to ``FirstMateMention/url(for:)``. The
/// message text itself is never rewritten; the emoji exists only on screen.
enum FirstMateMentionLinker {
    /// A thin space either side pads the tint; a no-break space keeps the
    /// emoji with its name.
    static let edge = "\u{2009}"
    static let joiner = "\u{00A0}"

    struct Span: Equatable {
        var range: NSRange
        var entry: FirstMateMentionCatalog.Entry
    }

    static func link(_ source: AttributedString, catalog: FirstMateMentionCatalog) -> AttributedString {
        let spans = spans(in: source, catalog: catalog)
        guard !spans.isEmpty else { return source }
        var result = source
        let plain = String(source.characters)
        for span in spans.sorted(by: { $0.range.location > $1.range.location }) {
            guard let stringRange = Range(span.range, in: plain),
                  let start = AttributedString.Index(stringRange.lowerBound, within: result),
                  let end = AttributedString.Index(stringRange.upperBound, within: result) else { continue }
            let range = start..<end
            let attributes = result[range].runs.first?.attributes ?? AttributeContainer()
            let name = String(plain[stringRange])
            let prefix = span.entry.emoji.isEmpty ? "" : span.entry.emoji + joiner
            var run = AttributedString(edge + prefix + name + edge, attributes: attributes)
            style(&run, entry: span.entry)
            result.replaceSubrange(range, with: run)
        }
        return result
    }

    /// The runs to draw, in text order: existing mention links first, then
    /// plain names outside code and outside every other link.
    static func spans(in source: AttributedString, catalog: FirstMateMentionCatalog) -> [Span] {
        let plain = String(source.characters)
        var spans: [Span] = []
        var protected: [NSRange] = []
        for (url, range) in source.runs[\.link] {
            guard let url else { continue }
            let nsRange = NSRange(range, in: source)
            protected.append(nsRange)
            guard let target = FirstMateMention.parse(url) else { continue }
            let name = Range(nsRange, in: plain).map { String(plain[$0]) } ?? ""
            let entry = catalog.entry(for: target)
                ?? .init(name: name, emoji: "", status: .unknown, target: target)
            spans.append(Span(range: nsRange, entry: entry))
        }
        if catalog.matchesPlainNames {
            for run in source.runs where run.inlinePresentationIntent?.contains(.code) == true {
                protected.append(NSRange(run.range, in: source))
            }
            for match in FirstMateMention.plainNameMatches(in: plain, candidates: catalog.candidates) {
                let nsRange = NSRange(match.range, in: plain)
                guard !protected.contains(where: { NSIntersectionRange($0, nsRange).length > 0 }),
                      let entry = catalog.entry(for: match.target) else { continue }
                spans.append(Span(range: nsRange, entry: entry))
            }
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }

    private static func style(_ run: inout AttributedString, entry: FirstMateMentionCatalog.Entry) {
        let tint = FirstMateChatStatusStyle.tintColor(for: entry.status)
        run.link = FirstMateMention.url(for: entry.target)
        run.inlinePresentationIntent = .stronglyEmphasized
        run.foregroundColor = HerdrTheme.primaryText
        run.backgroundColor = tint.opacity(0.22)
        run.underlineStyle = nil
    }
}
