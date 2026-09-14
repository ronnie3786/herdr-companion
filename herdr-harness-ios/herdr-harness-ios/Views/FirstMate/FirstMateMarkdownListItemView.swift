import SwiftUI

struct FirstMateMarkdownListItemView: View {
    let item: PiMarkdownListItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(marker).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(PiMarkdownText.render(item.text))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.body)
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
