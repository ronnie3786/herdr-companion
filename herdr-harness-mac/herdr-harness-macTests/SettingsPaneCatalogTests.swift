import Testing
@testable import herdr_harness_mac

@Suite("Settings pane catalog")
struct SettingsPaneCatalogTests {
    @Test("Panes keep the approved order")
    func approvedOrder() {
        #expect(SettingsPane.allCases == [
            .general,
            .machines,
            .agents,
            .agentProfiles,
            .hud,
            .alerts,
            .voice,
            .privacy,
            .updates,
        ])
    }

    @Test("Pane metadata is complete and unique")
    func completeUniqueMetadata() {
        let panes = SettingsPane.allCases
        let titles = panes.map(\.title)
        let identifiers = panes.map(\.accessibilityIdentifier)
        let symbols = panes.map(\.systemImage)

        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(identifiers.allSatisfy { !$0.isEmpty })
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == panes.count)
        #expect(Set(identifiers).count == panes.count)
        #expect(Set(symbols).count == panes.count)
    }

    @Test("Pane titles match the approved information architecture")
    func approvedTitles() {
        #expect(SettingsPane.allCases.map(\.title) == [
            "General",
            "Machines",
            "Agents",
            "Agent Profiles",
            "HUD",
            "Alerts",
            "Voice",
            "Privacy & Access",
            "Updates",
        ])
    }

    @Test("Pane accessibility identifiers derive from raw values")
    func accessibilityIdentifiers() {
        for pane in SettingsPane.allCases {
            #expect(pane.accessibilityIdentifier == "settings-pane-\(pane.rawValue)")
        }
    }
}
