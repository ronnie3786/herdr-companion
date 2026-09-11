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
                        .herdrFont(.headline, weight: .semibold)
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
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)

                HStack {
                    Text(pane.id)
                    Spacer()
                    Text("rev \(pane.revision)")
                }
                .herdrFont(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(HerdrTheme.muted)
            }

            Image(systemName: "chevron.right")
                .herdrFont(.caption, weight: .bold)
                .foregroundStyle(HerdrTheme.muted)
        }
        .padding(15)
        .background(isSelected ? HerdrTheme.selection : HerdrTheme.elevated)
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(isSelected ? HerdrTheme.accent.opacity(0.5) : HerdrTheme.separator, lineWidth: 1)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pane.displayTitle), \(pane.displayAgentName), \(pane.agentStatus.title)")
        .accessibilityValue(colorLabel.map { "Color group: \($0)" } ?? "No tab color")
        .accessibilityHint("Opens the live terminal")
    }
}
