import os
import SwiftUI

struct PiMarkdownText: View {
    let source: String
    @Environment(\.saveChatQuote) private var saveQuote
    @Environment(\.paneResponseLinkCatalog) private var paneLinks
    @Environment(\.detectsPaneResponseLinks) private var detectsPaneLinks
    @Environment(\.chatProsePalette) private var palette
    let font: Font
    let cacheRenderedText: Bool
    var inlineCodeFont: Font? = nil
    var inlineCodeColor: Color? = nil
    /// The chip behind inline code (ink 8%); nil leaves code unboxed.
    var inlineCodeBackground: Color? = nil
    /// Bold runs: semibold in full ink, like MonoCode's `.md b`.
    var strongColor: Color? = nil
    let id: String?
    let cacheKeyLength: Int?

    init(
        _ source: String,
        font: Font = .body,
        cacheRenderedText: Bool = true,
        inlineCodeFont: Font? = nil,
        inlineCodeColor: Color? = nil,
        inlineCodeBackground: Color? = nil,
        strongColor: Color? = nil,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) {
        self.source = source
        self.font = font
        self.cacheRenderedText = cacheRenderedText
        self.inlineCodeFont = inlineCodeFont
        self.inlineCodeColor = inlineCodeColor
        self.inlineCodeBackground = inlineCodeBackground
        self.strongColor = strongColor
        self.id = id
        self.cacheKeyLength = cacheKeyLength
    }

    var body: some View {
        let rendered: AttributedString
        if cacheRenderedText {
            rendered = PiMarkdownInlineCache.shared.rendered(
                source,
                id: id,
                cacheKeyLength: cacheKeyLength
            )
        } else {
            rendered = Self.render(source)
        }

        let styled: AttributedString
        if let inlineCodeFont, let inlineCodeColor {
            let strongFont = strongColor == nil ? nil : font.weight(.semibold)
            styled = cacheRenderedText
                ? PiMarkdownInlineCache.shared.styled(
                    rendered,
                    source: source,
                    font: inlineCodeFont,
                    color: inlineCodeColor,
                    background: inlineCodeBackground,
                    strongFont: strongFont,
                    strongColor: strongColor,
                    id: id,
                    cacheKeyLength: cacheKeyLength
                )
                : Self.applyingInlineCodeStyle(
                    rendered,
                    font: inlineCodeFont,
                    color: inlineCodeColor,
                    background: inlineCodeBackground,
                    strongFont: strongFont,
                    strongColor: strongColor
                )
        } else {
            styled = rendered
        }

        let linked: AttributedString
        if detectsPaneLinks, let paneLinks {
            linked = PaneResponseLinker.link(styled, catalog: paneLinks)
        } else {
            linked = styled
        }
        return Group {
            if saveQuote != nil {
                ChatSelectableText(text: linked, font: font, lineSpacing: nil)
            } else {
                Text(linked)
                    .font(font)
                    .foregroundStyle(palette.text)
                    .tint(palette.accent)
                    .textSelection(.enabled)
            }
        }
    }

    static func render(_ source: String) -> AttributedString {
        PiMarkdownInlineCache.render(source)
    }

    static func applyingInlineCodeStyle(
        _ source: AttributedString,
        font: Font,
        color: Color,
        background: Color? = nil,
        strongFont: Font? = nil,
        strongColor: Color? = nil
    ) -> AttributedString {
        var result = source
        var codeRanges: [Range<AttributedString.Index>] = []
        var strongRanges: [Range<AttributedString.Index>] = []
        for run in result.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                codeRanges.append(run.range)
            } else if intent.contains(.stronglyEmphasized) {
                strongRanges.append(run.range)
            }
        }
        for range in codeRanges {
            result[range].font = font
            result[range].foregroundColor = color
            if let background { result[range].backgroundColor = background }
        }
        if let strongColor {
            for range in strongRanges {
                if let strongFont { result[range].font = strongFont }
                result[range].foregroundColor = strongColor
            }
        }
        return result
    }
}

final class PiMarkdownInlineCache: @unchecked Sendable {
    static let shared = PiMarkdownInlineCache()

    final class Entry {
        let value: AttributedString

        init(value: AttributedString) {
            self.value = value
        }
    }

