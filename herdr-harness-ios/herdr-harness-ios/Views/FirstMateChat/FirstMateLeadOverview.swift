import SwiftUI

struct FirstMateLeadOverview: View {
    let fleet: FirstMateMobileFleetStore
    let snapshot: FirstMateSnapshot
    let openFeature: (FirstMateFeatureTarget) -> Void
    private var rows: [FirstMateConversation] { fleet.conversations }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your features at a glance").herdrFont(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        HerdrMicroLabel(text: "GOAL")
                        Text(snapshot.feature.goal).font(HerdrProse.font(.bubble))
                            .foregroundStyle(HerdrTheme.proseText).fixedSize(horizontal: false, vertical: true)
                    }
                    group("Needs you", rows: rows.filter { $0.hudStatus.needsYou })
                    group("Moving", rows: rows.filter { !$0.hudStatus.needsYou && $0.hudStatus != .done })
                    group("Done", rows: rows.filter { $0.hudStatus == .done })
                    Text("\(rows.count) features").herdrFont(.caption2).foregroundStyle(HerdrTheme.secondaryText)
                }.padding(16).frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .leading)
            }
            FirstMateSyncFooter(isDemo: fleet.isDemo, hasError: fleet.hosts.contains { $0.error != nil }, revision: snapshot.feature.revision)
        }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-lead-tab-overview")
    }
    private func group(_ title: String, rows: [FirstMateConversation]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).herdrFont(.body, weight: .semibold); HerdrCountBadge(count: rows.count) }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    FirstMateFeatureCapsule(conversation: row, fleet: fleet, open: openFeature)
                    Text("\(FirstMateChatStatusStyle.word(for: row)) · \(row.machineName)")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                    if let now = row.now, !now.isEmpty {
                        Text(now).herdrFont(.footnote).foregroundStyle(HerdrTheme.proseText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if rows.isEmpty { Text("None").herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText) }
        }
    }
}
