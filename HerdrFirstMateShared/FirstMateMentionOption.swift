import Foundation

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
