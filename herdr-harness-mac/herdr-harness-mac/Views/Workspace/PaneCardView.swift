import SwiftUI

struct PaneCardView: View {
    let pane: HerdrPane
    let isSelected: Bool
    var colorLabel: String?

    var body: some View {
        HStack(spacing: 13) {
            StatusRail(status: pane.agentStatus)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(pane.displayTitle)
                        .herdrFont(size: HerdrTheme.TextSize.reading, weight: .semibold)
                        .foregroundStyle(HerdrTheme.text)
                        .lineLimit(1)
                    Spacer()
                    AgentStatusBadge(status: pane.agentStatus, compact: true)
                }

                HStack(spacing: 10) {
                    Label(pane.displayAgentName, systemImage: pane.agentStatus == .unknown ? "terminal" : "cpu")
                    if !pane.displayPath.isEmpty {
                        Text(pane.displayPath)
                            .fontDesign(.monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(HerdrTheme.tertiaryText)

                HStack {
                    Text(pane.id)
                    Spacer()
                    Text("rev \(pane.revision)")
                }
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(HerdrTheme.tertiaryText)
            }

            Image(systemName: "chevron.right")
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .semibold)
                .foregroundStyle(HerdrTheme.iconTint)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .herdrCard(
            fill: isSelected ? HerdrTheme.selectedFill : HerdrTheme.cardFill,
            outline: isSelected ? HerdrTheme.accent.opacity(0.45) : HerdrTheme.outline
        )
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pane.displayTitle), \(pane.displayAgentName), \(pane.agentStatus.title)")
        .accessibilityValue(colorLabel.map { "Color group: \($0)" } ?? "No tab color")
        .accessibilityHint("Opens the live terminal")
    }
}
