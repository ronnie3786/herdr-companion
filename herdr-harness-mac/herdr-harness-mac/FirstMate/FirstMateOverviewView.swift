import SwiftUI

struct FirstMateOverviewView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FirstMatePullRequestsSection(store: store, snapshot: snapshot, surface: .overview)
            Text("The feature at a glance").herdrFont(.title2, weight: .semibold)
            VStack(alignment: .leading, spacing: 12) {
                Label("GOAL", systemImage: "scope").herdrFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                Text(snapshot.feature.goal).herdrFont(.body).lineSpacing(5).textSelection(.enabled)
            }
            Divider()
            FirstMateVerificationSummaryView(
                verification: snapshot.feature.verification,
                isLastReported: !store.isDemo && store.error != nil
            )
            .padding(16)
            .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 10))
            Divider()
            FirstMateUsageSummaryView(usage: snapshot.feature.usage, title: "Full task usage")
                .padding(16)
                .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 10))
            Divider()
            if let visit = snapshot.currentVisit {
                VStack(alignment: .leading, spacing: 12) {
                    Text("CURRENT FOCUS").herdrFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    HStack {
                        Text(visit.title).herdrFont(.headline)
                        Spacer()
                        FirstMateStatusLabel(status: visit.status)
                    }
                    FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                }.padding(16).background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("AGENTS").herdrFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    Spacer()
                    Button("View all \(snapshot.assignments.count)") { store.inspector = .agents }
                        .buttonStyle(.plain).herdrFont(.caption).foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                }
                ForEach(Array(snapshot.assignments.filter { $0.visitID == snapshot.feature.currentVisitID }.prefix(3))) { agent in
                    FirstMateAgentRow(store: store, agent: agent)
                }
                if snapshot.assignments.isEmpty {
                    Text("Your First Mate will assemble the crew when work is authorized.").herdrFont(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 13) {
                Text("LATEST IN THE JOURNAL").herdrFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                ForEach(Array(snapshot.events.sorted { $0.sequence > $1.sequence }.prefix(4))) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "clock").foregroundStyle(.secondary)
                        Text(event.summary).herdrFont(.subheadline).lineSpacing(3)
                    }
                }
                Button("Open workflow", systemImage: "arrow.right") { store.inspector = .workflow }
                    .buttonStyle(.plain).herdrFont(.caption).foregroundStyle(FirstMatePalette(scheme: scheme).accent)
            }
        }
    }
}
