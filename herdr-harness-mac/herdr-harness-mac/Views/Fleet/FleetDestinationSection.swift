enum FleetDestinationSection: String, CaseIterable, Identifiable {
    case inventory
    case agentProfiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inventory: "Inventory"
        case .agentProfiles: "Agent Profiles"
        }
    }
}
