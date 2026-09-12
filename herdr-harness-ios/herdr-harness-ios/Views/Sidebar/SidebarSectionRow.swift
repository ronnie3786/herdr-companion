import SwiftUI

struct SidebarSectionRow: View {
    let tab: HerdrTab
    let tabColor: ChatTabColor?
    let colorLabel: String?
    let isExpanded: Bool
    let attentionStatus: AgentStatus?
    let workingCount: Int
    let action: () -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(disclosureColor)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)

                if let tabColor {
                    Image(systemName: differentiateWithoutColor ? tabColor.symbol : "folder")
                        .font(.caption)
                        .foregroundStyle(tabColor.swatch)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                        .accessibilityHidden(true)
                }

                Text(tab.label)
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                if workingCount > 0 {
                    Image(systemName: AgentStatus.working.symbol)
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.working)
                        .accessibilityLabel("\(workingCount) working")
                }

                Text("\(tab.paneCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(HerdrTheme.muted)
            }
            .padding(.leading, SidebarMetrics.tabRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.tabRowHeight)
            .contentShape(.rect)
            .background(tabColor?.rowBackground(selected: false) ?? .clear, in: .rect(cornerRadius: SidebarMetrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-tab-\(tab.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Collapses or expands this tab's chats")
    }

    private var disclosureColor: Color {
        if let attentionStatus { attentionStatus.color }
        else if workingCount > 0 { HerdrTheme.working }
        else { HerdrTheme.mist }
    }

    private var accessibilityLabel: String {
        var parts = [tab.label, "\(tab.paneCount) panes"]
        if let tabColor {
            parts.append("color \(colorLabel ?? tabColor.defaultLabel), \(tabColor.defaultLabel)")
        }
        if let attentionStatus { parts.append(attentionStatus.title) }
        if workingCount > 0 { parts.append("\(workingCount) working") }
        return parts.joined(separator: ", ")
    }
}
