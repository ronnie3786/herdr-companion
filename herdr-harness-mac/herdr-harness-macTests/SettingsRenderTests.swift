import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import Vision
@testable import herdr_harness_mac

@Suite("Settings pane renders", .serialized)
@MainActor
struct SettingsRenderTests {
    @Test("Settings pane renders substantial content", arguments: SettingsPane.allCases)
    func rendersPane(_ pane: SettingsPane) async throws {
        let suiteName = "SettingsRenderTests.\(pane.rawValue).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrRenderFixtures.demoModel()
        let fontScale = HerdrFontScaleStore(defaults: defaults)
        let result = try await HerdrRenderHarness.render(
            "settings-\(pane.rawValue).png",
            size: CGSize(width: 920, height: 680)
        ) {
            SettingsView(
                model: model,
                fontScale: fontScale,
                cleanupSettings: CleanupSettingsStore(defaults: defaults),
                agentSettings: AgentModelSettingsStore(defaults: defaults),
                promptSettings: HerdrPromptSettingsStore(defaults: defaults),
                modelFavorites: ModelFavoritesStore(userDefaults: defaults),
                hudController: HerdrHudController(userDefaults: defaults),
                updates: HerdrUpdateController(defaults: defaults),
                agentControl: AgentControlController(
                    defaults: defaults,
                    secretStorage: TestAgentControlSecretStorage()
                ),
                initialPane: pane
            )
            .environment(\.herdrFontScale, fontScale.scale)
            .background(HerdrTheme.ink)
            .foregroundStyle(HerdrTheme.text)
            .preferredColorScheme(.dark)
            .tint(HerdrTheme.accent)
        }

        result.expectSubstantial()
    }

