import AppKit
import SwiftUI

/// The note editor has one typeface and size. Only emphasis and links travel
/// between AppKit and the existing SwiftUI-attributed persistence/sync format.
@MainActor
enum HerdrNoteTextStyle {
    static let fontSize: CGFloat = 15

    enum Format: String, CaseIterable {
        case bold, italic, underline, strikethrough

        var symbol: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    static func font(bold: Bool = false, italic: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
        return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
    }

    static func attributes(_ source: [NSAttributedString.Key: Any], ink: NSColor) -> [NSAttributedString.Key: Any] {
        let traits = (source[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        var result: [NSAttributedString.Key: Any] = [
            .font: font(bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask)),
            .foregroundColor: ink,
            .paragraphStyle: paragraph,
            .underlineStyle: 0,
            .strikethroughStyle: 0
        ]
        for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle] {
            if let value = source[key] as? Int, value != 0 { result[key] = NSUnderlineStyle.single.rawValue }
        }
        if let link = source[.link] { result[.link] = link }
        return result
    }

    static func normalized(_ source: NSAttributedString, ink: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source.string)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { values, range, _ in
            result.setAttributes(attributes(values, ink: ink), range: range)
        }
        return result
    }

    static func native(_ source: AttributedString, ink: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let context = EnvironmentValues().fontResolutionContext
        for run in source.runs {
            let resolved = run.font?.resolve(in: context)
            let intent = run.inlinePresentationIntent ?? []
            var values: [NSAttributedString.Key: Any] = [
                .font: font(bold: resolved?.isBold == true || intent.contains(.stronglyEmphasized),
                            italic: resolved?.isItalic == true || intent.contains(.emphasized))
            ]
            if run.underlineStyle != nil { values[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strikethroughStyle != nil || intent.contains(.strikethrough) {
                values[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link { values[.link] = link }
            result.append(NSAttributedString(string: String(source[run.range].characters), attributes: attributes(values, ink: ink)))
        }
        return result
    }

    static func rich(_ source: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { values, range, _ in
            var part = AttributedString((source.string as NSString).substring(with: range))
            let traits = (values[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            var font = Font.system(size: fontSize)
            if traits.contains(.boldFontMask) { font = font.bold() }
            if traits.contains(.italicFontMask) { font = font.italic() }
            part.font = font
            if (values[.underlineStyle] as? Int ?? 0) != 0 { part.underlineStyle = .single }
            if (values[.strikethroughStyle] as? Int ?? 0) != 0 { part.strikethroughStyle = .single }
            part.link = values[.link] as? URL ?? (values[.link] as? String).flatMap(URL.init(string:))
            result.append(part)
        }
        return result
    }

    static func contains(_ format: Format, in attributes: [NSAttributedString.Key: Any]) -> Bool {
        let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        switch format {
        case .bold: return traits.contains(.boldFontMask)
        case .italic: return traits.contains(.italicFontMask)
        case .underline: return (attributes[.underlineStyle] as? Int ?? 0) != 0
        case .strikethrough: return (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        }
    }

    static func applying(_ format: Format, enabled: Bool, to values: [NSAttributedString.Key: Any], ink: NSColor) -> [NSAttributedString.Key: Any] {
        var result = attributes(values, ink: ink)
        switch format {
        case .bold, .italic:
            result[.font] = font(bold: format == .bold ? enabled : contains(.bold, in: result),
                                 italic: format == .italic ? enabled : contains(.italic, in: result))
        case .underline: result[.underlineStyle] = enabled ? NSUnderlineStyle.single.rawValue : 0
        case .strikethrough: result[.strikethroughStyle] = enabled ? NSUnderlineStyle.single.rawValue : 0
        }
        return result
    }

    struct MarkdownMatch {
        let range: NSRange
        let contentRange: NSRange
        let format: Format
    }

    /// Only a completed inline token ending at the insertion point converts.
    /// Requiring a boundary avoids treating identifiers, escapes, or unfinished
    /// double-star tokens as italic. Existing/pasted Markdown stays untouched.
    static func markdownMatch(in prefix: String) -> MarkdownMatch? {
        let patterns: [(String, Format)] = [
            (#"(?<![\p{L}\p{N}_*\\`])\*\*([^\s*`](?:[^*`\n]*[^\s*`])?)\*\*$"#, .bold),
            (#"(?<![\p{L}\p{N}_*\\`])\*([^\s*`](?:[^*`\n]*[^\s*`])?)\*$"#, .italic),
            (#"(?<![\p{L}\p{N}_\\`])_([^\s_`](?:[^_`\n]*[^\s_`])?)_$"#, .italic),
            (#"(?<![\p{L}\p{N}~\\`])~~([^\s~`](?:[^~`\n]*[^\s~`])?)~~$"#, .strikethrough)
        ]
        // Leave inline and fenced code literal, including a fence on a prior line.
        guard prefix.filter({ $0 == "`" }).count.isMultiple(of: 2) else { return nil }
        for (pattern, format) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) else { continue }
            return MarkdownMatch(range: match.range, contentRange: match.range(at: 1), format: format)
        }
        return nil
    }
}
