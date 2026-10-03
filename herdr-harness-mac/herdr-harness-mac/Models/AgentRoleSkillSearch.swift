import Foundation

/// Fuzzy, ranked search over a skill catalog. Folded search text is built once
/// per catalog, so each keystroke only scores entries instead of re-folding,
/// re-sorting, and re-filtering hundreds of skills per section.
struct AgentRoleSkillSearch {
    struct Section: Identifiable, Equatable {
        /// A browse letter, or `matchesID` for ranked search results.
        let id: String
        let skills: [AgentRoleSkill]
    }

    static let matchesID = "matches"

    private struct Entry {
        let skill: AgentRoleSkill
        let letter: String
        let name: Folded
        /// The name's letters and digits only, for whole-name and prefix bonuses.
        let compactName: [Unicode.Scalar]
        let words: [ArraySlice<Unicode.Scalar>]
        /// Folded UTF-8, searched with `memmem` because descriptions can be long.
        let description: [UInt8]
    }

    private struct Token {
        let scalars: [Unicode.Scalar]
        let bytes: [UInt8]
    }

    /// Folded scalars plus word starts, so matching never touches `String` APIs.
    private struct Folded {
        let scalars: [Unicode.Scalar]
        let starts: [Bool]

        init(_ value: String) {
            scalars = Array(AgentRoleSkillSearch.fold(value).unicodeScalars)
            var starts = [Bool](repeating: false, count: scalars.count)
            for index in scalars.indices {
                starts[index] = index == 0 || !AgentRoleSkillSearch.isWordScalar(scalars[index - 1])
            }
            self.starts = starts
        }
    }

    let skills: [AgentRoleSkill]
    private let entries: [Entry]

    init(_ skills: [AgentRoleSkill] = []) {
        self.skills = skills
        entries = skills.map { skill in
            let name = Folded(skill.name)
            return Entry(skill: skill, letter: skill.letter, name: name,
                         compactName: name.scalars.filter(Self.isWordScalar),
                         words: name.scalars.split { !Self.isWordScalar($0) },
                         description: Array(Self.fold(skill.description).utf8))
        }.sorted { lhs, rhs in
            if lhs.letter != rhs.letter { return lhs.letter < rhs.letter }
            let order = lhs.skill.name.localizedStandardCompare(rhs.skill.name)
            return order == .orderedSame ? lhs.skill.id < rhs.skill.id : order == .orderedAscending
        }
    }

    /// Alphabetical letter sections when browsing; a single best-first section when searching.
    func sections(query: String, source: String) -> [Section] {
        let candidates = entries.filter { source.isEmpty || $0.skill.source == source }
        // Punctuation separates words, so "swiftui_pro" and "swiftui pro" both find swiftui-pro.
        let tokens: [Token] = Array(Self.fold(query).unicodeScalars).split { !Self.isWordScalar($0) }.map { scalars in
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars)
            return Token(scalars: Array(scalars), bytes: Array(String(text).utf8))
        }
        guard !tokens.isEmpty else {
            var sections: [Section] = []
            var index = candidates.startIndex
            while index < candidates.endIndex {
                let letter = candidates[index].letter
                let end = candidates[index...].firstIndex { $0.letter != letter } ?? candidates.endIndex
                sections.append(Section(id: letter, skills: candidates[index..<end].map(\.skill)))
                index = end
            }
            return sections
        }
        let compact = Array(tokens.map(\.scalars).joined())
        var ranked: [(score: Int, order: Int)] = []
        for (order, entry) in candidates.enumerated() {
            if let score = Self.score(tokens, compact: compact, in: entry) { ranked.append((score, order)) }
        }
        ranked.sort { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        return ranked.isEmpty ? [] : [Section(id: Self.matchesID, skills: ranked.map { candidates[$0.order].skill })]
    }

    // MARK: Scoring

    /// Every token must match the name or description. Nil excludes the skill.
    private static func score(_ tokens: [Token], compact: [Unicode.Scalar], in entry: Entry) -> Int? {
        var total = 0
        for token in tokens {
            guard let tokenScore = Self.score(token, in: entry) else { return nil }
            total += tokenScore
        }
        // A query that spells out the whole name, or its start, outranks scattered matches.
        if entry.compactName == compact { total += 120 } else if entry.compactName.starts(with: compact) { total += 40 }
        return total
    }

    /// Name matches always outscore description matches, so the long
    /// description is only searched when the name has no match at all.
    private static func score(_ token: Token, in entry: Entry) -> Int? {
        let n = token.scalars.count
        let name = fuzzyScore(token.scalars, in: entry.name)
        if let name, name >= 10 * n { return name }
        if let best = [name, typoScore(token.scalars, words: entry.words)].compactMap({ $0 }).max() { return best }
        return descriptionScore(token.bytes, in: entry.description)
    }

