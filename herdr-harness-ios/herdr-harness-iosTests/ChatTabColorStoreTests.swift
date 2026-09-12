import Foundation
import Testing
@testable import herdr_harness_ios

@Suite("Local chat tab colors")
struct ChatTabColorStoreTests {
    @Test("Color identities, ordering, and RGB values remain stable")
    func stableColorCatalog() {
        #expect(ChatTabColor.allCases.map(\.rawValue) == [
            "lavender", "iris", "rose", "clay", "sage", "slate",
        ])
        #expect(ChatTabColor.allCases.map(\.symbol) == [
            "1.circle.fill", "2.circle.fill", "3.circle.fill",
            "4.circle.fill", "5.circle.fill", "6.circle.fill",
        ])
        #expect(ChatTabColor.allCases.map(\.rgb) == [
            0xB9A7DF, 0x969ED4, 0xCD9FAB, 0xC6AD96, 0x9DB9AE, 0x95B2C8,
        ])
    }

    @MainActor
    @Test("Assignments and shared labels reload from local defaults")
    func assignmentsAndLabelsPersist() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ChatTabColorStore(defaults: defaults)
        store.assign(.lavender, to: "desktop|w1:t1")
        #expect(store.rename(.lavender, to: "  Garden work  "))

        let reloaded = ChatTabColorStore(defaults: defaults)
        #expect(reloaded.color(for: "desktop|w1:t1") == .lavender)
        #expect(reloaded.label(for: .lavender) == "Garden work")
        #expect(reloaded.tabIDs(for: .lavender) == ["desktop|w1:t1"])
        #expect(reloaded.activeColors(tabIDs: ["desktop|w1:t1"]) == [.lavender])

        reloaded.assign(nil, to: "desktop|w1:t1")
        reloaded.resetLabel(.lavender)
        let cleared = ChatTabColorStore(defaults: defaults)
        #expect(cleared.color(for: "desktop|w1:t1") == nil)
        #expect(cleared.label(for: .lavender) == "Lavender")
    }

    @MainActor
    @Test("Machine-scoped tab IDs do not collide")
    func scopedAssignmentsDoNotCollide() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ChatTabColorStore(defaults: defaults)

        store.assign(.rose, to: "desktop|w1:t1")
        store.assign(.sage, to: "laptop|w1:t1")

        #expect(store.color(for: "desktop|w1:t1") == .rose)
        #expect(store.color(for: "laptop|w1:t1") == .sage)
    }

    @MainActor
    @Test("Invalid labels and unknown persisted values fall back safely")
    func validationAndUnknownValues() throws {
        #expect(ChatTabColorStore.validLabel("  Useful  ") == "Useful")
        #expect(ChatTabColorStore.validLabel("   ") == nil)
        #expect(ChatTabColorStore.validLabel(String(repeating: "a", count: 81)) == nil)
        #expect(ChatTabColorStore.validLabel("bad\u{0007}label") == nil)

        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [
                "assignments": ["desktop|w1:t1": "future-color"],
                "labels": ["lavender": "\n"],
            ],
            forKey: "herdr.chatTabColors.v1"
        )

        let store = ChatTabColorStore(defaults: defaults)
        #expect(store.color(for: "desktop|w1:t1") == nil)
        #expect(store.label(for: .lavender) == "Lavender")
        #expect(defaults.dictionary(forKey: "herdr.chatTabColors.v1") != nil)
    }

    @MainActor
    @Test("Sidebar reset clears local colors and the app defaults to Recents")
    func sidebarResetIsDeterministic() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let saved = ChatTabColorStore(defaults: defaults)
        saved.assign(.clay, to: "desktop|w1:t1")

        let model = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: ["-HerdrDemoMode", "-HerdrResetSidebarState"],
            userDefaults: defaults
        )

        #expect(model.sidebarRecency == .recents)
        #expect(model.chatTabColors.color(for: "desktop|w1:t1") == nil)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "chat-tab-colors-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
