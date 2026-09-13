import SwiftUI

struct AgentWorkspaceHeading: View {
    let group: AgentWorkspaceGroup

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                title
                Spacer(minLength: 8)
                machine
            }
            VStack(alignment: .leading, spacing: 3) {
                title
                machine
            }
        }
    }

    private var title: some View {
        Text(group.workspace.label)
            .font(.title3.bold())
            .foregroundStyle(HerdrTheme.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("agent-workspace-\(group.id)")
    }

    private var machine: some View {
        Label(group.machineName, systemImage: "desktopcomputer")
            .font(.caption2)
            .foregroundStyle(HerdrTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Machine: \(group.machineName)")
    }
}