    /// Best in-order alignment of the token's characters within the name. Word
    /// starts and consecutive runs earn bonuses and gaps cost points, so
    /// "swui" ranks swiftui-pro above a name that only scatters those letters.
    private static func fuzzyScore(_ token: [Unicode.Scalar], in text: Folded) -> Int? {
        let scalars = text.scalars
        let n = token.count, m = scalars.count
        guard n > 0, n <= m else { return nil }
        // Very short tokens only match runs or word initials; anything else is noise.
        if n <= 2 { return substringScore(token, in: text, weight: 16) ?? initialsScore(token, in: text) }
        let match = 16, wordStart = 12, firstStart = 8, consecutive = 10, gapOpen = 4, gapExtend = 1
        let none = Int.min / 4
        var previous = [Int](repeating: none, count: m)
        var current = [Int](repeating: none, count: m)
        for i in 0..<n {
            // Running best of previous[k] + gapExtend * k over k < j - 1, for an O(n·m) alignment.
            var bestBefore = none
            for j in 0..<m {
                if i > 0, j >= 2, previous[j - 2] > none {
                    bestBefore = max(bestBefore, previous[j - 2] + gapExtend * (j - 2))
                }
                guard scalars[j] == token[i] else { current[j] = none; continue }
                let bonus = match + (text.starts[j] ? wordStart : 0) + (j == 0 ? firstStart : 0)
                if i == 0 {
                    current[j] = bonus - min(j, 12)
                    continue
                }
                var best = none
                if j >= 1, previous[j - 1] > none { best = previous[j - 1] + consecutive }
                if bestBefore > none { best = max(best, bestBefore - gapExtend * (j - 1) - gapOpen) }
                current[j] = best > none ? best + bonus : none
            }
            swap(&previous, &current)
        }
        guard let best = previous.max(), best > none, best >= n * 8 else { return nil }
        return best
    }

    private static func substringScore(_ token: [Unicode.Scalar], in text: Folded, weight: Int) -> Int? {
        let scalars = text.scalars
        let n = token.count
        guard n > 0, n <= scalars.count else { return nil }
        var best: Int?
        for start in 0...(scalars.count - n) where scalars[start] == token[0] {
            guard scalars[start..<(start + n)].elementsEqual(token) else { continue }
            if text.starts[start] { return weight * n + weight }
            // Inside a word, only longer tokens are specific enough to count.
            if n >= 3 { best = max(best ?? 0, weight * n - weight / 2) }
        }
        return best
    }

    private static func descriptionScore(_ token: [UInt8], in text: [UInt8]) -> Int? {
        let n = token.count
        guard n > 0, n <= text.count else { return nil }
        var best: Int?
        text.withUnsafeBytes { haystack in
            token.withUnsafeBytes { needle in
                guard let base = haystack.baseAddress, let pattern = needle.baseAddress else { return }
                var offset = 0
                while offset + n <= haystack.count,
                      let found = memmem(base + offset, haystack.count - offset, pattern, n) {
                    let start = base.distance(to: UnsafeRawPointer(found))
                    if start == 0 || !isWordByte(haystack[start - 1]) {
                        best = 3 * n + 3
                        return
                    }
                    // Inside a word, only longer tokens are specific enough to count.
                    if n >= 3 { best = 3 * n - 1 }
                    offset = start + 1
                }
            }
        }
        return best
    }

    /// Non-ASCII bytes count as letters; folding has already removed most accents.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 0x80 || (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func initialsScore(_ token: [Unicode.Scalar], in text: Folded) -> Int? {
        var index = 0
        for (position, scalar) in text.scalars.enumerated() where text.starts[position] && scalar == token[index] {
            index += 1
            if index == token.count { return 14 * token.count }
        }
        return nil
    }

    /// Small typos (a swapped, missing, extra, or wrong letter) in a word or the start of one.
    private static func typoScore(_ token: [Unicode.Scalar], words: [ArraySlice<Unicode.Scalar>]) -> Int? {
        let n = token.count
        guard n >= 4 else { return nil }
        let allowed = n >= 8 ? 2 : 1
        var best: Int?
        for word in words where word.count >= n - allowed {
            // The word itself, or its start for a partly typed word.
            for length in [n - 1, n, n + 1, word.count] where length > 0 && length <= word.count {
                let distance = editDistance(token, word.prefix(length), limit: allowed)
                if distance <= allowed { best = max(best ?? 0, 10 * n - 12 * distance) }
            }
        }
        return best
    }

    /// Optimal string alignment distance, abandoned once every path exceeds `limit`.
    private static func editDistance(_ a: [Unicode.Scalar], _ word: ArraySlice<Unicode.Scalar>, limit: Int) -> Int {
        guard !a.isEmpty, !word.isEmpty, abs(a.count - word.count) <= limit else { return max(a.count, word.count) }
        let b = Array(word)
        var older = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, older[j - 2] + 1) }
                current[j] = value
                rowMinimum = min(rowMinimum, value)
            }
            if rowMinimum > limit { return limit + 1 }
            (older, previous, current) = (previous, current, older)
        }
        return previous[b.count]
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}
