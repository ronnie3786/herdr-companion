import SwiftUI

struct SidebarStatusMark: View {
    let status: AgentStatus

    var body: some View {
        Image(systemName: status.symbol)
            .font(.caption)
            .foregroundStyle(SidebarRowTone.statusColor(for: status))
            .frame(width: 16, height: 16)
            .accessibilityLabel(status.title)
    }
}
