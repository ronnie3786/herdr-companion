import SwiftUI

struct DashboardFirstMatesSection: View {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    let entries: [DashboardFeatureEntry]
    @State private var leadingID: String?

    private var visible: [DashboardFeatureEntry] {
        DashboardFeatureEntry.ordered(entries, focusMode: shell.dashboard.focusMode, query: shell.dashboard.search)
    }
    private var attentionCount: Int { entries.filter(\.needsAttention).count }
    private var scrollIDs: [String] { visible.map(\.id) + ["new-feature"] }
    private var position: Int { leadingID.flatMap { scrollIDs.firstIndex(of: $0) } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button { shell.show(.firstMate, model: model) } label: {
                    HStack(spacing: 6) {
                        Text("First Mates").herdrFont(.headline)
                        Image(systemName: "chevron.right").herdrFont(.caption2)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("dashboard-first-mates")
                Text("\(entries.count) active · \(attentionCount) \(attentionCount == 1 ? "needs" : "need") you")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                Spacer()
                Button("Previous First Mate", systemImage: "chevron.left") { move(-1) }
                    .disabled(position == 0).labelStyle(.iconOnly).herdrHitTarget()
                Button("Next First Mate", systemImage: "chevron.right") { move(1) }
                    .disabled(position >= scrollIDs.count - 1).labelStyle(.iconOnly).herdrHitTarget()
                Button("Agent view", systemImage: "rectangle.split.3x1") { shell.show(.agentBoard, model: model) }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .accessibilityIdentifier("dashboard-open-agent-view")
            }.buttonStyle(.plain).padding(.horizontal, 24)

            if !model.isDemoMode {
                ForEach(shell.firstMateFleet.hosts.filter { $0.unsupported || $0.error != nil }) { host in
                    HStack {
                        Label(host.unsupported ? "\(host.machineName) needs a companion update" : "\(host.machineName) is unavailable. Showing last known work.", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Retry") { Task { await shell.firstMateFleet.refresh() } }
                    }.herdrFont(.caption).foregroundStyle(HerdrTheme.mist).padding(.horizontal, 24)
                }
            }
            if !model.isDemoMode, !shell.firstMateFleet.hosts.isEmpty, !shell.firstMateFleet.hasLoadedAnyHost {
                HStack(spacing: 16) {
                    ForEach(0..<3) { _ in
                        RoundedRectangle(cornerRadius: 12).fill(HerdrTheme.elevated).frame(width: 360, height: 244)
                            .overlay { Text("Loading First Mates…").foregroundStyle(HerdrTheme.muted) }
                    }
                }.padding(.horizontal, 24).accessibilityLabel("Loading First Mates")
            } else {
                if visible.isEmpty && (!entries.isEmpty || shell.dashboard.focusMode || !shell.dashboard.search.isEmpty) {
                    Text(shell.dashboard.focusMode ? "No First Mates are waiting for you." : "No First Mates match your search.")
                        .herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted).padding(.horizontal, 24)
                }
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(visible) { entry in
                            DashboardFeatureCard(entry: entry) {
                                shell.showFirstMate(machineID: entry.machineID, featureID: entry.feature.id, inspector: .overview, model: model)
                            }.id(entry.id)
                        }
                        DashboardNewFeatureCard(model: model, shell: shell).id("new-feature")
                    }.scrollTargetLayout()
                }
                .scrollPosition(id: $leadingID, anchor: .leading)
                .scrollIndicators(.hidden).contentMargins(.horizontal, 24, for: .scrollContent)
                .frame(height: 258)
            }
        }
    }

    private func move(_ offset: Int) {
        leadingID = scrollIDs[min(max(position + offset, 0), scrollIDs.count - 1)]
    }
}
