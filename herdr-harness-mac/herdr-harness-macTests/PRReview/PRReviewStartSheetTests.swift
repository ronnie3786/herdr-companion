import Foundation
import Testing
@testable import herdr_harness_mac

@Suite("PR Review start sheet") @MainActor
struct PRReviewStartSheetTests {
    @Test("Skill selection persists")
    func skillSelectionPersists() {
        let suite = "pr-review-sheet-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PRReviewStartSheet.saveSelection(["review", "utility"], defaults: defaults)
        #expect(PRReviewStartSheet.loadSelection(defaults: defaults) == ["review", "utility"])
    }
}
