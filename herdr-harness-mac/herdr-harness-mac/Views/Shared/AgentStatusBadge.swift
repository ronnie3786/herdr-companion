import SwiftUI

struct AgentStatusBadge: View {
    let status: AgentStatus
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol)
                .herdrFont(size: 9, weight: .semibold)
                .accessibilityHidden(true)
            Text(compact ? status.compactTitle : status.title)
                .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                .lineLimit(1)
        }
        .foregroundStyle(status.labelColor)
        .padding(.horizontal, 6)
        .frame(minHeight: 20)
        .background(status.color.opacity(0.12), in: .rect(cornerRadius: 4))
        .fixedSize()
            .accessibilityLabel("Agent status: \(status.title)")
    }
}
