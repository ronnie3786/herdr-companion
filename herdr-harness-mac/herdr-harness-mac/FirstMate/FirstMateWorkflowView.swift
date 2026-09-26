import SwiftUI

struct FirstMateWorkflowView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Feature journal").herdrFont(size: 15, weight: .semibold)
                Spacer()
                HerdrTabs(
                    selection: $store.graphMode,
                    tabs: [.init(value: false, title: "Timeline"), .init(value: true, title: "Graph")],
                    style: .compactSegments,
                    accessibilityLabel: "Workflow presentation"
                )
                .fixedSize()
                .accessibilityIdentifier("first-mate-workflow-mode")
            }
            Text("Every visit retains its agents and evidence. Revisions keep earlier work available.")
                .herdrFont(size: HerdrTheme.TextSize.small).foregroundStyle(HerdrTheme.secondaryText)
            if store.graphMode {
                FirstMateGraphView(store: store, snapshot: snapshot)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.visits.enumerated()), id: \.element.id) { index, visit in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Image(systemName: visit.status == "completed" ? "checkmark.circle.fill" : "circle")
                                    .herdrFont(size: HerdrTheme.TextSize.body).foregroundStyle(FirstMatePalette(scheme: scheme).accent)
                                Rectangle().fill(HerdrTheme.hairline).frame(width: 1)
                            }.herdrIconSlot(width: 20)
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .top) {
                                    Text(visit.title).herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                                    Spacer(minLength: 4)
                                    FirstMateStatusLabel(status: visit.status)
                                }
                                Text("Visit \(index + 1) · revision \(visit.revision)").herdrFont(size: HerdrTheme.TextSize.caption).foregroundStyle(HerdrTheme.secondaryText)
                                FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                            }.padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
            FirstMateReliabilityView(health: store.runtimeHealth, snapshot: snapshot)
            ForEach(snapshot.events.filter { $0.featureID == snapshot.feature.id && $0.recoveryCheckpoint?.workspacePath != nil }.suffix(10)) { event in
                if let checkpoint = event.recoveryCheckpoint {
                    DisclosureGroup("Recovery checkpoint · \(event.createdAt)") {
                        FirstMateRecoveryFactsView(store: store, snapshot: snapshot, checkpoint: checkpoint)
                            .padding(.top, 8)
                    }
                    .herdrFont(size: HerdrTheme.TextSize.small)
                }
            }
            if snapshot.visits.isEmpty {
                ContentUnavailableView("The journey starts with a plan", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
        }
    }
}
