import Foundation

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
