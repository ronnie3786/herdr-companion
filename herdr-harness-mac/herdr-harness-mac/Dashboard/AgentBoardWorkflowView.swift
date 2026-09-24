import SwiftUI

struct AgentBoardWorkflowView: View {
    let snapshot: FirstMateSnapshot

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if snapshot.visits.isEmpty {
                    Text("The workflow will appear when First Mate plans the first stage.")
                        .herdrFont(.body).foregroundStyle(HerdrTheme.muted)
                }
                ForEach(snapshot.visits) { visit in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 6) {
                            Image(systemName: symbol(visit))
                                .foregroundStyle(visit.id == snapshot.feature.currentVisitID ? HerdrTheme.accent : HerdrTheme.muted)
                                .frame(width: 20, height: 20)
                            Rectangle().fill(HerdrTheme.separator).frame(width: 1, height: 40)
                                .opacity(visit.id == snapshot.visits.last?.id ? 0 : 1)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(visit.title).herdrFont(.body, weight: .medium)
                            HStack(spacing: 6) {
                                Text(visit.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                if visit.id == snapshot.feature.currentVisitID { Text("· Current") }
                            }
                            .herdrFont(.caption)
                            .foregroundStyle(HerdrTheme.muted)
                        }
                        .padding(.top, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func symbol(_ visit: FirstMateVisit) -> String {
        if visit.status == "completed" { return "checkmark.circle" }
        if visit.status == "failed" { return "xmark.circle" }
        if visit.id == snapshot.feature.currentVisitID { return "circle.inset.filled" }
        return "circle"
    }
}