    private let renderedCache = NSCache<NSString, Entry>()
    private let styledCache = NSCache<NSString, Entry>()
    private let streamingKeysLock = OSAllocatedUnfairLock<[String: Set<String>]>(initialState: [:])

    private init() {
        renderedCache.countLimit = 2_048
        renderedCache.totalCostLimit = 16 * 1_024 * 1_024
        styledCache.countLimit = 2_048
        styledCache.totalCostLimit = 16 * 1_024 * 1_024
    }

    func markStreamingEntry(id: String, length: Int) {
        streamingKeysLock.withLock { keys in
            keys[id, default: []].insert(Self.identityKey(id: id, length: length))
        }
    }

    func evictStreaming(id: String) {
        let keys = streamingKeysLock.withLock { $0.removeValue(forKey: id) } ?? []
        for key in keys {
            renderedCache.removeObject(forKey: key as NSString)
            styledCache.removeObject(forKey: key as NSString)
        }
    }

    func rendered(
        _ source: String,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) -> AttributedString {
        let key = Self.renderedKey(for: source, id: id, cacheKeyLength: cacheKeyLength)
        if let cached = renderedCache.object(forKey: key as NSString) {
            return cached.value
        }
        let value = Self.render(source)
        renderedCache.setObject(Entry(value: value), forKey: key as NSString, cost: source.utf8.count)
        return value
    }

    func styled(
        _ rendered: AttributedString,
        source: String,
        font: Font,
        color: Color,
        background: Color? = nil,
        strongFont: Font? = nil,
        strongColor: Color? = nil,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) -> AttributedString {
        let key = Self.styledKey(
            for: source,
            font: font,
            color: color,
            background: background,
            strongFont: strongFont,
            strongColor: strongColor,
            id: id,
            cacheKeyLength: cacheKeyLength
        )
        if let cached = styledCache.object(forKey: key as NSString) {
            recordStyledStreamingKey(key, id: id, cacheKeyLength: cacheKeyLength ?? source.utf8.count)
            return cached.value
        }
        let value = PiMarkdownText.applyingInlineCodeStyle(
            rendered,
            font: font,
            color: color,
            background: background,
            strongFont: strongFont,
            strongColor: strongColor
        )
        styledCache.setObject(Entry(value: value), forKey: key as NSString, cost: source.utf8.count)
        recordStyledStreamingKey(key, id: id, cacheKeyLength: cacheKeyLength ?? source.utf8.count)
        return value
    }

    func renderedEntry(
        for source: String,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) -> Entry? {
        renderedCache.object(forKey: Self.renderedKey(for: source, id: id, cacheKeyLength: cacheKeyLength) as NSString)
    }

    func styledEntry(
        for source: String,
        font: Font,
        color: Color,
        id: String? = nil,
        cacheKeyLength: Int? = nil
    ) -> Entry? {
        styledCache.object(
            forKey: Self.styledKey(
                for: source,
                font: font,
                color: color,
                id: id,
                cacheKeyLength: cacheKeyLength
            ) as NSString
        )
    }

    static func render(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }

    private func recordStyledStreamingKey(_ key: String, id: String?, cacheKeyLength: Int) {
        guard let id else { return }
        streamingKeysLock.withLock { keys in
            guard keys[id]?.contains(Self.identityKey(id: id, length: cacheKeyLength)) == true else { return }
            keys[id, default: []].insert(key)
        }
    }

    private static func renderedKey(for source: String, id: String?, cacheKeyLength: Int?) -> String {
        if let id {
            identityKey(id: id, length: cacheKeyLength ?? source.utf8.count)
        } else {
            source
        }
    }

    private static func identityKey(id: String, length: Int) -> String {
        "identity\u{0}\(id)\u{0}\(length)"
    }

    private static func styledKey(
        for source: String,
        font: Font,
        color: Color,
        background: Color? = nil,
        strongFont: Font? = nil,
        strongColor: Color? = nil,
        id: String?,
        cacheKeyLength: Int?
    ) -> String {
        var hasher = Hasher()
        hasher.combine(font)
        hasher.combine(color)
        hasher.combine(background)
        hasher.combine(strongFont)
        hasher.combine(strongColor)
        let baseKey: String
        if let id {
            baseKey = identityKey(id: id, length: cacheKeyLength ?? source.utf8.count)
        } else {
            baseKey = source
        }
        return "\(baseKey)\u{0}style\u{0}\(hasher.finalize())"
    }
}
