import SwiftUI
import Testing
@testable import herdr_harness_mac

@MainActor
@Suite("Workspace scope keyboard navigation")
struct WorkspaceScopeKeyboardNavigationTests {
    @Test("Arrow selection skips Git when the selected pane has no repository")
    func followsVisibleSegments() {
        #expect(next(.right, from: .session, includesGit: true) == .git)
        #expect(next(.right, from: .session, includesGit: false) == .workspace)
        #expect(next(.left, from: .workspace, includesGit: false) == .session)
    }

    @Test("End segments and vertical arrows do not dispatch another navigation")
    func stopsAtBoundaries() {
        #expect(next(.left, from: .session) == nil)
        #expect(next(.right, from: .activity) == nil)
        #expect(next(.up, from: .fleet) == nil)
        #expect(next(.down, from: .fleet) == nil)
    }

    @Test("Arrow keys cannot switch screens while focus belongs to the prompt")
    func ignoresUnfocusedInput() {
        #expect(next(.left, from: .workspace, isFocused: false) == nil)
        #expect(next(.right, from: .session, isFocused: false) == nil)
        #expect(next(.right, from: nil, isFocused: false) == nil)
    }

    @Test("Arrow movement follows the visual order in right-to-left layouts")
    func followsLayoutDirection() {
        #expect(next(.left, from: .session, layoutDirection: .rightToLeft) == .git)
        #expect(next(.right, from: .git, layoutDirection: .rightToLeft) == .session)
        #expect(next(.right, from: .session, layoutDirection: .rightToLeft) == nil)
    }

    private func next(
        _ direction: MoveCommandDirection,
        from current: HerdrDetailScope?,
        includesGit: Bool = true,
        isFocused: Bool = true,
        layoutDirection: LayoutDirection = .leftToRight
    ) -> HerdrDetailScope? {
        WorkspaceScopeKeyboardNavigation.nextSelection(
            after: direction,
            current: current,
            includesGit: includesGit,
            isFocused: isFocused,
            layoutDirection: layoutDirection
        )
    }
}
