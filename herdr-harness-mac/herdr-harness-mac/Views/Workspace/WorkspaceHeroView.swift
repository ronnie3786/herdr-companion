import SwiftUI

struct WorkspaceHeroView: View {
    let workspace: HerdrWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(workspace.label)
                        .herdrFont(.title, weight: .semibold)
                    if !workspace.displayPath.isEmpty {
                        Text(workspace.displayPath)
                            .herdrFont(.footnote)
                            .fontDesign(.monospaced)
                            .foregroundStyle(HerdrTheme.mist)
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
                .background(HerdrTheme.graphite, in: .rect(cornerRadius: HerdrTheme.compactRadius))

            HStack(spacing: 14) {
                Label("^[\(workspace.tabCount) tab](inflect: true)", systemImage: "folder")
                Label("^[\(workspace.paneCount) pane](inflect: true)", systemImage: "rectangle.split.3x1")
                if let branch = workspace.tokens["branch"] {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                }
            }
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.mist)
        }
        .padding(HerdrTheme.cardPadding)
        .background(HerdrTheme.elevated)
        .clipShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(HerdrTheme.separator, lineWidth: 1)
        }
    }
}
