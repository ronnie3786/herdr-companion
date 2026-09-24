import Foundation

/// One compact block of a First Mate reply, sized for a board column rather
/// than the full-width chat reader. Inline markdown is already resolved.
enum AgentBoardProseBlock: Equatable, Sendable, Identifiable {
    case paragraph(id: Int, text: AttributedString)
    case heading(id: Int, text: AttributedString)
    case quote(id: Int, text: AttributedString)
    case listItem(id: Int, marker: String, depth: Int, text: AttributedString)
    case code(id: Int, text: String)
    case notice(id: Int, text: String)

    var id: Int {
        switch self {
        case let .paragraph(id, _), let .heading(id, _), let .quote(id, _),
             let .listItem(id, _, _, _), let .code(id, _), let .notice(id, _):
            id
        }
    }
}

/// Text preparation shared by Dashboard cards and Agent view columns. Every
/// function is pure and safe to call off the main actor.
enum AgentBoardProse {
    static func plain(_ text: String) -> [AgentBoardProseBlock] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [.paragraph(id: 0, text: AttributedString(trimmed))]
    }

    static func blocks(from markdown: String) -> [AgentBoardProseBlock] {
        var result: [AgentBoardProseBlock] = []
        func next() -> Int { result.count }
        for block in PiMarkdownParser.parse(markdown) {
            switch block {
            case .paragraph(_, let text):
                result.append(.paragraph(id: next(), text: inline(text)))
            case .heading(_, _, let text):
                result.append(.heading(id: next(), text: inline(text)))
            case .quote(_, let text):
                result.append(.quote(id: next(), text: inline(text)))
            case .list(_, let items):
                for item in items {
                    let marker = switch item.marker {
                    case .bullet: "•"
                    case .number(let value): value.hasSuffix(".") || value.hasSuffix(")") ? value : "\(value)."
                    case .task(let done): done ? "☑" : "☐"
                    }
                    result.append(.listItem(id: next(), marker: marker, depth: item.depth, text: inline(item.text)))
                }
            case .code(_, _, let code):
                let trimmed = code.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty { result.append(.code(id: next(), text: trimmed)) }
            case .table(_, let table):
                result.append(.notice(id: next(), text: "Table with \(table.rows.count) row\(table.rows.count == 1 ? "" : "s") — open the full view to read it"))
            case .thematicBreak:
                continue
            }
        }
        return result
    }

    /// Inline markdown (bold, italic, code, links) without block parsing, so
    /// line breaks inside a paragraph survive.
    static func inline(_ text: String) -> AttributedString {
        let source = decodeEntities(text)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }

    /// Single-line-friendly plain text for previews, prompts, and notes: no
    /// markdown punctuation, no entities, whitespace collapsed.
    static func plainText(fromMarkdown markdown: String) -> String {
        var blocks: [String] = []
        for block in PiMarkdownParser.parse(markdown) {
            switch block {
            case .paragraph(_, let text), .heading(_, _, let text), .quote(_, let text):
                blocks.append(String(inline(text).characters))
            case .list(_, let items):
                blocks.append(items.map { collapse(String(inline($0.text).characters)) }.joined(separator: " · "))
            case .code(_, _, let code):
                blocks.append(code)
            case .table(_, let table):
                blocks.append(table.headers.joined(separator: " · "))
            case .thematicBreak:
                continue
            }
        }
        // Blocks read as sentences once their line breaks are gone.
        let sentences = blocks.map(collapse).filter { !$0.isEmpty }
        return sentences.enumerated().map { index, text in
            guard index < sentences.count - 1, let last = text.last, !".!?:;,…".contains(last) else { return text }
            return text + "."
        }.joined(separator: " ")
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Role and status identifiers read as words ("planning_lead" → "planning lead").
    static func readable(_ identifier: String) -> String {
        decodeEntities(identifier).replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let entities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
        ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&"),
    ]

    /// Agent titles and roles sometimes arrive HTML-escaped from their source
    /// profile. `&amp;` is decoded last so "&amp;lt;" stays literal "&lt;".
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var value = text
        for (entity, character) in entities { value = value.replacingOccurrences(of: entity, with: character) }
        return value
    }
}
