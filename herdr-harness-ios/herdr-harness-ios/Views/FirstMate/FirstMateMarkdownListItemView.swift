import SwiftUI

struct FirstMateMarkdownListItemView: View {
    let item: PiMarkdownListItem
    @Environment(\.firstMateMentionCatalog) private var catalog

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(marker).foregroundStyle(HerdrTheme.secondaryText).accessibilityHidden(true)
            Text(FirstMateMentionText.render(item.text, catalog: catalog))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(HerdrProse.font(.bubble))
        .lineSpacing(4)
        .padding(.leading, CGFloat(min(item.depth, 4)) * 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var marker: String {
        switch item.marker {
        case .bullet: "•"
        case .number(let number): "\(number)."
        case .task(let completed): completed ? "☑" : "☐"
        }
    }

    private var accessibilityDescription: String {
        switch item.marker {
        case .bullet: item.text
        case .number(let number): "\(number), \(item.text)"
        case .task(let completed): "\(completed ? "Completed" : "Incomplete"), \(item.text)"
        }
    }
}
