import SwiftUI

struct SidebarProjectRow: View {
    let workspace: HerdrWorkspace
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(HerdrTheme.mist)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)

                Image(systemName: "folder")
                    .font(.subheadline)
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityHidden(true)

                Text(workspace.label)
                    .font(.subheadline.bold())
                    .foregroundStyle(HerdrTheme.mist)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if workspace.focused {
                    Image(systemName: "scope")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.accent)
                        .accessibilityLabel("Active workspace")
                }

                Spacer(minLength: 4)

                if workspace.attentionCount > 0 {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.alert)
                        .accessibilityLabel("\(workspace.attentionCount) needing attention")
                } else if !isExpanded, workspace.workingCount > 0 {
                    Image(systemName: AgentStatus.working.symbol)
                        .font(.caption)
                        .foregroundStyle(HerdrTheme.working)
                        .accessibilityLabel("\(workspace.workingCount) working")
                }

                Text("\(workspace.paneCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(HerdrTheme.muted)
            }
            .padding(.leading, SidebarMetrics.workspaceRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.workspaceRowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-workspace-\(workspace.id)")
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Collapses or expands this workspace's tabs")
    }

    private var accessibilityValue: String {
        var parts = [isExpanded ? "Expanded" : "Collapsed", "\(workspace.paneCount) panes"]
        if workspace.focused { parts.append("active workspace") }
        if workspace.attentionCount > 0 { parts.append("\(workspace.attentionCount) needing attention") }
        if workspace.workingCount > 0 { parts.append("\(workspace.workingCount) working") }
        return parts.joined(separator: ", ")
    }
}
