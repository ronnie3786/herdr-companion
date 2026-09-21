import SwiftUI

/// Renders an agent's answer as markdown inside Car mode.
///
/// It reuses the app's parser (`PiMarkdownParser`) and inline styling
/// (`PiMarkdownText`), but keeps its own typography: everything is sized from
/// the Car mode scale factor so the prose stays legible from a mounted phone,
/// and nothing here enables text selection — a selectable text view adds editing
/// affordances that a driving surface must not have.
struct CarMarkdownView: View {
    let source: String
    let scale: CGFloat
    let isWide: Bool

    private let blocks: [PiMarkdownBlock]

    init(source: String, scale: CGFloat, isWide: Bool) {
        self.source = source
        self.scale = scale
        self.isWide = isWide
        blocks = CarMarkdownDocumentCache.shared.blocks(for: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CarModeMetrics.scaled(isWide ? 10 : 12, by: scale)) {
            ForEach(blocks) { block in
                CarMarkdownBlockView(block: block, scale: scale, isWide: isWide)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
/// Inline styling for Car mode prose. Separate from the view so the marker
/// stripping and intent mapping stay testable without a rendered hierarchy.
enum CarMarkdownText {
    /// Bold, italic, inline code, and links come from the same inline markdown
    /// renderer the chat uses, so an answer looks the same in both places.
    static func inline(_ text: String, size: CGFloat, scale: CGFloat) -> AttributedString {
        let rendered = PiMarkdownText.render(normalized(text))
        return PiMarkdownText.applyingInlineCodeStyle(
            rendered,
            font: .system(size: size * scale * 0.94, design: .monospaced),
            color: HerdrTheme.code
        )
    }

    /// What a reader actually sees, with every markdown marker resolved away.
    /// Used by tests, accessibility labels, and anything else that needs a plain
    /// rendering of a block.
    static func plainText(_ text: String) -> String {
        String(inline(text, size: 1, scale: 1).characters)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Agent prose wraps at its own column width, so a paragraph arrives with
    /// soft line breaks that are not meaningful to a phone-width reader. Blocks
    /// are already split on blank lines, so collapsing what is left lets the
    /// text reflow instead of showing ragged mid-sentence breaks.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// One markdown block, sized for a car.
private struct CarMarkdownBlockView: View {
    let block: PiMarkdownBlock
    let scale: CGFloat
    let isWide: Bool

    var body: some View {
        switch block {
        case let .paragraph(_, text):
            prose(text, size: bodySize, weight: .regular)

        case let .heading(_, level, text):
            prose(text, size: headingSize(level), weight: level <= 2 ? .bold : .semibold)
                .accessibilityAddTraits(.isHeader)

        case let .code(_, language, code):
            codeBlock(language: language, code: code)

        case let .list(_, items):
            list(items)

        case let .quote(_, text):
            HStack(alignment: .top, spacing: CarModeMetrics.scaled(10, by: scale)) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(HerdrTheme.mauve.opacity(0.72))
                    .frame(width: CarModeMetrics.scaled(3, by: scale))
                    .accessibilityHidden(true)
                prose(text, size: bodySize, weight: .regular, color: HerdrTheme.mist)
            }

        case let .table(_, table):
            tableView(table)

        case .thematicBreak:
            Rectangle()
                .fill(HerdrTheme.surface.opacity(0.82))
                .frame(height: 1)
                .padding(.vertical, CarModeMetrics.scaled(4, by: scale))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Prose

    private func prose(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight,
        color: Color = HerdrTheme.text
    ) -> some View {
        Text(styledInline(text, size: size))
            .font(.system(size: size * scale, weight: weight))
            .foregroundStyle(color)
            .lineSpacing(CarModeMetrics.scaled(3, by: scale))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodySize: CGFloat { isWide ? 18 : 20 }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 26
        case 2: 23
        case 3: 21
        case 4: 19
        case 5: 17.5
        default: 17.5
        }
    }

    // MARK: - Code

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").lowercased())
                    .font(.system(size: 12.5 * scale, weight: .bold))
                    .foregroundStyle(HerdrTheme.code.opacity(0.8))
                Spacer(minLength: 8)
                Text("\(code.split(separator: "\n").count) lines")
                    .font(.system(size: 12.5 * scale, weight: .medium))
                    .foregroundStyle(HerdrTheme.mist)
            }
            .padding(.horizontal, CarModeMetrics.scaled(12, by: scale))
            .padding(.vertical, CarModeMetrics.scaled(7, by: scale))
            .background(HerdrTheme.ink.opacity(0.85))

            Rectangle()
                .fill(HerdrTheme.surface.opacity(0.5))
                .frame(height: 1)

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 15.5 * scale, design: .monospaced))
                    .foregroundStyle(HerdrTheme.text)
                    .lineSpacing(CarModeMetrics.scaled(4, by: scale))
                    .padding(CarModeMetrics.scaled(12, by: scale))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.visible)
        }
        .background(HerdrTheme.crust, in: .rect(cornerRadius: CarModeMetrics.scaled(12, by: scale)))
        .overlay {
            RoundedRectangle(cornerRadius: CarModeMetrics.scaled(12, by: scale))
                .strokeBorder(HerdrTheme.surface.opacity(0.5), lineWidth: 1)
        }
        .composerLayoutMeasurement(id: "car-md-code", label: "Code block")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code block\(language.map { ", \($0)" } ?? "")")
        .accessibilityValue(code)
    }

    // MARK: - Lists

