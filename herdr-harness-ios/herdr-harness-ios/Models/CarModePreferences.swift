import Foundation

/// Car mode settings, stored on this iPhone only.
///
/// Deliberately small: how many agents fit on the screen, whether a spoken
/// reply is confirmed before it is sent, and whether the screen stays awake.
struct CarModePreferences: Equatable, Sendable {
    static let defaultsKey = "herdr.carMode.v1"
    static let defaultAgentLimit = 4
    static let allowedAgentLimits = [2, 4, 6]

    var agentLimit: Int = Self.defaultAgentLimit
    /// Confirming a transcript is the safe default: speech recognition mishears,
    /// and an accidental steer into a working agent is expensive to undo.
    var confirmsVoiceTranscripts: Bool = true
    var keepsScreenAwake: Bool = true

    static let standard = CarModePreferences()

    /// Reads saved values, ignoring anything a previous version or a stray
    /// write left in an unusable shape.
    static func load(from defaults: UserDefaults) -> CarModePreferences {
        guard let saved = defaults.dictionary(forKey: defaultsKey) else { return .standard }
        var preferences = CarModePreferences.standard
        if let limit = saved["agentLimit"] as? Int {
            preferences.agentLimit = normalizedAgentLimit(limit)
        }
        if let confirms = saved["confirmsVoiceTranscripts"] as? Bool {
            preferences.confirmsVoiceTranscripts = confirms
        }
        if let keepsAwake = saved["keepsScreenAwake"] as? Bool {
            preferences.keepsScreenAwake = keepsAwake
        }
        return preferences
    }

    func save(to defaults: UserDefaults) {
        defaults.set(
            [
                "agentLimit": Self.normalizedAgentLimit(agentLimit),
                "confirmsVoiceTranscripts": confirmsVoiceTranscripts,
                "keepsScreenAwake": keepsScreenAwake,
            ],
            forKey: Self.defaultsKey
        )
    }

    func normalized() -> CarModePreferences {
        var copy = self
        copy.agentLimit = Self.normalizedAgentLimit(agentLimit)
        return copy
    }

    static func normalizedAgentLimit(_ limit: Int) -> Int {
        allowedAgentLimits.contains(limit) ? limit : defaultAgentLimit
    }
}
/// How a spoken reply is delivered once it has been transcribed.
enum CarModeSendPolicy {
    /// Mirrors the chat composer: interject into a running turn when the bridge
    /// can steer, otherwise send a normal prompt. A finished agent always gets
    /// a prompt.
    static func disposition(
        phase: PiConversationPhase,
        capabilities: PiSemanticCapabilities?
    ) -> PiPromptDisposition {
        guard phase == .working, let capabilities else { return .prompt }
        if capabilities.steer { return .steer }
        if capabilities.followUp { return .followUp }
        return .prompt
    }

    /// Panes without a semantic bridge only understand terminal text.
    static func usesSemanticPrompt(for pane: HerdrPane, phase: PiConversationPhase) -> Bool {
        guard pane.supportsPiSemanticChat else { return false }
        guard let capabilities = pane.piSemantic?.capabilities else { return false }
        return phase == .working ? (capabilities.steer || capabilities.followUp || capabilities.prompt)
            : capabilities.prompt
    }

    /// What the confirmation screen promises before you send.
    static func confirmationLabel(for disposition: PiPromptDisposition) -> String {
        switch disposition {
        case .prompt: "Send as a new message"
        case .steer: "Steer the turn that is running"
        case .followUp: "Queue after the running turn"
        }
    }
}
