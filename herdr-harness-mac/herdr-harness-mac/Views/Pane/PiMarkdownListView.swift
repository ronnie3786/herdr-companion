import SwiftUI

struct PiMarkdownListView: View {
    let items: [PiMarkdownListItem]
    @Environment(\.herdrFontScale) private var fontScale
    @Environment(\.chatProsePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                // `.top`, not baselines: the quotable NSTextView path has no
                // SwiftUI baseline, and both paths start their first line at 0.
                HStack(alignment: .top, spacing: 8) {
                    marker(for: item.marker)
                        .herdrIconSlot(width: 16, alignment: .trailing)
                        .accessibilityHidden(true)
                    PiMarkdownText(
                        item.text,
                        font: HerdrProse.font(.listItem, scale: fontScale),
                        inlineCodeFont: HerdrProse.inlineCodeFont(.listItem, scale: fontScale),
                        inlineCodeColor: palette.code,
                        inlineCodeBackground: palette.codeFill,
                        strongColor: palette.strong
                    )
                        .lineSpacing(HerdrProse.lineSpacing(.listItem, scale: fontScale))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(min(item.depth, 6)) * 24)
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
                .herdrFont(size: HerdrTheme.TextSize.reading)
                .foregroundStyle(palette.marker)
        case let .number(number):
            Text("\(number).")
                .herdrFont(size: HerdrTheme.TextSize.reading)
                .monospacedDigit()
                .foregroundStyle(palette.marker)
        case let .task(isCompleted):
            Image(systemName: isCompleted ? "checkmark.square.fill" : "square")
                .herdrFont(size: HerdrTheme.TextSize.body)
                .foregroundStyle(isCompleted ? HerdrTheme.success : palette.marker)
        }
    }

    private func accessibilityLabel(for item: PiMarkdownListItem) -> String {
        switch item.marker {
        case .bullet:
            "Bullet, \(item.text)"
        case let .number(number):
            "Item \(number), \(item.text)"
        case let .task(isCompleted):
            "\(isCompleted ? "Completed" : "Incomplete") task, \(item.text)"
        }
    }
}
