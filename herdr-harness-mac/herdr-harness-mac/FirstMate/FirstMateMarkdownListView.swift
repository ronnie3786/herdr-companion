import SwiftUI

struct FirstMateMarkdownListView: View {
    let items: [PiMarkdownListItem]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale
    @Environment(\.firstMateMarkdownDensity) private var density

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: density == .compact ? 4 : 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(marker(for: item))
                        .font(.system(size: density.size(.listItem) * fontScale.rawValue))
                        .foregroundStyle(palette.tertiaryText)
                        .accessibilityHidden(true)
                    FirstMateMarkdownText(item.text, role: .listItem)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .lineSpacing(density.lineSpacing(.listItem, scale: fontScale))
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
