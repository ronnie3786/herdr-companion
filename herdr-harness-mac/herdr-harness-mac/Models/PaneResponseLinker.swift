import Foundation

/// Add link attributes after Markdown parsing/styling. The cached Markdown and
/// copied text stay unchanged; IDs in inline code keep their monospace styling.
enum PaneResponseLinker {
    private static let candidates = try! NSRegularExpression(pattern:
        #"[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"`]+|(?<![\p{L}\p{N}_|:/.@+\-])(?:[A-Za-z0-9][A-Za-z0-9_-]{0,63}\|)?w[A-Za-z0-9]+:p[A-Za-z0-9]+(?![\p{L}\p{N}_|:/@+\-]|\.[\p{L}\p{N}_])"#
    )
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}")

    static func link(_ source: AttributedString, catalog: PaneResponseLinkCatalog) -> AttributedString {
        var result = source
        let plain = String(source.characters)
        // Protect every original link label, even when its invalid pane href
        // gets removed: never reinterpret that label as a different target.
        let existing = source.runs.compactMap { run -> (NSRange, URL)? in
            guard let url = run.link else { return nil }
            return (NSRange(run.range, in: source), url)
        }
        for (range, url) in existing where catalog.isPaneURL(url) {
            guard let range = attributedRange(range, plain: plain, text: result) else { continue }
            result[range].link = catalog.target(for: url)?.url
        }
        for match in candidates.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard !existing.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }),
                  let stringRange = Range(match.range, in: plain) else { continue }
            let raw = String(plain[stringRange])
            let candidate = raw.hasPrefix("w") && !raw.contains("://") && !raw.contains("|")
                ? raw : raw.trimmingCharacters(in: trailingPunctuation)
            guard let target = catalog.target(for: candidate),
                  let range = attributedRange(NSRange(location: match.range.location, length: (candidate as NSString).length), plain: plain, text: result) else { continue }
            result[range].link = target.url
        }
        return result
    }

    private static func attributedRange(_ range: NSRange, plain: String, text: AttributedString) -> Range<AttributedString.Index>? {
        guard let stringRange = Range(range, in: plain),
              let start = AttributedString.Index(stringRange.lowerBound, within: text),
              let end = AttributedString.Index(stringRange.upperBound, within: text) else { return nil }
        return start..<end
    }
}
