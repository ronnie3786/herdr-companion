import SwiftUI

struct WorkspaceHeroView: View {
    let workspace: HerdrWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(workspace.label)
                        .herdrFont(size: HerdrTheme.TextSize.title, weight: .semibold)
                    if !workspace.displayPath.isEmpty {
                        Text(workspace.displayPath)
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                AgentStatusBadge(status: workspace.agentStatus)
            }

            PaneTopologyView(layout: workspace.layouts.first)
                .frame(height: 94)
                .padding(10)
                .background(HerdrTheme.insetFill, in: .rect(cornerRadius: HerdrTheme.Radius.composer))

            HStack(spacing: 14) {
                Label("^[\(workspace.tabCount) tab](inflect: true)", systemImage: "folder")
                Label("^[\(workspace.paneCount) pane](inflect: true)", systemImage: "rectangle.split.3x1")
                if let branch = workspace.tokens["branch"] {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                }
            }
            .herdrFont(size: HerdrTheme.TextSize.caption)
            .foregroundStyle(HerdrTheme.tertiaryText)
        }
        .padding(14)
        .herdrCard()
    }
}
