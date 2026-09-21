import Foundation
import Observation

// These are the app-side defaults for headless agent runs in the HUD and quick
// chat. An empty model string means send no model, letting the harness's own pi
// default win. The vision and thinking defaults used to be compile-time
// constants in HerdrHudModelRouting.
struct AgentModelSettings: Equatable, Sendable {
    // The HUD keeps its original key: the HUD's own chip has always written
    // here, and Settings is a second surface onto the same value, not a
    // competing one. A user who picks a model in the HUD sees it in Settings.
    static let hudModelKey = "herdr.hud.model"
    static let quickChatModelKey = "herdr.agent.model"
    static let visionModelKey = "herdr.agent.visionModel"
    static let hudThinkingLevelKey = "herdr.hud.thinkingLevel"
    /// Quick chat keeps the key the shared setting used, so an existing choice
    /// carries over instead of silently resetting to the built-in default.
    static let quickChatThinkingLevelKey = "herdr.agent.thinkingLevel"
    static let notesModelKey = "herdr.notes.model"
    static let notesThinkingLevelKey = "herdr.notes.thinkingLevel"
    /// Smart Rename's model has its own preference so a naming run can use a
    /// different model than the chat it names. An empty value means "Same as
    /// Agent model": `quickChatModelKey` first, then the execution machine's
    /// Pi default.
    static let smartRenameModelKey = "herdr.agent.smartRenameModel"
    /// Smart Rename has always named with Low effort, so a missing or
    /// unrecognized value must keep resolving there. It deliberately does not
    /// inherit `quickChatThinkingLevelKey`'s Max default.
    static let smartRenameThinkingLevelKey = "herdr.agent.smartRenameThinkingLevel"

    /// The model every image-bearing HUD message is rerouted to when the
    /// chosen model cannot see images. Was `HerdrHudModelRouting.visionModel`.
    static let builtInVisionModel = "openai-codex/gpt-5.6-luna"
    static let builtInThinkingLevel = PiThinkingLevel.max
    /// The effort Smart Rename used before it became configurable.
    static let builtInSmartRenameThinkingLevel = PiThinkingLevel.low

    var hudModel: String
    var quickChatModel: String
    var visionModel: String
    var hudThinkingLevel: PiThinkingLevel
    var quickChatThinkingLevel: PiThinkingLevel
    var notesModel: String
    var notesThinkingLevel: PiThinkingLevel
    var smartRenameModel: String
    var smartRenameThinkingLevel: PiThinkingLevel

