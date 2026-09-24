import SwiftUI

struct DashboardChatRow: View {
    let pane: HerdrPane
    let workspaceName: String
    let machineName: String
    let open: () -> Void
    @State private var isHovered = false
    private var needsAttention: Bool { pane.agentStatus == .blocked }
    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Group {
                    if needsAttention { Image(systemName: "diamond.fill").foregroundStyle(HerdrTheme.working) }
                    else if pane.agentStatus == .working { Image(systemName: "circle.lefthalf.filled").foregroundStyle(HerdrTheme.signal) }
                    else { Color.clear }
                }.frame(width: 12, height: 12).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(pane.displayTitle).herdrFont(.subheadline, weight: needsAttention ? .semibold : .regular)
                        .foregroundStyle(needsAttention ? HerdrTheme.working : HerdrTheme.text).lineLimit(1)
                    Text("\(workspaceName) · \(machineName)").herdrFont(.caption2).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let date = pane.lastActivityAt ?? pane.firstSeenAt {
                    DashboardAgeText(date: date).herdrFont(.caption2).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(isHovered ? HerdrTheme.elevated : .clear, in: .rect(cornerRadius: 5))
            .overlay(alignment: .bottom) { Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1) }
            .contentShape(.rect)
        }.buttonStyle(.plain).onHover { isHovered = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityValue(needsAttention ? "Needs input" : pane.agentStatus == .working ? "Working" : "")
            .accessibilityIdentifier("dashboard-chat-\(pane.id)")
    }
}
