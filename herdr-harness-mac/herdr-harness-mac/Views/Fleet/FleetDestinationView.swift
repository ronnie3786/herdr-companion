import SwiftUI

struct FleetDestinationView: View {
    let model: HerdrAppModel
    @State private var section = FleetDestinationSection.inventory

    var body: some View {
        VStack(spacing: 0) {
            Picker("Fleet section", selection: $section) {
                ForEach(FleetDestinationSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(HerdrTheme.ink)
            .accessibilityIdentifier("fleet-section-picker")

            Divider().overlay(HerdrTheme.separator)

            switch section {
            case .inventory:
                FleetManagementSheet(model: model, isEmbedded: true)
            case .agentProfiles:
                AgentProfilesView(model: model)
            }
        }
        .background(HerdrTheme.graphite)
    }
}
