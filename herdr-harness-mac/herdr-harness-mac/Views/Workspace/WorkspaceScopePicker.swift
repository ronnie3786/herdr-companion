import SwiftUI

/// Stable native chrome for the app's destinations. A small rectangular strip
/// keeps the selected surface visible without the toolbar's enclosing glass pill.
struct WorkspaceScopePicker: View {
    @Binding var selection: HerdrDetailScope?
    let includesGit: Bool
    let unreadAlertCount: Int
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(HerdrDetailScope.pickerCases(includingGit: includesGit)) { scope in
                WorkspaceScopeSegment(
                    scope: scope,
                    isSelected: selection == scope,
                    unreadCount: scope == .attention ? unreadAlertCount : 0,
                    action: { selection = scope }
                )
            }
        }
        .padding(2)
        .background(HerdrTheme.graphite, in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(HerdrTheme.subtleSeparator, lineWidth: 1)
        }
        .contentShape(.rect(cornerRadius: 7))
        // One keyboard stop, like a native segmented picker. Pointer selection
        // does not move focus out of the prompt; Tab opts into arrow navigation.
        .focusable(interactions: .activate)
        .focused($isFocused)
        .onMoveCommand(perform: moveSelection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace views")
        .accessibilityIdentifier("detail-scope-picker")
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard let next = WorkspaceScopeKeyboardNavigation.nextSelection(
            after: direction,
            current: selection,
            includesGit: includesGit,
            isFocused: isFocused,
            layoutDirection: layoutDirection
        ) else { return }
        selection = next
    }
}
