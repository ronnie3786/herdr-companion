import Foundation

/// An at-a-glance outcome, separate from the retained ticket/implementation brief.
/// Prefer a named goal or objective. Legacy briefs use their first prose paragraph;
/// metadata, acceptance checklists, source links and code are not a goal.
enum FirstMateGoalSummary {
    static func text(goal: String, title: String) -> String {
        let lines = goal.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraphs: [(explicit: Bool, text: String)] = []
        var current: [String] = []
        var explicit = false
        var inFence = false
        func flush() {
            if !current.isEmpty { paragraphs.append((explicit, current.joined(separator: " "))) }
            current = []
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { flush(); inFence.toggle(); continue }
            if inFence { continue }
            if line.isEmpty { flush(); continue }
            let plain = FirstMateChatPreview.plainText(line)
            let heading = plain.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).lowercased()
            if ["goal", "objective", "outcome", "desired outcome", "user goal"].contains(heading) {
                flush(); explicit = true; continue
            }
            if line.hasPrefix("#") { flush(); explicit = false; continue }
            if plain.range(of: #"(?i)^(goal|objective|outcome):\s*"#, options: .regularExpression) != nil {
                flush(); explicit = true
                current.append(plain.replacingOccurrences(of: #"(?i)^(goal|objective|outcome):\s*"#, with: "", options: .regularExpression))
                continue
            }
            if line.range(of: #"^([-*+] |\d+[.)] |\||https?://)"#, options: .regularExpression) != nil
                || plain.range(of: #"(?i)^(ticket|jira|issue|status|priority|assignee|acceptance criteria|implementation|references|links|repository|branch):"#, options: .regularExpression) != nil {
                flush(); continue
            }
            current.append(plain)
        }
        flush()
        let candidates = paragraphs.filter(\.explicit) + paragraphs.filter { !$0.explicit }
        for candidate in candidates {
            let prose = candidate.text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            var sentences: [String] = []
            prose.enumerateSubstrings(in: prose.startIndex..<prose.endIndex, options: .bySentences) { sentence, _, _, stop in
                if let sentence {
                    let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty { sentences.append(clean) }
                }
                if sentences.count == 2 { stop = true }
            }
            let summary = sentences.joined(separator: " ")
            if !summary.isEmpty, summary.count <= 400 { return punctuated(summary) }
        }
        let fallback = FirstMateChatPreview.plainText(title)
            .replacingOccurrences(of: #"^[A-Z][A-Z0-9]+-\d+\s*[:—–-]?\s*"#, with: "", options: .regularExpression)
        return punctuated(fallback.isEmpty ? "Define the outcome for this feature" : fallback)
    }

    private static func punctuated(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }
}
