enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case machines
    case agents
    case agentProfiles
    case hud
    case alerts
    case voice
    case privacy
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .machines: "Machines"
        case .agents: "Agents"
        case .agentProfiles: "Agent Profiles"
        case .hud: "HUD"
        case .alerts: "Alerts"
        case .voice: "Voice"
        case .privacy: "Privacy & Access"
        case .updates: "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .machines: "server.rack"
        case .agents: "cpu"
        case .agentProfiles: "person.text.rectangle"
        case .hud: "sparkles"
        case .alerts: "bell.badge"
        case .voice: "waveform"
        case .privacy: "lock.shield"
        case .updates: "arrow.down.circle"
        }
    }

    var accessibilityIdentifier: String {
        "settings-pane-\(rawValue)"
    }
}