    @Test("Settings columns preserve dark chrome and visible sidebar rows")
    func rendersDarkColumnsAndVisibleSidebarRows() async throws {
        let suiteName = "SettingsRenderTests.pixels.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrRenderFixtures.demoModel()
        let fontScale = HerdrFontScaleStore(defaults: defaults)
        let result = try await HerdrRenderHarness.render(
            "settings-pixel-regression.png",
            size: CGSize(width: 920, height: 680)
        ) {
            SettingsView(
                model: model,
                fontScale: fontScale,
                cleanupSettings: CleanupSettingsStore(defaults: defaults),
                agentSettings: AgentModelSettingsStore(defaults: defaults),
                promptSettings: HerdrPromptSettingsStore(defaults: defaults),
                modelFavorites: ModelFavoritesStore(userDefaults: defaults),
                hudController: HerdrHudController(userDefaults: defaults),
                updates: HerdrUpdateController(defaults: defaults),
                agentControl: AgentControlController(
                    defaults: defaults,
                    secretStorage: TestAgentControlSecretStorage()
                ),
                initialPane: .general
            )
            .environment(\.herdrFontScale, fontScale.scale)
            .background(HerdrTheme.ink)
            .foregroundStyle(HerdrTheme.text)
            .preferredColorScheme(.dark)
            .tint(HerdrTheme.accent)
        }

        result.expectSubstantial()
        let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: result.url)))
        let verticalInset = Int(Double(bitmap.pixelsHigh) * 0.05)
        let sampledRows = verticalInset..<(bitmap.pixelsHigh - verticalInset)
        let sidebar = luminanceStatistics(
            in: bitmap,
            columns: 0..<Int(Double(bitmap.pixelsWide) * 0.22),
            rows: sampledRows
        )
        let detail = luminanceStatistics(
            in: bitmap,
            columns: Int(Double(bitmap.pixelsWide) * 0.26)..<bitmap.pixelsWide,
            rows: sampledRows
        )

        // Regression: a sidebar resolving to a light background hides the
        // dark-chrome rows. Its mean must stay dark while row pixels stay bright.
        #expect(sidebar.mean < 100, "Sidebar mean luminance was \(sidebar.mean)")
        #expect(sidebar.maximum > 150, "Sidebar maximum luminance was \(sidebar.maximum)")
        #expect(detail.mean < 100, "Detail mean luminance was \(detail.mean)")
    }

    @Test("Each settings pane renders distinct content")
    func rendersDistinctPaneContent() async throws {
        var digests = Set<Data>()

        for pane in SettingsPane.allCases {
            let suiteName = "SettingsRenderTests.distinct.\(pane.rawValue).\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let model = HerdrRenderFixtures.demoModel()
            let fontScale = HerdrFontScaleStore(defaults: defaults)
            let result = try await HerdrRenderHarness.render(
                "settings-pane-\(pane.rawValue).png",
                size: CGSize(width: 920, height: 680)
            ) {
                SettingsView(
                    model: model,
                    fontScale: fontScale,
                    cleanupSettings: CleanupSettingsStore(defaults: defaults),
                    agentSettings: AgentModelSettingsStore(defaults: defaults),
                    promptSettings: HerdrPromptSettingsStore(defaults: defaults),
                    modelFavorites: ModelFavoritesStore(userDefaults: defaults),
                    hudController: HerdrHudController(userDefaults: defaults),
                    updates: HerdrUpdateController(defaults: defaults),
                    agentControl: AgentControlController(
                        defaults: defaults,
                        secretStorage: TestAgentControlSecretStorage()
                    ),
                    initialPane: pane
                )
                .environment(\.herdrFontScale, fontScale.scale)
                .background(HerdrTheme.ink)
                .foregroundStyle(HerdrTheme.text)
                .preferredColorScheme(.dark)
                .tint(HerdrTheme.accent)
            }

            result.expectSubstantial()
            let pngData = try Data(contentsOf: result.url)
            digests.insert(Data(SHA256.hash(data: pngData)))
        }

        #expect(digests.count == SettingsPane.allCases.count)
    }

    @Test("Smart Rename settings render the saved naming model and effort")
    func rendersSmartRenameSettings() async throws {
        let populated = try await renderAgentsPane(
            named: "settings-smart-rename-populated.png",
            configure: { settings in
                settings.smartRenameModel = "openai-codex/gpt-5.6-luna"
                settings.smartRenameThinkingLevel = .off
            }
        )
        let defaultsOnly = try await renderAgentsPane(
            named: "settings-smart-rename-defaults.png",
            configure: { _ in }
        )

        populated.result.expectSubstantial()
        defaultsOnly.result.expectSubstantial()
        // The naming model label and effort picker are part of the Agents pane,
        // so a saved Smart Rename choice must change what it draws.
        #expect(try pngData(populated) != pngData(defaultsOnly))
    }

    @Test("Both Smart Rename controls change the rendered Agents pane")
    func rendersBothSmartRenameControls() async throws {
        let baseline = try await renderAgentsPane(
            named: "settings-smart-rename-baseline.png",
            configure: { settings in
                settings.smartRenameModel = "openai-codex/gpt-5.6-luna"
                settings.smartRenameThinkingLevel = .off
            }
        )
        let otherModel = try await renderAgentsPane(
            named: "settings-smart-rename-other-model.png",
            configure: { settings in
                settings.smartRenameModel = "anthropic/claude-sonnet-4-5"
                settings.smartRenameThinkingLevel = .off
            }
        )
        let otherEffort = try await renderAgentsPane(
            named: "settings-smart-rename-other-effort.png",
            configure: { settings in
                settings.smartRenameModel = "openai-codex/gpt-5.6-luna"
                settings.smartRenameThinkingLevel = .low
            }
        )

        for render in [baseline, otherModel, otherEffort] {
            render.result.expectSubstantial()
        }
        #expect(try pngData(baseline) != pngData(otherModel))
        #expect(try pngData(baseline) != pngData(otherEffort))
        #expect(baseline.settings.smartRenameModel == "openai-codex/gpt-5.6-luna")
        #expect(otherModel.settings.smartRenameModel == "anthropic/claude-sonnet-4-5")
        #expect(otherEffort.settings.smartRenameThinkingLevel == .low)
    }

    @Test("A saved but unavailable selection stays visible with a strict-policy warning")
    func rendersUnavailableSelectionWarning() async throws {
        let available = try await renderAgentsPane(
            named: "settings-smart-rename-available.png",
            configure: { settings in
                settings.smartRenameModel = "openai-codex/gpt-5.6-luna"
                settings.smartRenameThinkingLevel = .low
            }
        )
        let unavailable = try await renderAgentsPane(
            named: "settings-smart-rename-unavailable.png",
            settlePasses: 16,
            configure: { settings in
                settings.smartRenameModel = "ghost/vendor-naming"
                settings.smartRenameThinkingLevel = .low
            }
        )

        available.result.expectSubstantial()
        unavailable.result.expectSubstantial()
        // The warning changes the drawn pane; the saved selection survives the
        // catalog load and every unrelated preference stays put.
        #expect(try pngData(available) != pngData(unavailable))
        #expect(unavailable.settings.smartRenameModel == "ghost/vendor-naming")
        #expect(unavailable.settings.smartRenameThinkingLevel == .low)
        #expect(unavailable.settings.quickChatModel == "")
        #expect(unavailable.settings.hudModel == "")

        // "offered" appears only in the strict-policy warning, so visible text
        // proves the unavailable selection was reported rather than hidden.
        let availableText = try recognizedText(available)
        let unavailableText = try recognizedText(unavailable)
        #expect(!availableText.lowercased().contains("offered"))
        #expect(unavailableText.lowercased().contains("offered"))

        let catalog = try await HerdrRenderFixtures.demoModel().fetchAgentModels()
        let warning = try #require(SmartRenameSettingsPresentation.resolutionWarning(
            catalog: catalog,
            preference: "ghost/vendor-naming",
            thinkingLevel: .low,
            browsedCatalogMachineName: "desktop"
        ))
        #expect(warning.contains("ghost/vendor-naming"))
        #expect(warning.contains("desktop"))
        #expect(warning.contains("Settings"))
        #expect(!warning.contains("falls back"))
    }

    @Test("An incompatible thinking level warns with Off as the actionable fix")
    func rendersIncompatibleThinkingWarning() async throws {
        let legacy = PiAvailableModel(
            provider: "alpha",
            modelID: "legacy",
            name: "Alpha Legacy",
            reasoning: false,
            contextWindow: nil
        )
        let catalog = AgentModelCatalogResponse(
            ok: true,
            models: [legacy],
            defaultModel: PiModelIdentity(provider: "alpha", id: "legacy", name: "Alpha Legacy")
        )

        #expect(SmartRenameSettingsPresentation.resolutionWarning(
            catalog: catalog,
            preference: legacy.id,
            thinkingLevel: .off,
            browsedCatalogMachineName: "Alpha"
        ) == nil)

        let warning = try #require(SmartRenameSettingsPresentation.resolutionWarning(
            catalog: catalog,
            preference: legacy.id,
            thinkingLevel: .high,
            browsedCatalogMachineName: "Alpha"
        ))
        #expect(warning.contains("alpha/legacy"))
        #expect(warning.contains("High"))
        #expect(warning.contains("Off"))
        #expect(warning.contains("Alpha"))
        #expect(warning.contains("Settings"))
    }

    @Test("The Smart Rename copy states the strict policy without promising a fallback")
    func smartRenameCopyStatesStrictPolicy() {
        let footer = SmartRenameSettingsPresentation.sectionFooter
        #expect(footer.contains("keeps the current title"))
        #expect(footer.contains("leaves the saved preference unchanged"))
        #expect(footer.contains("no other model or machine is substituted"))
        #expect(!footer.contains("fallback"))
        #expect(!footer.contains("falls back"))
        #expect(!footer.contains("Off when the resolved model cannot reason"))

        let sourceNote = SmartRenameSettingsPresentation.catalogSourceFootnote
        #expect(sourceNote.contains("browses"))
        #expect(sourceNote.contains("does not prove"))
        #expect(sourceNote.contains("machine that owns the target"))
    }

    @Test("Switching the browsed catalog source leaves the saved selection unchanged")
    func switchingCatalogSourceKeepsSelection() async throws {
        let desktop = try await renderAgentsPane(
            named: "settings-smart-rename-source-desktop.png",
            initialCatalogMachineID: "demo1",
            configure: { settings in
                settings.smartRenameModel = "anthropic/claude-sonnet-4-5"
                settings.smartRenameThinkingLevel = .low
            }
        )
        let laptop = try await renderAgentsPane(
            named: "settings-smart-rename-source-laptop.png",
            initialCatalogMachineID: "demo2",
            configure: { settings in
                settings.smartRenameModel = "anthropic/claude-sonnet-4-5"
                settings.smartRenameThinkingLevel = .low
            }
        )

        desktop.result.expectSubstantial()
        laptop.result.expectSubstantial()
        // The source picker label changes with the browsed companion, but the
        // naming preference is never part of catalog state.
        #expect(try pngData(desktop) != pngData(laptop))
        for render in [desktop, laptop] {
            #expect(render.settings.smartRenameModel == "anthropic/claude-sonnet-4-5")
            #expect(render.settings.smartRenameThinkingLevel == .low)
        }
    }

    @Test("Settings labels the saved HUD model as legacy rather than the new-chat default")
    func rendersLegacyHudModelCopy() async throws {
        let render = try await renderAgentsPane(
            named: "settings-legacy-hud-model.png",
            configure: { _ in }
        )
        render.result.expectSubstantial()
        let text = try recognizedText(render).lowercased()
        #expect(text.contains("legacy hud model"))
        #expect(text.contains("machine default"))
        #expect(text.contains("same as legacy hud model"))
        #expect(!text.contains("same as hud model"))
    }

    private struct AgentsPaneRender {
        let result: HerdrRenderHarness.RenderResult
        let settings: AgentModelSettingsStore
    }

    private func pngData(_ render: AgentsPaneRender) throws -> Data {
        try Data(contentsOf: render.result.url)
    }

    private func recognizedText(_ render: AgentsPaneRender) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.005
        try HerdrOCR.perform(request, url: render.result.url)
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    private func renderAgentsPane(
        named name: String,
        initialCatalogMachineID: String? = nil,
        settlePasses: Int = 8,
        configure: (AgentModelSettingsStore) -> Void
    ) async throws -> AgentsPaneRender {
        let suiteName = "SettingsRenderTests.smartRename.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = HerdrRenderFixtures.demoModel()
        let fontScale = HerdrFontScaleStore(defaults: defaults)
        let agentSettings = AgentModelSettingsStore(defaults: defaults)
        configure(agentSettings)
        // Tall enough that the whole Smart Rename section, including its
        // footer and any warning row, is captured rather than clipped.
        let result = try await HerdrRenderHarness.render(
            name,
            size: CGSize(width: 920, height: 1400),
            settlePasses: settlePasses
        ) {
            SettingsView(
                model: model,
                fontScale: fontScale,
                cleanupSettings: CleanupSettingsStore(defaults: defaults),
                agentSettings: agentSettings,
                promptSettings: HerdrPromptSettingsStore(defaults: defaults),
                modelFavorites: ModelFavoritesStore(userDefaults: defaults),
                hudController: HerdrHudController(userDefaults: defaults),
                updates: HerdrUpdateController(defaults: defaults),
                agentControl: AgentControlController(
                    defaults: defaults,
                    secretStorage: TestAgentControlSecretStorage()
                ),
                initialPane: .agents,
                initialSmartRenameCatalogMachineID: initialCatalogMachineID
            )
            .environment(\.herdrFontScale, fontScale.scale)
            .background(HerdrTheme.ink)
            .foregroundStyle(HerdrTheme.text)
            .preferredColorScheme(.dark)
            .tint(HerdrTheme.accent)
        }
        return AgentsPaneRender(result: result, settings: agentSettings)
    }

    private func luminanceStatistics(
        in bitmap: NSBitmapImageRep,
        columns: Range<Int>,
        rows: Range<Int>
    ) -> (mean: Double, maximum: Double) {
        var total = 0.0
        var maximum = 0.0
        var sampleCount = 0

        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 4) {
            for x in stride(from: columns.lowerBound, to: columns.upperBound, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let luminance = (0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent) * 255
                total += luminance
                maximum = max(maximum, luminance)
                sampleCount += 1
            }
        }

        #expect(sampleCount > 0)
        return (total / Double(max(sampleCount, 1)), maximum)
    }
}
