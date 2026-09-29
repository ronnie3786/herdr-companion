import Foundation
import SwiftUI
import Testing
@testable import herdr_harness_mac

extension ChatFixtures {
    @MainActor
    static func model(demo: Bool) -> HerdrAppModel {
        let name = "FirstMateChatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: demo ? ["HerdrTests", "-HerdrDemoMode", "-HerdrResetSidebarState"] : ["HerdrTests"],
            userDefaults: defaults,
            configuredMachines: []
        )
    }
    @MainActor
    static func shell() -> HerdrShellState {
        let name = "FirstMateChatTests.shell.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return HerdrShellState(userDefaults: defaults)
    }
}