    static func load(from defaults: UserDefaults) -> AgentModelSettings {
        let legacy = defaults.string(forKey: quickChatThinkingLevelKey)
        let hudRaw = defaults.string(forKey: hudThinkingLevelKey) ?? legacy
        return AgentModelSettings(
            hudModel: defaults.string(forKey: hudModelKey) ?? "",
            quickChatModel: defaults.string(forKey: quickChatModelKey) ?? "",
            visionModel: defaults.string(forKey: visionModelKey) ?? "",
            hudThinkingLevel: PiThinkingLevel(rawValue: hudRaw ?? "") ?? builtInThinkingLevel,
            quickChatThinkingLevel: PiThinkingLevel(rawValue: legacy ?? "") ?? builtInThinkingLevel,
            notesModel: defaults.string(forKey: notesModelKey) ?? "",
            notesThinkingLevel: PiThinkingLevel(rawValue: defaults.string(forKey: notesThinkingLevelKey) ?? "") ?? .medium,
            smartRenameModel: defaults.string(forKey: smartRenameModelKey) ?? "",
            smartRenameThinkingLevel: PiThinkingLevel(
                rawValue: defaults.string(forKey: smartRenameThinkingLevelKey) ?? ""
            ) ?? builtInSmartRenameThinkingLevel
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(hudModel, forKey: Self.hudModelKey)
        defaults.set(quickChatModel, forKey: Self.quickChatModelKey)
        defaults.set(visionModel, forKey: Self.visionModelKey)
        defaults.set(hudThinkingLevel.rawValue, forKey: Self.hudThinkingLevelKey)
        defaults.set(quickChatThinkingLevel.rawValue, forKey: Self.quickChatThinkingLevelKey)
        defaults.set(notesModel, forKey: Self.notesModelKey)
        defaults.set(notesThinkingLevel.rawValue, forKey: Self.notesThinkingLevelKey)
        defaults.set(smartRenameModel, forKey: Self.smartRenameModelKey)
        defaults.set(smartRenameThinkingLevel.rawValue, forKey: Self.smartRenameThinkingLevelKey)
    }

    /// The vision model actually sent, never empty.
    var effectiveVisionModel: String {
        visionModel.isEmpty ? Self.builtInVisionModel : visionModel
    }

    var effectiveNotesModel: String? {
        if !notesModel.isEmpty { return notesModel }
        if !hudModel.isEmpty { return hudModel }
        return nil
    }

    /// The naming model preference actually sent, if any. An empty Smart
    /// Rename choice follows the Agent model; an empty Agent choice means the
    /// execution machine's Pi default. A non-empty value is returned verbatim
    /// even when a catalog does not offer it: callers report the mismatch and
    /// never substitute another model or rewrite this preference.
    var effectiveSmartRenameModel: String? {
        if !smartRenameModel.isEmpty { return smartRenameModel }
        if !quickChatModel.isEmpty { return quickChatModel }
        return nil
    }
}

@MainActor
@Observable
final class AgentModelSettingsStore {
    var hudModel: String {
        didSet { saveIfChanged(oldValue != hudModel) }
    }
    var quickChatModel: String {
        didSet { saveIfChanged(oldValue != quickChatModel) }
    }
    var visionModel: String {
        didSet { saveIfChanged(oldValue != visionModel) }
    }
    var hudThinkingLevel: PiThinkingLevel {
        didSet { saveIfChanged(oldValue != hudThinkingLevel) }
    }
    var quickChatThinkingLevel: PiThinkingLevel {
        didSet { saveIfChanged(oldValue != quickChatThinkingLevel) }
    }
    var notesModel: String {
        didSet { saveIfChanged(oldValue != notesModel) }
    }
    var notesThinkingLevel: PiThinkingLevel {
        didSet { saveIfChanged(oldValue != notesThinkingLevel) }
    }
    var smartRenameModel: String {
        didSet { saveIfChanged(oldValue != smartRenameModel) }
    }
    var smartRenameThinkingLevel: PiThinkingLevel {
        didSet { saveIfChanged(oldValue != smartRenameThinkingLevel) }
    }

    var effectiveVisionModel: String {
        visionModel.isEmpty ? AgentModelSettings.builtInVisionModel : visionModel
    }

    var effectiveNotesModel: String? {
        if !notesModel.isEmpty { return notesModel }
        if !hudModel.isEmpty { return hudModel }
        return nil
    }

    var effectiveSmartRenameModel: String? {
        if !smartRenameModel.isEmpty { return smartRenameModel }
        if !quickChatModel.isEmpty { return quickChatModel }
        return nil
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = AgentModelSettings.load(from: defaults)
        hudModel = settings.hudModel
        quickChatModel = settings.quickChatModel
        visionModel = settings.visionModel
        hudThinkingLevel = settings.hudThinkingLevel
        quickChatThinkingLevel = settings.quickChatThinkingLevel
        notesModel = settings.notesModel
        notesThinkingLevel = settings.notesThinkingLevel
        smartRenameModel = settings.smartRenameModel
        smartRenameThinkingLevel = settings.smartRenameThinkingLevel
    }

    private func saveIfChanged(_ changed: Bool) {
        guard changed else { return }
        AgentModelSettings(
            hudModel: hudModel,
            quickChatModel: quickChatModel,
            visionModel: visionModel,
            hudThinkingLevel: hudThinkingLevel,
            quickChatThinkingLevel: quickChatThinkingLevel,
            notesModel: notesModel,
            notesThinkingLevel: notesThinkingLevel,
            smartRenameModel: smartRenameModel,
            smartRenameThinkingLevel: smartRenameThinkingLevel
        ).save(to: defaults)
    }
}
