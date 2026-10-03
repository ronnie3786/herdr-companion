import Foundation
import Testing
@testable import herdr_harness_mac

@MainActor
struct HomeShellTests {
    @Test("Four tabs retain the required order and keep utility destinations under Chats")
    func tabIdentity() {
        #expect(HomeTab.allCases == [.home, .reviews, .watchers, .chats])
        #expect(HomeTab(scope: .fleet) == .chats)
        #expect(HomeTab(scope: .firstMate) == .chats)
        #expect(HomeTab(scope: .git) == .chats)
    }

    @Test("The preview preference controls the initial screen and legacy Home routes")
    func optIn() {
        let suite = "HomeShellTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HerdrAppModel(credentials: TestCredentialStore(), arguments: [], userDefaults: defaults, configuredMachines: [])
        let legacy = HerdrShellState(userDefaults: defaults)
        #expect(!legacy.homeEnabled)
        legacy.show(.home, model: model)
        #expect(legacy.detailScope == .dashboard)
        defaults.set(true, forKey: HomePreferences.enabledKey)
        let preview = HerdrShellState(userDefaults: defaults)
        #expect(preview.detailScope == .home)
        for tab in HomeTab.allCases {
            preview.show(tab.scope, model: model)
            #expect(preview.detailScope == tab.scope)
        }
        preview.show(.fleet, model: model)
        preview.goHome(model: model)
        #expect(preview.detailScope == .home)
    }
}
