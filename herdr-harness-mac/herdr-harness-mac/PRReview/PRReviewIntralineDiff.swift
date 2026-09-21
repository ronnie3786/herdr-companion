import Foundation

/// Deterministic word-level emphasis for an adjacent removed/added line pair.
///
/// The native diff only emphasizes changed words inside a replacement block.
/// Computation is bounded: a long line, a token-heavy line, or a pair beyond
/// the renderer's budget keeps the ordinary whole-line highlighting instead of
/// producing a partial or expensive result.
enum PRReviewIntralineDiff {
    struct Emphasis: Equatable, Sendable {
        var old: [Range<Int>] = []
        var new: [Range<Int>] = []

        var isEmpty: Bool { old.isEmpty && new.isEmpty }
    }

    /// Longer lines fall back to ordinary line highlighting.
    static let maximumUTF16LengthPerLine = 2_000
    /// Token-heavy lines fall back instead of allocating large LCS tables.
    static let maximumTokensPerLine = 256

    /// UTF-16 ranges of the changed words on each side, relative to each line's
    /// text. Returns `nil` when there is nothing to emphasize or the pair is
    /// outside the bounds above.
    static func emphasis(old: String, new: String) -> Emphasis? {
        guard old != new else { return nil }
        guard (old as NSString).length <= maximumUTF16LengthPerLine,
              (new as NSString).length <= maximumUTF16LengthPerLine,
              let oldTokens = tokens(in: old),
              let newTokens = tokens(in: new),
              !oldTokens.isEmpty,
              !newTokens.isEmpty
        else { return nil }

        let matched = matches(old: oldTokens, new: newTokens)
        let emphasis = Emphasis(
            old: changedRanges(in: oldTokens, matched: matched.old),
            new: changedRanges(in: newTokens, matched: matched.new)
        )
        return emphasis.isEmpty ? nil : emphasis
    }

    private enum TokenKind {
        case whitespace
        case word
        case punctuation
    }

    private struct Token {
        let text: String
        let range: Range<Int>
        let isWhitespace: Bool
    }

    /// Splits text into whitespace runs, identifier-like words, and individual
    /// punctuation scalars. Every range is a UTF-16 offset, so it maps directly
    /// onto `NSAttributedString` and `NSString` without splitting a surrogate
    /// pair.
    private static func tokens(in string: String) -> [Token]? {
        var tokens: [Token] = []
        var offset = 0
        var current: (kind: TokenKind, start: Int, length: Int, text: String)?

        func appendCurrent() {
            guard let token = current else { return }
            tokens.append(
                Token(
                    text: token.text,
                    range: token.start..<(token.start + token.length),
                    isWhitespace: token.kind == .whitespace
                )
            )
            current = nil
        }

        for scalar in string.unicodeScalars {
            let width = UTF16.width(scalar)
            let kind: TokenKind
            if scalar.properties.isWhitespace {
                kind = .whitespace
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar.value == 0x5F {
                kind = .word
            } else {
                kind = .punctuation
            }

            if kind == .punctuation {
                appendCurrent()
                tokens.append(
                    Token(text: String(scalar), range: offset..<(offset + width), isWhitespace: false)
                )
            } else if current?.kind == kind, var token = current {
                token.length += width
                token.text.append(String(scalar))
                current = token
            } else {
                appendCurrent()
                current = (kind, offset, width, String(scalar))
            }
            offset += width

            if tokens.count > maximumTokensPerLine {
                return nil
            }
        }
        appendCurrent()
        return tokens.count > maximumTokensPerLine ? nil : tokens
    }

    /// A deterministic longest-common-subsequence of tokens. Ties advance the
    /// old side, so repeated calls always produce the same ranges.
    private static func matches(old: [Token], new: [Token]) -> (old: [Bool], new: [Bool]) {
        let oldCount = old.count
        let newCount = new.count
        var table = [Int](repeating: 0, count: (oldCount + 1) * (newCount + 1))

        func length(_ oldIndex: Int, _ newIndex: Int) -> Int {
            table[oldIndex * (newCount + 1) + newIndex]
        }

        for oldIndex in stride(from: oldCount - 1, through: 0, by: -1) {
            for newIndex in stride(from: newCount - 1, through: 0, by: -1) {
                if old[oldIndex].text == new[newIndex].text {
                    table[oldIndex * (newCount + 1) + newIndex] = length(oldIndex + 1, newIndex + 1) + 1
                } else {
                    table[oldIndex * (newCount + 1) + newIndex] = max(
                        length(oldIndex + 1, newIndex),
                        length(oldIndex, newIndex + 1)
                    )
                }
            }
        }

        var oldMatched = [Bool](repeating: false, count: oldCount)
        var newMatched = [Bool](repeating: false, count: newCount)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldCount, newIndex < newCount {
            if old[oldIndex].text == new[newIndex].text {
                oldMatched[oldIndex] = true
                newMatched[newIndex] = true
                oldIndex += 1
                newIndex += 1
            } else if length(oldIndex + 1, newIndex) >= length(oldIndex, newIndex + 1) {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        return (oldMatched, newMatched)
    }

    /// Merges adjacent unmatched tokens into spans. Whitespace-only changes are
    /// presentation noise, so they are dropped rather than emphasized.
    private static func changedRanges(in tokens: [Token], matched: [Bool]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for (index, token) in tokens.enumerated() where !matched[index] && !token.isWhitespace {
            if let last = ranges.last, token.range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, token.range.upperBound)
            } else {
                ranges.append(token.range)
            }
        }
        return ranges
    }
}
