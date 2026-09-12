import SwiftUI

struct SidebarMachineRow: View {
    let machine: HerdrMachine
    let state: ConnectionState
    let paneCount: Int
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

                Image(systemName: "desktopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(state == .live || state == .demo ? HerdrTheme.mist : state.color)
                    .accessibilityHidden(true)

                Text(machine.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                if state == .live || state == .demo {
                    Text("\(paneCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(HerdrTheme.muted)
                } else {
                    Text(state.title)
                        .font(.caption)
                        .foregroundStyle(state.color)
                }
            }
            .padding(.leading, SidebarMetrics.workspaceRowLeadingPadding)
            .padding(.trailing, SidebarMetrics.rowTrailingPadding)
            .frame(minHeight: SidebarMetrics.machineRowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-machine-\(machine.id)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(machine.name), \(state.title), \(paneCount) panes")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Collapses or expands this machine's workspaces")
    }
}
