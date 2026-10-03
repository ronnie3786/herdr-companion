import Testing
@testable import herdr_harness_mac

@MainActor
struct HomeTabBadgeTests {
    @Test("A failed preparation keeps the review alert visible without unread reviews")
    func preparationFailure() {
        var snapshot = HomeSnapshot()
        snapshot.reviewNeedsAttention = true
        let badge = HomeTabStrip.badge(.reviews, snapshot: snapshot)
        #expect(badge?.text == "!")
        #expect(badge?.tone == .alert)
        snapshot.reviewCount = 2
        #expect(HomeTabStrip.badge(.reviews, snapshot: snapshot)?.text == "2")
        #expect(HomeTabStrip.badge(.reviews, snapshot: snapshot)?.tone == .alert)
        snapshot.reviewNeedsAttention = false
        #expect(HomeTabStrip.badge(.reviews, snapshot: snapshot)?.tone == .brandBlue)
        snapshot.reviewCount = 0
        #expect(HomeTabStrip.badge(.reviews, snapshot: snapshot) == nil)
    }
}
