import SwiftUI

/// My First Mate's Info: the Mac lead Overview. Every feature grouped under
/// Needs you, Moving and Done, each row with its status and "now" line; a row
/// opens its readout, and the readout opens its chat.
struct FirstMateLeadOverview: View {
    let fleet: FirstMateMobileFleetStore
    let snapshot: FirstMateSnapshot
    let openFeature: (FirstMateFeatureTarget) -> Void
    private var rows: [FirstMateConversation] { fleet.conversations }
    private var showsMachine: Bool { Set(rows.map(\.machineID)).count > 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FirstMateInspectorHeading(title: "Your features at a glance")
                VStack(alignment: .leading, spacing: 6) {
                    HerdrMicroLabel(text: "Goal")
                    Text(snapshot.feature.goal).herdrFont(.body).foregroundStyle(HerdrTheme.proseText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if rows.isEmpty {
                    Text("No features yet. Describe one in the chat to start it.")
                        .herdrFont(.subheadline).foregroundStyle(HerdrTheme.tertiaryText)
                }
                group("Needs you", rows: rows.filter { $0.hudStatus.needsYou })
                group("Moving", rows: rows.filter { !$0.hudStatus.needsYou && $0.hudStatus != .done })
                group("Done", rows: rows.filter { $0.hudStatus == .done })
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 24)
            .frame(maxWidth: 720).frame(maxWidth: .infinity, alignment: .leading)
        }
        .herdrEdgeFade()
        .safeAreaBar(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                HerdrTabs(selection: .constant(FirstMateInspector.overview), tabs: [
                    .init(value: .overview, title: FirstMateInspector.overview.rawValue, accessibilityIdentifier: "first-mate-lead-info-tab")
                ], style: .underline, accessibilityLabel: "My First Mate info tabs")
                Spacer(minLength: 0)
                FirstMateInspectorPanelButtons()
            }
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .herdrHairline(.bottom)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            FirstMateSyncFooter(isDemo: fleet.isDemo, hasError: fleet.hosts.contains { $0.error != nil }, revision: snapshot.feature.revision,
                                trailing: "\(rows.count) \(rows.count == 1 ? "feature" : "features")")
        }
        .background { HerdrGlassBackground(level: HerdrTheme.Glass.pane).ignoresSafeArea() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-lead-tab-overview")
    }

    @ViewBuilder private func group(_ title: String, rows: [FirstMateConversation]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HerdrMicroLabel(text: title, count: rows.count).padding(.bottom, 4)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    FirstMateFeatureCapsule(conversation: row, fleet: fleet, style: .row, showsMachine: showsMachine,
                                            showsDivider: index < rows.count - 1, open: openFeature)
                }
            }
        }
    }
}
