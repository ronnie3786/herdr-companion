import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
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
