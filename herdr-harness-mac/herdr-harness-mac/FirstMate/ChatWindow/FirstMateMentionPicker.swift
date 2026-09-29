import SwiftUI

/// Finds the `@query` being typed. The composer publishes no caret, so, like
/// the `$` skills palette, the trigger is the end of the draft.
enum FirstMateMentionTrigger {
    static let maximumQueryLength = 24

    struct Match: Equatable, Sendable {
        /// The query after `@`, as typed.
        var query: String
        /// The `@`'s offset in UTF-16 units, which identifies this trigger.
        var offset: Int
    }

    /// The trailing `@query`: the `@` starts the draft or follows whitespace or
    /// `(`; the query is at most 24 characters, has no newline or `@`, does not
    /// start with a space, and never holds two spaces in a row.
    static func match(in draft: String) -> Match? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex {
            let previous = draft[draft.index(before: at)]
            guard previous.isWhitespace || previous == "(" else { return nil }
        }
        let query = draft[draft.index(after: at)...]
        guard query.count <= maximumQueryLength,
              !query.contains(where: \.isNewline),
              query.first?.isWhitespace != true,
              !query.contains("  ") else { return nil }
        return Match(query: String(query), offset: draft[..<at].utf16.count)
    }

    /// Replaces the trailing `@query` with `@Name ` (the pick plus a space).
    static func insert(_ name: String, into draft: String) -> String {
        guard match(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return draft + "@" + name + " " }
        return String(draft[..<at]) + "@" + name + " "
    }
}

/// One row of the `@` picker.
struct FirstMateMentionOption: Identifiable, Equatable, Sendable {
    enum Section: Hashable, Sendable { case features, crew }

    var candidate: FirstMateMentionCandidate
    var section: Section
    var emoji: String
    var status: FirstMateHudStatus
    /// The feature's status word, or the agent's role.
    var detail: String

    var id: String {
        switch candidate.target {
        case .feature(let featureID): "feature:\(featureID)"
        case .agent(let featureID, let assignmentID): "agent:\(featureID):\(assignmentID)"
        }
    }

    static let featureLimit = 5

    /// The features a draft can tag: a mention carries only a feature id and
    /// opens on the chat's own machine, so only that machine's features. No
    /// machine (nothing can start a feature) means none.
    static func taggableFeatures(_ conversations: [FirstMateConversation], machineID: String?) -> [FirstMateConversation] {
        guard let machineID else { return [] }
        return conversations.filter { $0.machineID == machineID }
    }

    /// The picks to serialize at send. The picks live in view state while the
    /// draft outlives it (the window store keeps it), so a restored draft's
    /// `@Name` tags are recovered from the taggable features and crew. Recorded
    /// picks come first and keep their names.
    static func picksForSend(
        _ picks: [FirstMateMentionCandidate], draft: String,
        features: [FirstMateConversation], crew: [FirstMateAssignment]
    ) -> [FirstMateMentionCandidate] {
        let named = features.flatMap { feature in
            var seen = Set<String>()
            return [feature.name, feature.title, feature.label]
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .map { FirstMateMentionCandidate(name: $0, target: .feature(featureID: feature.featureID)) }
        } + crew.filter { !$0.title.isEmpty }.map {
                FirstMateMentionCandidate(name: $0.title, target: .agent(featureID: $0.featureID, assignmentID: $0.id))
            }
        var result = picks
        for candidate in named where !result.contains(where: { $0.name == candidate.name }) && draft.contains("@" + candidate.name) {
            result.append(candidate)
        }
        return result
    }

