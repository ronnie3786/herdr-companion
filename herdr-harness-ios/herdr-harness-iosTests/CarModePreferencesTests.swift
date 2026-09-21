import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Car mode preferences and reply policy")
struct CarModePreferencesTests {
    @Test("Defaults keep four agents, confirm transcripts, and hold the screen awake")
    func defaults() {
        let preferences = CarModePreferences.standard

        #expect(preferences.agentLimit == 4)
        #expect(preferences.confirmsVoiceTranscripts)
        #expect(preferences.keepsScreenAwake)
    }

    @Test("Preferences round-trip through their own defaults key")
    func roundTrip() throws {
        let defaults = try scratchDefaults()
        var preferences = CarModePreferences.standard
        preferences.agentLimit = 6
        preferences.confirmsVoiceTranscripts = false
        preferences.keepsScreenAwake = false

        preferences.save(to: defaults)

        #expect(CarModePreferences.load(from: defaults) == preferences)
        #expect(defaults.dictionary(forKey: CarModePreferences.defaultsKey) != nil)
    }

    @Test("An unusable saved count falls back to four instead of emptying the screen")
    func normalizesBadValues() throws {
        let defaults = try scratchDefaults()
        defaults.set(["agentLimit": 5, "confirmsVoiceTranscripts": true], forKey: CarModePreferences.defaultsKey)

        #expect(CarModePreferences.load(from: defaults).agentLimit == 4)
        #expect(CarModePreferences.normalizedAgentLimit(0) == 4)
        #expect(CarModePreferences.normalizedAgentLimit(2) == 2)
        #expect(CarModePreferences.normalizedAgentLimit(6) == 6)
        #expect(CarModePreferences.standard.normalized().agentLimit == 4)
        #expect(CarModePreferences.load(from: try scratchDefaults()) == .standard)
    }

    @Test("Steering a running turn is preferred, exactly as the chat composer does")
    func disposition() {
        let steerAndFollow = capabilities(steer: true, followUp: true)

        #expect(CarModeSendPolicy.disposition(phase: .working, capabilities: steerAndFollow) == .steer)
        #expect(CarModeSendPolicy.disposition(phase: .idle, capabilities: steerAndFollow) == .prompt)
        #expect(CarModeSendPolicy.disposition(phase: .working, capabilities: capabilities(steer: false, followUp: true)) == .followUp)
        #expect(CarModeSendPolicy.disposition(phase: .working, capabilities: .unavailable) == .prompt)
        #expect(CarModeSendPolicy.disposition(phase: .working, capabilities: nil) == .prompt)
        #expect(CarModeSendPolicy.disposition(phase: .failed, capabilities: steerAndFollow) == .prompt)
    }

    @Test("Panes without a semantic bridge fall back to terminal text")
    func sendRouting() throws {
        #expect(CarModeSendPolicy.usesSemanticPrompt(for: try pane(semantic: true), phase: .idle))
        #expect(CarModeSendPolicy.usesSemanticPrompt(for: try pane(semantic: true), phase: .working))
        #expect(!CarModeSendPolicy.usesSemanticPrompt(for: try pane(semantic: false), phase: .idle))
        #expect(!CarModeSendPolicy.usesSemanticPrompt(for: try pane(connected: false, semantic: true), phase: .working))
    }

    @Test("The confirmation says what sending will actually do")
    func confirmationLabels() {
        #expect(CarModeSendPolicy.confirmationLabel(for: .prompt) == "Send as a new message")
        #expect(CarModeSendPolicy.confirmationLabel(for: .steer) == "Steer the turn that is running")
        #expect(CarModeSendPolicy.confirmationLabel(for: .followUp) == "Queue after the running turn")
    }

    @Test("herdr://car opens Car mode; other links do not")
    func deepLinks() throws {
        #expect(HerdrAppModel.opensCarMode(try #require(URL(string: "herdr://car"))))
        #expect(HerdrAppModel.opensCarMode(try #require(URL(string: "herdr://car-mode"))))
        #expect(HerdrAppModel.opensCarMode(try #require(URL(string: "herdr://pane/w1:p1?car=1"))))
        #expect(!HerdrAppModel.opensCarMode(try #require(URL(string: "herdr://pane/w1:p1"))))
        #expect(!HerdrAppModel.opensCarMode(try #require(URL(string: "herdr://car?car=0"))))
        #expect(!HerdrAppModel.opensCarMode(try #require(URL(string: "https://example.invalid/car"))))
    }

    @MainActor
    @Test("The app model normalizes and persists Car mode settings")
    func modelPersistence() throws {
        let defaults = try scratchDefaults()
        let model = HerdrAppModel(arguments: ["-HerdrDemoMode"], userDefaults: defaults)
        var preferences = model.carModePreferences
        preferences.agentLimit = 5
        preferences.confirmsVoiceTranscripts = false

        model.updateCarModePreferences(preferences)

        #expect(model.carModePreferences.agentLimit == 4)
        #expect(!model.carModePreferences.confirmsVoiceTranscripts)
        #expect(CarModePreferences.load(from: defaults).confirmsVoiceTranscripts == false)

        model.openCarMode()
        #expect(model.isCarModePresented)
    }

    // MARK: - Fixtures

    private func scratchDefaults() throws -> UserDefaults {
        let name = "herdr.carMode.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func capabilities(steer: Bool, followUp: Bool) -> PiSemanticCapabilities {
        PiSemanticCapabilities(
            prompt: true,
            steer: steer,
            followUp: followUp,
            abort: true,
            listModels: false,
            setModel: false,
            setThinkingLevel: false,
            interactionResponse: true
        )
    }

    private func pane(connected: Bool = true, semantic: Bool) throws -> HerdrPane {
        let capability = semantic ? try semanticCapability(connected: connected) : nil
        return HerdrPane(
            paneID: "w1:p1",
            terminalID: "w1:p1",
            workspaceID: "w1",
            tabID: "w1:t1",
            focused: true,
            agentStatus: .idle,
            revision: 1,
            cwd: "/tmp/herdr-demo",
            foregroundCWD: nil,
            label: nil,
            title: "Plan a fictitious herb garden",
            agent: "pi",
            displayAgent: "Pi",
            terminalTitle: nil,
            terminalTitleStripped: nil,
            piSemantic: capability
        )
    }

    /// The bridge capability is decode-only in production, so fixtures build it
    /// the same way the server does.
    private func semanticCapability(connected: Bool) throws -> PiSemanticCapability {
        let json = """
        {
          "available": true,
          "connected": \(connected),
          "protocolVersion": \(connected ? 1 : 0),
          "sessionId": "session-1",
          "capabilities": {
            "prompt": true, "steer": true, "followUp": true, "abort": true,
            "interactionResponse": true
          }
        }
        """
        return try JSONDecoder().decode(PiSemanticCapability.self, from: Data(json.utf8))
    }
}
