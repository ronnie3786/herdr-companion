import SwiftUI

struct FirstMateMarkdownListView: View {
    let items: [PiMarkdownListItem]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 9) {
                    Text(marker(for: item))
                        .font(HerdrProse.font(.listItem, scale: fontScale))
                        .foregroundStyle(palette.secondaryText)
                        .accessibilityHidden(true)
                    FirstMateMarkdownText(item.text, role: .listItem)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .lineSpacing(HerdrProse.lineSpacing(.listItem, scale: fontScale))
                .padding(.leading, CGFloat(min(item.depth, 4)) * 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityDescription(for: item))
            }
        }
    }

    private func marker(for item: PiMarkdownListItem) -> String {
        switch item.marker {
        case .bullet: "•"
        case .number(let number): "\(number)."
        case .task(let completed): completed ? "☑" : "☐"
        }
    }

    private func accessibilityDescription(for item: PiMarkdownListItem) -> String {
        switch item.marker {
        case .bullet: item.text
        case .number(let number): "\(number), \(item.text)"
        case .task(let completed): "\(completed ? "Completed" : "Incomplete"), \(item.text)"
        }
    }
}
