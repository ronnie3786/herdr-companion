import Foundation

/// What Car mode says about one agent, in the one sentence a driver can read.
///
/// The kind is kept alongside the sentence so tests can assert the reason a
/// line was chosen, and so views can style a blocking question differently from
/// a routine progress note. Everything here is derived from fleet state plus a
/// Pi transcript — no network, no model request.
struct CarAgentSummary: Equatable, Sendable {
    enum HeadlineKind: Equatable, Sendable {
        /// The agent asked something and cannot continue without an answer.
        case question(String)
        /// The last turn failed.
        case failed(String)
        /// Context compaction is running; the agent is not taking new work yet.
        case compacting(String)
        /// A tool or step is running right now.
        case activity(String)
        /// Working, with nothing more specific to say yet.
        case working
        /// Ready: the first line of the newest completed answer.
        case answer(String)
        /// Nothing new; echo the last thing that was asked.
        case prompt(String)
        /// Idle with no readable transcript detail.
        case idle
    }

    let kind: HeadlineKind
    let response: String?
    let asked: String?
    let phase: PiConversationPhase
    let isBridgeConnected: Bool

    var headline: String {
        switch kind {
        case let .question(text), let .failed(text), let .compacting(text),
             let .activity(text), let .answer(text), let .prompt(text):
            text
        case .working:
            "Working…"
        case .idle:
            "Idle"
        }
    }