    private func list(_ items: [PiMarkdownListItem]) -> some View {
        VStack(alignment: .leading, spacing: CarModeMetrics.scaled(7, by: scale)) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: CarModeMetrics.scaled(9, by: scale)) {
                    marker(for: item.marker)
                        .frame(width: CarModeMetrics.scaled(24, by: scale), alignment: .trailing)
                        .padding(.top, CarModeMetrics.scaled(2, by: scale))
                        .accessibilityHidden(true)
                    prose(item.text, size: isWide ? 17.5 : 19, weight: .regular)
                }
                .padding(.leading, CGFloat(min(item.depth, 6)) * CarModeMetrics.scaled(16, by: scale))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(for: item))
            }
        }
    }

    @ViewBuilder
    private func marker(for marker: PiMarkdownListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            Text("•")
                .font(.system(size: 19 * scale, weight: .bold))
                .foregroundStyle(HerdrTheme.muted)
        case let .number(number):
            Text("\(number).")
                .font(.system(size: 17 * scale, weight: .semibold).monospacedDigit())
                .foregroundStyle(HerdrTheme.muted)
        case let .task(isCompleted):
            Image(systemName: isCompleted ? "checkmark.square.fill" : "square")
                .font(.system(size: 17 * scale, weight: .semibold))
                .foregroundStyle(isCompleted ? HerdrTheme.success : HerdrTheme.muted)
        }
    }

    private func accessibilityLabel(for item: PiMarkdownListItem) -> String {
        // The label must be what the row *says*, not the markdown source: VoiceOver
        // reading "asterisk winter reading asterisk" is worse than silence.
        let text = CarMarkdownText.plainText(item.text)
        switch item.marker {
        case .bullet:
            return "Bullet, \(text)"
        case let .number(number):
            return "Item \(number), \(text)"
        case let .task(isCompleted):
            return "\(isCompleted ? "Completed" : "Incomplete") task, \(text)"
        }
    }

    // MARK: - Tables

    private func tableView(_ table: PiMarkdownTable) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(table.headers, columnAlignments: table.alignments, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    tableRow(cells, columnAlignments: table.alignments, isHeader: false)
                }
            }
        }
        .scrollIndicators(.visible)
        .background(HerdrTheme.ink.opacity(0.5), in: .rect(cornerRadius: CarModeMetrics.scaled(12, by: scale)))
        .overlay {
            RoundedRectangle(cornerRadius: CarModeMetrics.scaled(12, by: scale))
                .strokeBorder(HerdrTheme.surface.opacity(0.78), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table with \(table.headers.count) columns and \(table.rows.count) rows")
    }

    private func tableRow(
        _ cells: [String],
        columnAlignments: [PiMarkdownTable.ColumnAlignment],
        isHeader: Bool
    ) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { columnIndex, cell in
                Text(styledInline(cell, size: cellSize(isHeader: isHeader)))
                    .font(.system(
                        size: cellSize(isHeader: isHeader) * scale,
                        weight: isHeader ? .bold : .regular
                    ))
                    .foregroundStyle(HerdrTheme.text)
                    .multilineTextAlignment(textAlignment(for: columnIndex, in: columnAlignments))
                    .frame(
                        minWidth: CarModeMetrics.scaled(112, by: scale),
                        idealWidth: CarModeMetrics.scaled(150, by: scale),
                        maxWidth: CarModeMetrics.scaled(230, by: scale),
                        alignment: frameAlignment(for: columnIndex, in: columnAlignments)
                    )
                    .padding(.horizontal, CarModeMetrics.scaled(11, by: scale))
                    .padding(.vertical, CarModeMetrics.scaled(isHeader ? 10 : 9, by: scale))
                    .background(isHeader ? HerdrTheme.elevated.opacity(0.75) : Color.clear)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(HerdrTheme.surface.opacity(0.48))
                            .frame(width: 1)
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(HerdrTheme.surface.opacity(0.48))
                            .frame(height: 1)
                    }
            }
        }
    }

    private func cellSize(isHeader: Bool) -> CGFloat {
        isHeader ? 16 : 15.5
    }

    private func textAlignment(
        for columnIndex: Int,
        in alignments: [PiMarkdownTable.ColumnAlignment]
    ) -> TextAlignment {
        guard columnIndex < alignments.count else { return .leading }
        switch alignments[columnIndex] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(
        for columnIndex: Int,
        in alignments: [PiMarkdownTable.ColumnAlignment]
    ) -> Alignment {
        guard columnIndex < alignments.count else { return .leading }
        switch alignments[columnIndex] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    // MARK: - Inline styling

    /// Bold, italic, inline code, and links come from the same inline markdown
    /// renderer the chat uses, so an answer looks the same in both places.
    private func styledInline(_ text: String, size: CGFloat) -> AttributedString {
        CarMarkdownText.inline(text, size: size, scale: scale)
    }
}

/// Parsing is cached because the detail view is rebuilt on every poll (five
/// seconds) while the answer itself rarely changes.
private final class CarMarkdownDocumentCache: @unchecked Sendable {
    static let shared = CarMarkdownDocumentCache()

    private final class Entry {
        let blocks: [PiMarkdownBlock]

        init(blocks: [PiMarkdownBlock]) {
            self.blocks = blocks
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.countLimit = 64
        cache.totalCostLimit = 1 * 1_024 * 1_024
    }

    func blocks(for source: String) -> [PiMarkdownBlock] {
        let key = source as NSString
        if let cached = cache.object(forKey: key) {
            return cached.blocks
        }
        let blocks = PiMarkdownParser.parse(source)
        cache.setObject(Entry(blocks: blocks), forKey: key, cost: source.utf8.count)
        return blocks
    }
}