    /// Features first (at most five), then the open feature's crew, each
    /// filtered case-insensitively by name.
    static func options(query: String, features: [FirstMateConversation], crew: [FirstMateAssignment]) -> [Self] {
        let needle = query.trimmingCharacters(in: .whitespaces).isEmpty ? "" : query
        func matches(_ names: String...) -> Bool {
            needle.isEmpty || names.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        let featureOptions = features
            .filter { matches($0.name, $0.title, $0.label) }
            .prefix(featureLimit)
            .map { conversation in
                Self(
                    candidate: FirstMateMentionCandidate(name: conversation.name, target: .feature(featureID: conversation.featureID)),
                    section: .features,
                    emoji: conversation.emoji,
                    status: conversation.hudStatus,
                    detail: FirstMateChatStatusStyle.word(for: conversation)
                )
            }
        let crewOptions = crew
            .filter { !$0.title.isEmpty && matches($0.title) }
            .map { assignment in
                Self(
                    candidate: FirstMateMentionCandidate(name: assignment.title, target: .agent(featureID: assignment.featureID, assignmentID: assignment.id)),
                    section: .crew,
                    emoji: FirstMateCrewStyle.emoji(forRole: assignment.role),
                    status: FirstMateCrewStyle.status(forAssignment: assignment.status),
                    detail: assignment.role
                )
            }
        return Array(featureOptions) + crewOptions
    }

    /// ↑/↓ wrap around.
    static func move(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}

/// The `@` picker, floating above the composer from its leading edge.
struct FirstMateMentionPicker: View {
    let options: [FirstMateMentionOption]
    let highlighted: Int
    /// "Crew on {title}".
    let crewTitle: String?
    let pick: (FirstMateMentionOption) -> Void
    let hover: (Int) -> Void

    static let width: CGFloat = 320
    static let maximumHeight: CGFloat = 320
    static let rowHeight: CGFloat = 34
    static let labelHeight: CGFloat = 24
    /// The design's float surface (#191820 at 95% over a 20 pt backdrop
    /// blur). Without the blur, 5% lets the transcript's text show through,
    /// so the native surface is opaque.
    static let floatFill = Color(.sRGB, red: 25 / 255, green: 24 / 255, blue: 32 / 255, opacity: 1)

    private var features: [(Int, FirstMateMentionOption)] {
        options.enumerated().filter { $0.element.section == .features }.map { ($0.offset, $0.element) }
    }

    private var crew: [(Int, FirstMateMentionOption)] {
        options.enumerated().filter { $0.element.section == .crew }.map { ($0.offset, $0.element) }
    }

    /// The picker's height for these options: rows and section labels, at
    /// most 320 pt, then it scrolls.
    static func height(for options: [FirstMateMentionOption]) -> CGFloat {
        let sections = Set(options.map(\.section)).count
        return min(CGFloat(options.count) * rowHeight + CGFloat(sections) * labelHeight + 12, maximumHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !features.isEmpty {
                        label("Features")
                        ForEach(features, id: \.1.id) { index, option in row(option, index: index) }
                    }
                    if !crew.isEmpty {
                        label(crewTitle.map { "Crew on \($0)" } ?? "Crew")
                        ForEach(crew, id: \.1.id) { index, option in row(option, index: index) }
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: highlighted) { _, index in
                guard options.indices.contains(index) else { return }
                proxy.scrollTo(options[index].id)
            }
        }
        .frame(width: Self.width, height: Self.height(for: options))
        .background(Self.floatFill, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HerdrTheme.outline, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 20, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tag a feature or agent")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
            .foregroundStyle(HerdrTheme.tertiaryText)
            .lineLimit(1)
            .padding(.top, 5)
            .padding(.bottom, 4)
            .padding(.horizontal, 8)
            .frame(height: Self.labelHeight, alignment: .bottomLeading)
    }

    private func row(_ option: FirstMateMentionOption, index: Int) -> some View {
        Button { pick(option) } label: {
            HStack(spacing: 9) {
                FirstMateEmojiDisc(emoji: option.emoji, size: 24, edge: FirstMateChatStatusStyle.dotColor(for: option.status))
                Text(option.candidate.name)
                    .herdrFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(option.detail)
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: option.section == .features && !FirstMateChatStatusStyle.isQuiet(option.status) ? .semibold : .medium)
                    .foregroundStyle(option.section == .features ? FirstMateChatStatusStyle.color(for: option.status) : HerdrTheme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .background(index == highlighted ? HerdrTheme.inkFill(0.10) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.herdrPlain)
        .onHover { if $0 { hover(index) } }
        .id(option.id)
        .accessibilityLabel("\(option.candidate.name), \(option.detail)")
        .accessibilityAddTraits(index == highlighted ? .isSelected : [])
    }
}
