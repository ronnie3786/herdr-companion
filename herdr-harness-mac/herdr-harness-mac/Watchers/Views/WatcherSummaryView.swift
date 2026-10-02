import SwiftUI

struct WatcherSummaryView: View {
    var markup: String
    var schedule: String
    var tokens: [PiJSONValue]? = nil
    private var runs: [WatchersSummary.Run] { tokens.map(WatchersSummary.parseTokens) ?? WatchersSummary.parse(markup, schedule: schedule) }
    var body: some View {
        WatcherSummaryLayout(spacing: 3.5, lineSpacing: 6) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run {
                case .word(let text): Text(text).font(.system(size: 12.5)).foregroundStyle(HerdrTheme.secondaryText)
                case .chip(let kind, let value, let punctuation):
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        WatcherChip(kind: kind, value: value)
                        if !punctuation.isEmpty { Text(punctuation).font(.system(size: 12.5)).foregroundStyle(HerdrTheme.secondaryText) }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchersSummary.accessibilityText(runs))
    }
}
/// Like CleanupFlowLayout, with shared first baselines and no wrapping inside a chip.
struct WatcherSummaryLayout: Layout {
    var spacing: CGFloat = 3.5
    var lineSpacing: CGFloat = 6
    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var ascent: CGFloat = 0; var descent: CGFloat = 0 }
    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []; var row = Row()
        for index in subviews.indices {
            let d = subviews[index].dimensions(in: ProposedViewSize(width: width, height: nil))
            if !row.indices.isEmpty, row.width + spacing + d.width > width { rows.append(row); row = Row() }
            row.width += (row.indices.isEmpty ? 0 : spacing) + d.width; row.indices.append(index)
            row.ascent = max(row.ascent, d[.firstTextBaseline]); row.descent = max(row.descent, d.height - d[.firstTextBaseline])
        }
        if !row.indices.isEmpty { rows.append(row) }; return rows
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? 600)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.ascent + $1.descent } + CGFloat(max(0, rows.count - 1)) * lineSpacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let d = subviews[index].dimensions(in: ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + row.ascent - d[.firstTextBaseline]), proposal: ProposedViewSize(width: d.width, height: d.height)); x += d.width + spacing
            }
            y += row.ascent + row.descent + lineSpacing
        }
    }
}
struct WatcherChip: View {
    let kind: String
    let value: String
    private var tone: Color { switch kind { case "time": Color(red: 0.95, green: 0.88, blue: 0.74); case "script": Color(red: 0.74, green: 0.90, blue: 0.83); case "skill", "agent", "inbox": HerdrTheme.accent; default: HerdrTheme.primaryText } }
    private var symbol: String { switch kind { case "time": "clock"; case "agent": "face.smiling"; case "script": "terminal"; case "inbox": "tray"; case "repo": "folder"; case "pc": "desktopcomputer"; default: "sparkles" } }
    private var spokenKind: String { switch kind { case "gh": "GitHub"; case "pc": "Computer"; case "slack": "Slack channel"; default: kind.capitalized } }
    var body: some View {
        HStack(spacing: 4) {
            if kind == "slack" || kind == "gh" { Image(kind == "slack" ? "Watcher-slack" : "Watcher-github").resizable().scaledToFit().frame(width: 12, height: 12) }
            else if kind == "skill" { Text("🤖").font(.system(size: 11)) }
            else { Image(systemName: symbol).font(.system(size: 10)) }
            Text(value).font(.system(size: 11.5, weight: .semibold, design: kind == "script" ? .monospaced : .default)).lineLimit(1)
        }
        .foregroundStyle(tone).padding(.horizontal, 6).frame(height: 20)
        .background(tone.opacity(kind == "skill" ? 0.13 : 0.10), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tone.opacity(0.28), lineWidth: 0.7))
        .help("\(spokenKind): \(value)")
        .accessibilityElement(children: .ignore).accessibilityLabel("\(spokenKind) \(value)")
    }
}
