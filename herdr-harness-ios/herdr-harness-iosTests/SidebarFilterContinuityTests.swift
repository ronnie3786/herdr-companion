import Foundation
import Testing
@testable import herdr_harness_ios

@MainActor
@Suite("Sidebar filter continuity")
struct SidebarFilterContinuityTests {
    @Test("Search and color survive drawer dismissal but reset on relaunch")
    func transientFilterLifetime() throws {
        let suiteName = "SidebarFilterContinuityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let model = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: ["-HerdrDemoMode"],
            userDefaults: defaults
        )
        model.sidebarQuery = "indented request"
        model.sidebarColorFilter = .iris
        model.isSidebarPresented = true
        model.isSidebarPresented = false

        #expect(model.sidebarQuery == "indented request")
        #expect(model.sidebarColorFilter == .iris)

        let relaunched = HerdrAppModel(
            credentials: TestCredentialStore(),
            arguments: ["-HerdrDemoMode"],
            userDefaults: defaults
        )
        #expect(relaunched.sidebarQuery.isEmpty)
        #expect(relaunched.sidebarColorFilter == nil)
    }
}
