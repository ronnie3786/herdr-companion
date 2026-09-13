import SwiftUI

struct AgentsListSummary: View {
    let sessionCount: Int
    let workspaceCount: Int
    let connectionState: ConnectionState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                counts
                Spacer(minLength: 8)
                connection
            }
            VStack(alignment: .leading, spacing: 4) {
                counts
                connection
            }
        }
        .font(.caption)
    }

    private var counts: some View {
        Text("\(sessionCount) Pi agents · \(workspaceCount) workspaces")
            .foregroundStyle(HerdrTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var connection: some View {
        Label(connectionState.title, systemImage: connectionState.symbol)
            .foregroundStyle(connectionState.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
