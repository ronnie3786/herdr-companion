import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("Agent model settings")
struct AgentModelSettingsStoreTests {
    @Test("Empty defaults use the documented agent defaults")
    func defaults() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AgentModelSettings.load(from: defaults)
        #expect(settings.hudModel == "")
        #expect(settings.quickChatModel == "")
        #expect(settings.visionModel == "")
        #expect(settings.hudThinkingLevel == .max)
        #expect(settings.quickChatThinkingLevel == .max)
        #expect(settings.notesModel == "")
        #expect(settings.notesThinkingLevel == .medium)
        #expect(settings.smartRenameModel == "")
        #expect(settings.smartRenameThinkingLevel == .low)
        #expect(settings.effectiveSmartRenameModel == nil)
        #expect(settings.effectiveVisionModel == AgentModelSettings.builtInVisionModel)
    }

    @MainActor
    @Test("Store mutations persist a complete settings snapshot")
    func storeMutationsPersist() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentModelSettingsStore(defaults: defaults)

        store.hudModel = "openai-codex/gpt-5.6-luna"
        store.quickChatModel = "anthropic/claude-sonnet-4-5"
        store.visionModel = "custom/vision"
        store.hudThinkingLevel = .low
        store.quickChatThinkingLevel = .high
        store.notesModel = "openai-codex/gpt-5.6-luna"
        store.notesThinkingLevel = .low
        store.smartRenameModel = "anthropic/claude-sonnet-4-5"
        store.smartRenameThinkingLevel = .off

        let loaded = AgentModelSettings.load(from: defaults)
        #expect(loaded.hudModel == "openai-codex/gpt-5.6-luna")
        #expect(loaded.quickChatModel == "anthropic/claude-sonnet-4-5")
        #expect(loaded.visionModel == "custom/vision")
        #expect(loaded.hudThinkingLevel == .low)
        #expect(loaded.quickChatThinkingLevel == .high)
        #expect(loaded.notesModel == "openai-codex/gpt-5.6-luna")
        #expect(loaded.notesThinkingLevel == .low)
        #expect(loaded.smartRenameModel == "anthropic/claude-sonnet-4-5")
        #expect(loaded.smartRenameThinkingLevel == .off)
    }

    @MainActor
    @Test("HUD model shares the legacy HUD key")
    func hudModelSharesTheLegacyHudKey() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("p/m", forKey: "herdr.hud.model")

        let store = AgentModelSettingsStore(defaults: defaults)
        #expect(store.hudModel == "p/m")
    }

    @Test("Invalid stored thinking levels fall back to max")
    func invalidStoredThinkingLevelsFallBackToMax() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("bananas", forKey: "herdr.agent.thinkingLevel")

        let settings = AgentModelSettings.load(from: defaults)
        #expect(settings.hudThinkingLevel == .max)
        #expect(settings.quickChatThinkingLevel == .max)
    }

    @Test("Legacy quick chat thinking level migrates to both surfaces")
    func legacyThinkingLevelMigratesToBothSurfaces() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(PiThinkingLevel.low.rawValue, forKey: AgentModelSettings.quickChatThinkingLevelKey)

        let migrated = AgentModelSettings.load(from: defaults)
        #expect(migrated.hudThinkingLevel == .low)
        #expect(migrated.quickChatThinkingLevel == .low)

        defaults.set(PiThinkingLevel.high.rawValue, forKey: AgentModelSettings.hudThinkingLevelKey)
        let independent = AgentModelSettings.load(from: defaults)
        #expect(independent.hudThinkingLevel == .high)
        #expect(independent.quickChatThinkingLevel == .low)
    }

    @Test("effectiveNotesModel falls back through notes model then HUD model then nil")
    func effectiveNotesModelFallsBack() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var settings = AgentModelSettings.load(from: defaults)
        #expect(settings.effectiveNotesModel == nil)
        settings.hudModel = "hud/model"
        #expect(settings.effectiveNotesModel == "hud/model")
        settings.notesModel = "notes/model"
        #expect(settings.effectiveNotesModel == "notes/model")
    }

    @Test("Invalid or missing Smart Rename thinking stays Low instead of inheriting Max")
    func invalidSmartRenameThinkingStaysLow() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(PiThinkingLevel.max.rawValue, forKey: AgentModelSettings.quickChatThinkingLevelKey)
        defaults.set("bananas", forKey: AgentModelSettings.smartRenameThinkingLevelKey)

        let settings = AgentModelSettings.load(from: defaults)
        #expect(settings.quickChatThinkingLevel == .max)
        #expect(settings.smartRenameThinkingLevel == .low)

        defaults.removeObject(forKey: AgentModelSettings.smartRenameThinkingLevelKey)
        let missing = AgentModelSettings.load(from: defaults)
        #expect(missing.smartRenameThinkingLevel == .low)
    }

    @Test("Smart Rename model follows the Agent model until it has its own value")
    func smartRenameModelInheritsTheAgentModel() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var settings = AgentModelSettings.load(from: defaults)
        #expect(settings.effectiveSmartRenameModel == nil)

        settings.quickChatModel = "provider/agent-model"
        #expect(settings.effectiveSmartRenameModel == "provider/agent-model")

        settings.smartRenameModel = "provider/naming-model"
        #expect(settings.effectiveSmartRenameModel == "provider/naming-model")

        settings.smartRenameModel = ""
        #expect(settings.effectiveSmartRenameModel == "provider/agent-model")
    }

    @MainActor
    @Test("Both Smart Rename controls survive store recreation")
    func smartRenameControlsSurviveStoreRecreation() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AgentModelSettingsStore(defaults: defaults)
        store.smartRenameModel = "provider/naming-model"
        store.smartRenameThinkingLevel = .medium

        let recreated = AgentModelSettingsStore(defaults: defaults)
        #expect(recreated.smartRenameModel == "provider/naming-model")
        #expect(recreated.smartRenameThinkingLevel == .medium)
        #expect(recreated.effectiveSmartRenameModel == "provider/naming-model")
        #expect(recreated.smartRenameThinkingLevel != AgentModelSettings.builtInSmartRenameThinkingLevel)

        recreated.smartRenameThinkingLevel = .off
        let offAgain = AgentModelSettingsStore(defaults: defaults)
        #expect(offAgain.smartRenameThinkingLevel == .off)
        #expect(offAgain.smartRenameModel == "provider/naming-model")
    }

    @Test("An unavailable saved model is loaded and saved verbatim, never rewritten")
    func unavailableSavedModelIsPreserved() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("ghost/vendor-naming", forKey: AgentModelSettings.smartRenameModelKey)
        defaults.set(PiThinkingLevel.high.rawValue, forKey: AgentModelSettings.smartRenameThinkingLevelKey)

        var settings = AgentModelSettings.load(from: defaults)
        // The store has no catalog knowledge; an unavailable id is just text
        // that must survive a save/load cycle unchanged.
        #expect(settings.smartRenameModel == "ghost/vendor-naming")
        #expect(settings.effectiveSmartRenameModel == "ghost/vendor-naming")
        #expect(settings.smartRenameThinkingLevel == .high)
        settings.save(to: defaults)

        let reloaded = AgentModelSettings.load(from: defaults)
        #expect(reloaded.smartRenameModel == "ghost/vendor-naming")
        #expect(reloaded.smartRenameThinkingLevel == .high)
        #expect(defaults.string(forKey: AgentModelSettings.smartRenameModelKey) == "ghost/vendor-naming")
    }

    @MainActor
    @Test("Changing Smart Rename fields leaves every unrelated preference unchanged")
    func smartRenameChangesLeaveUnrelatedPreferences() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentModelSettingsStore(defaults: defaults)

        store.hudModel = "hud/one"
        store.quickChatModel = "agent/two"
        store.visionModel = "vision/three"
        store.hudThinkingLevel = .high
        store.quickChatThinkingLevel = .off
        store.notesModel = "notes/four"
        store.notesThinkingLevel = .low
        let before = AgentModelSettings.load(from: defaults)

        store.smartRenameModel = "naming/five"
        store.smartRenameThinkingLevel = .xhigh
        let after = AgentModelSettings.load(from: defaults)

        #expect(after.smartRenameModel == "naming/five")
        #expect(after.smartRenameThinkingLevel == .xhigh)
        #expect(after.hudModel == before.hudModel)
        #expect(after.quickChatModel == before.quickChatModel)
        #expect(after.visionModel == before.visionModel)
        #expect(after.hudThinkingLevel == before.hudThinkingLevel)
        #expect(after.quickChatThinkingLevel == before.quickChatThinkingLevel)
        #expect(after.notesModel == before.notesModel)
        #expect(after.notesThinkingLevel == before.notesThinkingLevel)
        #expect(store.effectiveSmartRenameModel == "naming/five")
    }

    @MainActor
    @Test("A store with an empty Smart Rename model inherits the Agent model until set")
    func storeInheritsTheAgentModel() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("provider/agent-model", forKey: AgentModelSettings.quickChatModelKey)

        let store = AgentModelSettingsStore(defaults: defaults)
        #expect(store.smartRenameModel == "")
        #expect(store.effectiveSmartRenameModel == "provider/agent-model")

        store.smartRenameModel = "provider/naming-model"
        #expect(store.effectiveSmartRenameModel == "provider/naming-model")

        store.smartRenameModel = ""
        #expect(store.effectiveSmartRenameModel == "provider/agent-model")
        #expect(store.quickChatModel == "provider/agent-model")
    }

    @MainActor
    @Test("The store persists Smart Rename fields without changing existing settings")
    func storePersistsSmartRenameWithoutChangingExistingSettings() throws {
        let suiteName = "AgentModelSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("anthropic/claude-sonnet-4-5", forKey: AgentModelSettings.quickChatModelKey)
        defaults.set(PiThinkingLevel.max.rawValue, forKey: AgentModelSettings.quickChatThinkingLevelKey)
        defaults.set(PiThinkingLevel.medium.rawValue, forKey: AgentModelSettings.notesThinkingLevelKey)
        let store = AgentModelSettingsStore(defaults: defaults)

        store.smartRenameModel = "provider/naming-model"
        store.smartRenameThinkingLevel = .off

        #expect(store.quickChatModel == "anthropic/claude-sonnet-4-5")
        #expect(store.quickChatThinkingLevel == .max)
        #expect(store.notesThinkingLevel == .medium)
        #expect(store.effectiveSmartRenameModel == "provider/naming-model")
        let loaded = AgentModelSettings.load(from: defaults)
        #expect(loaded.smartRenameModel == "provider/naming-model")
        #expect(loaded.smartRenameThinkingLevel == .off)
        #expect(loaded.quickChatThinkingLevel == .max)
    }
}
