import SwiftUI

struct WatcherSummaryView: View {
    var markup: String
    var schedule: String
    var tokens: [PiJSONValue]? = nil
    /// Prose size and CSS line height: every line is `size × lineHeight` tall, chips included.
    var size: CGFloat = 12.5
    var lineHeight: CGFloat = 2
    private var runs: [WatchersSummary.Run] { tokens.map(WatchersSummary.parseTokens) ?? WatchersSummary.parse(markup, schedule: schedule) }
    var body: some View {
        WatcherSummaryLayout(spacing: size * 0.28, line: size * lineHeight, baseline: WatchersStyle.baseline(size, lineHeight)) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run {
                case .word(let text): Text(text).font(.system(size: size)).foregroundStyle(HerdrTheme.proseText)
                case .chip(let kind, let value, let punctuation): WatcherChip(kind: kind, value: value, punctuation: punctuation, proseSize: size)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchersSummary.accessibilityText(runs))
    }
}
/// Prose that wraps by word into fixed-height lines, like CSS inline text:
/// each line box is `line` tall and every run's first baseline sits at
/// `baseline` inside it, so lines with and without chips keep one rhythm.
struct WatcherSummaryLayout: Layout {
    var spacing: CGFloat = 3.5
    var line: CGFloat = 25
    var baseline: CGFloat = 17
    private func rows(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []; var row: [Int] = []; var used: CGFloat = 0
        for index in subviews.indices {
            let w = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).width
            if !row.isEmpty, used + spacing + w > width { rows.append(row); row = []; used = 0 }
            used += (row.isEmpty ? 0 : spacing) + w; row.append(index)
        }
        if !row.isEmpty { rows.append(row) }; return rows
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: CGFloat(rows(subviews, width: width).count) * line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (number, row) in rows(subviews, width: bounds.width).enumerated() {
            var x = bounds.minX
            for index in row {
                let d = subviews[index].dimensions(in: ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + CGFloat(number) * line + baseline - d[.firstTextBaseline]), proposal: ProposedViewSize(width: d.width, height: d.height))
                x += d.width + spacing
            }
        }
    }
}
/// The prototype's smart chip: 20pt tall, 6pt radius, a colored mark and a
/// tinted wash for schedule, skill, agent and script; neutral for the rest.
/// Trailing punctuation stays glued to the chip, so it never starts a line.
struct WatcherChip: View {
    let kind: String
    let value: String
    var punctuation = ""
    var proseSize: CGFloat = 12.5
    private static let height: CGFloat = 20
    private var font: NSFont { kind == "script" ? .monospacedSystemFont(ofSize: 10.5, weight: .medium) : .systemFont(ofSize: 11.5, weight: WatchersStyle.w550) }
    private var text: Color {
        switch kind {
        case "time": WatchersStyle.hex(0xF2E0BC)
        case "skill", "agent": WatchersStyle.hex(0xE2DFFF)
        case "script": WatchersStyle.hex(0xD3EEE2)
        default: HerdrTheme.primaryText
        }
    }
    private var fill: Color {
        switch kind {
        case "time": WatchersStyle.amber.opacity(0.11)
        case "skill": HerdrTheme.accent.opacity(0.13)
        case "agent": HerdrTheme.accent.opacity(0.07)
        case "script": WatchersStyle.mint.opacity(0.10)
        default: HerdrTheme.chipFill
        }
    }
    private var stroke: Color {
        switch kind {
        case "time": WatchersStyle.amber.opacity(0.30)
        case "skill": HerdrTheme.accent.opacity(0.32)
        case "script": WatchersStyle.mint.opacity(0.28)
        default: HerdrTheme.outline
        }
    }
    private var spokenKind: String { switch kind { case "gh": "GitHub"; case "pc": "Computer"; case "slack": "Slack channel"; case "time": "Schedule"; default: kind.capitalized } }
    var body: some View {
        let chipBaseline = (Self.height - (font.ascender - font.descender)) / 2 + font.ascender
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(spacing: 4) {
                mark
                Text(value).font(Font(font as CTFont)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(text)
            .padding(.leading, kind == "agent" ? 2 : 4).padding(.trailing, 6)
            .frame(height: Self.height)
            .background(fill, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(stroke, lineWidth: 1))
            .padding(.horizontal, 1)
            .alignmentGuide(.firstTextBaseline) { _ in chipBaseline }
            if !punctuation.isEmpty { Text(punctuation).font(.system(size: proseSize)).foregroundStyle(HerdrTheme.proseText) }
        }
        .alignmentGuide(.firstTextBaseline) { _ in chipBaseline }
        .help("\(spokenKind): \(value)")
        .accessibilityElement(children: .ignore).accessibilityLabel("\(spokenKind) \(value)\(punctuation)")
    }
    @ViewBuilder private var mark: some View {
        switch kind {
        case "slack", "gh": Image(kind == "slack" ? "Watcher-slack" : "Watcher-github").resizable().scaledToFit().frame(width: 12, height: 12)
        case "skill": Text("🤖").font(.system(size: 11)).frame(width: 13)
        case "agent": WatcherMiniFace(size: 16)
        case "script": WatcherTerminalGlyph(size: 12).foregroundStyle(WatchersStyle.mint)
        default:
            Image(systemName: symbol).font(.system(size: 9.5, weight: .medium)).frame(width: 12, height: 12)
                .foregroundStyle(kind == "time" ? WatchersStyle.amber : kind == "inbox" ? HerdrTheme.accent : HerdrTheme.secondaryText)
        }
    }
    private var symbol: String {
        switch kind {
        case "time": "clock"
        case "inbox": "tray"
        case "pc": value.localizedCaseInsensitiveContains("laptop") ? "laptopcomputer" : "desktopcomputer"
        default: "folder"
        }
    }
}
