import SwiftUI

/// Keyboard selection follows the rendered segments, including a Git segment
/// only while the selected pane has a repository. Nil means no navigation.
enum WorkspaceScopeKeyboardNavigation {
    static func nextSelection(
        after direction: MoveCommandDirection,
        current: HerdrDetailScope?,
        includesGit: Bool,
        isFocused: Bool,
        layoutDirection: LayoutDirection
    ) -> HerdrDetailScope? {
        guard isFocused else { return nil }
        let step: Int
        switch direction {
        case .left: step = layoutDirection == .rightToLeft ? 1 : -1
        case .right: step = layoutDirection == .rightToLeft ? -1 : 1
        default: return nil
        }
        let scopes = HerdrDetailScope.pickerCases(includingGit: includesGit)
        guard let current, let index = scopes.firstIndex(of: current) else {
            return step > 0 ? scopes.first : scopes.last
        }
        let nextIndex = index + step
        guard scopes.indices.contains(nextIndex) else { return nil }
        return scopes[nextIndex]
    }
}