    /// A blocking question is the one headline that changes what you do next,
    /// so views tint it harder than ordinary progress.
    var isQuestion: Bool {
        if case .question = kind { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = kind { return true }
        return false
    }

    /// True when there is something worth hearing a summary of.
    var hasPlayableResponse: Bool {
        guard let response else { return false }
        return !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let empty = CarAgentSummary(
        kind: .idle,
        response: nil,
        asked: nil,
        phase: .idle,
        isBridgeConnected: false
    )

    /// Derives the headline using one fixed priority ladder, most urgent first:
    /// a blocking question, a failure, compaction, running work, the newest
    /// answer, the last prompt, then idle.
    static func derive(
        pane: HerdrPane,
        turns: [PiConversationTurn],
        phase: PiConversationPhase,
        pendingInteractions: [PiPendingInteraction],
        compactionActivity: PiCompactionActivity?,
        bridgeConnected: Bool
    ) -> CarAgentSummary {
        let response = latestCompletedResponse(in: turns)
        let asked = PiLastPrompt.lastUserMessage(in: turns).map(\.text)
        let failedText = latestFailureText(in: turns)

        let kind: HeadlineKind
        if let question = blockingQuestion(
            status: pane.agentStatus,
            interactions: pendingInteractions
        ) {
            kind = .question(question)
        } else if phase == .failed, failedText != nil {
            kind = .failed(failedText ?? "")
        } else if let compactionActivity {
            kind = .compacting(compactionActivity.statusMessage)
        } else if phase == .working {
            kind = workingKind(in: turns)
        } else if let response, let line = CarModeText.firstLine(of: response) {
            kind = .answer(line)
        } else if let asked, let line = CarModeText.oneLine(asked, limit: CarModeText.supportingLimit) {
            kind = .prompt("You asked: \(line)")
        } else {
            kind = .idle
        }

        return CarAgentSummary(
            kind: kind,
            response: response,
            asked: asked,
            phase: phase,
            isBridgeConnected: bridgeConnected
        )
    }

    private static func blockingQuestion(
        status: AgentStatus,
        interactions: [PiPendingInteraction]
    ) -> String? {
        if let interaction = interactions.first {
            let title = CarModeText.oneLine(interaction.title, limit: CarModeText.headlineLimit)
            let message = interaction.message.flatMap {
                CarModeText.oneLine($0, limit: CarModeText.headlineLimit)
            }
            if let title, let message, title != message {
                return "Waiting for your answer: \(title) — \(message)"
            }
            if let title { return "Waiting for your answer: \(title)" }
            if let message { return "Waiting for your answer: \(message)" }
        }
        guard status == .blocked else { return nil }
        return "Waiting for your answer."
    }

    private static func latestCompletedResponse(in turns: [PiConversationTurn]) -> String? {
        for turn in turns.reversed() {
            for item in turn.items.reversed() {
                guard case let .assistant(block) = item,
                      block.status == .complete
                else { continue }
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    private static func latestFailureText(in turns: [PiConversationTurn]) -> String? {
        for turn in turns.reversed() {
            for item in turn.items.reversed() {
                switch item {
                case let .notice(notice):
                    // Notices carry the failure headline, and sometimes only the
                    // detail; prefer whichever one reads like a sentence.
                    let parts = [notice.title, notice.detail ?? ""]
                        .compactMap { CarModeText.firstLine(of: $0) }
                    if !parts.isEmpty {
                        return "Run failed: \(parts.joined(separator: " — "))"
                    }
                case let .assistant(block):
                    if case let .failed(reason) = block.status,
                       let line = reason.flatMap({ CarModeText.firstLine(of: $0) }) {
                        return "Run failed: \(line)"
                    }
                default:
                    continue
                }
            }
        }
        return nil
    }

    private static func workingKind(in turns: [PiConversationTurn]) -> HeadlineKind {
        for turn in turns.reversed() {
            for item in turn.items.reversed() {
                switch item {
                case let .tool(tool) where tool.status == .running || tool.status == .waiting:
                    return .activity(CarModeText.activity(for: tool))
                case let .assistant(block) where block.status == .streaming:
                    if let line = CarModeText.firstLine(of: block.text) {
                        return .activity(line)
                    }
                case .thinking:
                    return .activity("Thinking…")
                default:
                    continue
                }
            }
        }
        return .working
    }
}

/// Flattens markdown-ish agent prose into one glanceable line.
enum CarModeText {
    static let headlineLimit = 96
    static let supportingLimit = 110
    static let detailLimit = 4_000

    /// Turns the opening of a response into one line.
    ///
    /// A leading markdown heading is a label, not a status ("Done", "Summary"),
    /// so it is skipped when there is prose after it; otherwise the whole answer
    /// would read "Done The demo export is ready".
    static func firstLine(of source: String) -> String? {
        let paragraphs = readableParagraphs(in: source)
        for paragraph in paragraphs where !paragraph.isHeading {
            if let line = clamp(paragraph.text, limit: headlineLimit) { return line }
        }
        return paragraphs.lazy.compactMap { clamp($0.text, limit: headlineLimit) }.first
    }

    /// Strips the markdown an agent actually emits, collapses every whitespace
    /// run, and truncates with an ellipsis. Returns nil when nothing readable
    /// is left (an answer that was only a code fence, say).
    static func oneLine(_ source: String, limit: Int) -> String? {
        clamp(flattened(source), limit: limit)
    }

    static func flattened(_ source: String) -> String {
        readableParagraphs(in: source)
            .map(\.text)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clamp(_ text: String, limit: Int) -> String? {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        let cut = collapsed.prefix(max(1, limit - 1))
        // Prefer a word boundary so a truncated line still reads like language.
        if let boundary = cut.lastIndex(where: { $0 == " " }), boundary > cut.startIndex {
            return cut[..<boundary].trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    private struct Paragraph {
        let text: String
        /// The paragraph opened with a markdown heading marker.
        let isHeading: Bool
    }

    /// Splits a response into readable paragraphs: fenced code is dropped,
    /// markdown is stripped, and blank lines end a paragraph.
    private static func readableParagraphs(in source: String) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var current: [String] = []
        var isHeading = false
        var insideFence = false

        func flush() {
            guard !current.isEmpty else { return }
            paragraphs.append(Paragraph(text: current.joined(separator: " "), isHeading: isHeading))
            current.removeAll(keepingCapacity: true)
            isHeading = false
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(rawLine).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                insideFence.toggle()
                flush()
                continue
            }
            if insideFence { continue }
            if trimmed.isEmpty {
                flush()
                continue
            }
            if current.isEmpty, trimmed.hasPrefix("#") { isHeading = true }
            current.append(strippedMarkdown(trimmed))
        }
        flush()
        return paragraphs
    }

    /// Reads a running tool the way a person would say it out loud.
    static func activity(for tool: PiToolInvocation) -> String {
        let presentation = PiToolPresentation(tool: tool)
        let detail = presentation.subtitle.flatMap { oneLine($0, limit: 48) }
        let verb: String = switch presentation.title {
        case "Command": "Running"
        case "Read": "Reading"
        case "Write": "Writing"
        case "Edit": "Editing"
        case "Search": "Searching"
        case "Web": "Fetching"
        default: "Using"
        }
        guard let detail else {
            return presentation.title == "Command" ? "Running a command…" : "\(verb) \(presentation.title)…"
        }
        return "\(verb) \(detail)"
    }

    private static func strippedMarkdown(_ line: String) -> String {
        var text = line
        if text.hasPrefix(">") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        while let first = text.first, "#".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        text = replacingOrderedListMarker(in: text)
        text = replacingLinks(in: text)
        for token in ["**", "__", "`", "*"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        // A table row reads as gibberish in one line; keep the first cell.
        if text.hasPrefix("|") {
            let cells = text.split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.allSatisfy { $0 == "-" || $0 == ":" } }
            text = cells.first ?? ""
        }
        return text
    }

    private static func replacingOrderedListMarker(in text: String) -> String {
        let digits = text.prefix { $0.isNumber }
        guard !digits.isEmpty else { return text }
        let remainder = text.dropFirst(digits.count)
        guard remainder.hasPrefix(". ") || remainder.hasPrefix(") ") else { return text }
        return String(remainder.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    /// `[label](https://…)` becomes `label`; a bare URL keeps its host so a
    /// spoken line does not include a query string.
    private static func replacingLinks(in text: String) -> String {
        var result = ""
        var remainder = Substring(text)
        while let open = remainder.firstIndex(of: "[") {
            result += remainder[..<open]
            let afterOpen = remainder.index(after: open)
            guard let close = remainder[afterOpen...].firstIndex(of: "]"),
                  remainder.index(after: close) < remainder.endIndex,
                  remainder[remainder.index(after: close)] == "(",
                  let end = remainder[afterOpen...].firstIndex(of: ")")
            else {
                result += remainder[open...]
                return result
            }
            result += remainder[afterOpen..<close]
            remainder = remainder[remainder.index(after: end)...]
        }
        return result + remainder
    }
}

/// Picks the agents Car mode shows from the navigator's newest-20 Recents
/// window, keeping the driving surface bounded even when the Agents list shows
/// the full fleet.
enum CarModeSelection {
    static let defaultLimit = CarModePreferences.defaultAgentLimit
    static let allowedLimits = CarModePreferences.allowedAgentLimits

    static func entries(
        workspaces: [HerdrWorkspace],
        machines: [HerdrMachine],
        limit: Int = defaultLimit
    ) -> [AgentSession] {
        let recentPaneIDs = Set(
            SidebarTree.recentChats(
                workspaces: workspaces,
                query: "",
                limit: SidebarRecency.recentsLimit
            ).map(\.id)
        )
        let window = AgentSession.recent(workspaces: workspaces, machines: machines, query: "")
            .filter { recentPaneIDs.contains($0.id) }
        return Array(ranked(window).prefix(max(1, limit)))
    }

    /// Needs-you first, then ready for review, then working, then idle — and
    /// newest first inside each rank, so a fresh result leads its own group.
    static func ranked(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { lhs, rhs in
            let lhsRank = rank(for: lhs.pane.agentStatus)
            let rhsRank = rank(for: rhs.pane.agentStatus)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsDate = lhs.pane.lastActivityAt ?? lhs.pane.firstSeenAt ?? .distantPast
            let rhsDate = rhs.pane.lastActivityAt ?? rhs.pane.firstSeenAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id < rhs.id
        }
    }

    static func rank(for status: AgentStatus) -> Int {
        switch status {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle: 3
        case .unknown: 4
        }
    }
}
