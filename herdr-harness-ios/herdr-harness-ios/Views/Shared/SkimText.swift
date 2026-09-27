import SwiftUI

/// Skim tokens as one wrapping `Text`. Anchors are inline links to
/// `herdr-skim://anchor/<id>` in the surrounding text color with a dotted
/// underline at 55% (never link blue); the open one gets a solid accent
/// underline and a light accent tint. Taps route through `openURL`.
enum SkimText {
    static let urlScheme = "herdr-skim"

    struct Mention: Equatable, Sendable {
        let id: String
        let phrase: String
    }

    static func url(anchorID: String) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "anchor"
        components.path = "/" + anchorID
        return components.url
    }

    static func anchorID(in url: URL) -> String? {
        guard url.scheme == urlScheme, url.host() == "anchor" else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty || id == "/" ? nil : id
    }

    /// Top-level anchors in reading order, each once (one accessibility action apiece).
    static func mentions(in tokens: [SkimToken]) -> [Mention] {
        var seen: Set<String> = []
        return tokens.compactMap { token in
            guard case .anchor(let id, let label, _) = token, seen.insert(id).inserted else { return nil }
            return Mention(id: id, phrase: label.map(\.plainText).joined())
        }
    }

    static func attributed(
        _ tokens: [SkimToken],
        style: SkimStyle,
        color: Color,
        openAnchorID: String? = nil
    ) -> AttributedString {
        tokens.reduce(into: AttributedString()) { result, token in
            result.append(piece(token, style: style, color: color, openAnchorID: openAnchorID, inAnchor: false))
        }
    }

    private static func piece(
        _ token: SkimToken,
        style: SkimStyle,
        color: Color,
        openAnchorID: String?,
        inAnchor: Bool
    ) -> AttributedString {
        switch token {
        case .text(let value):
            var text = AttributedString(value)
            text.swiftUI.foregroundColor = color
            return text
        case .code(let value):
            var code = AttributedString(value)
            if let font = style.inlineCodeFont {
                code.swiftUI.font = font
            } else {
                code.inlinePresentationIntent = .code
            }
            code.swiftUI.foregroundColor = style.inlineCodeColor ?? color
            return code
        case .anchor(let id, let label, _):
            var phrase = label.reduce(into: AttributedString()) { result, part in
                result.append(piece(part, style: style, color: color, openAnchorID: openAnchorID, inAnchor: true))
            }
            // A nested anchor reads as its label; the outer link owns the tap.
            guard !inAnchor, let link = Self.url(anchorID: id) else { return phrase }
            let isOpen = id == openAnchorID
            phrase.link = link
            phrase.swiftUI.underlineStyle = Text.LineStyle(
                pattern: isOpen ? .solid : .dot,
                color: isOpen ? style.accent : color.opacity(0.55)
            )
            if isOpen {
                phrase.swiftUI.backgroundColor = style.accent.opacity(0.17)
            }
            return phrase
        }
    }
}
