import SwiftUI

/// The Chat navigator's PR Review entry with its walkthrough badge.
///
/// The count is the active reviews on the review host whose newest
/// walkthrough finished, or failed, while nobody had that review open.
/// Opening the review clears its share of the count.
struct PRReviewNavigationButton: View {
    var readyCount: Int = 0
    let action: () -> Void
    @State private var isHovering = false

    static func accessibilityValue(for count: Int) -> String {
        switch count {
        case ..<1: "No new walkthroughs"
        case 1: "1 new walkthrough"
        default: "\(count) new walkthroughs"
        }
    }

    static func helpText(for count: Int) -> String {
        switch count {
        case ..<1: "Open PR Review."
        case 1: "Open PR Review. 1 walkthrough finished while you were away."
        default: "Open PR Review. \(count) walkthroughs finished while you were away."
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                SidebarNavRowLabel(title: "PR Review", systemImage: "arrow.triangle.pull")
                if let badgeText = FirstMateNavigationButton.badgeText(for: readyCount) {
                    Text(badgeText)
                        .herdrFont(size: 10, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.onBadge)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(HerdrTheme.badgeFill, in: .capsule)
                        .padding(.trailing, 8)
                        // The button's value announces the exact count.
                        .accessibilityHidden(true)
                }
            }
            .herdrRowBackground(selected: false, hovered: isHovering)
        }
        .buttonStyle(.herdrPlain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("PR Review")
        .accessibilityValue(Self.accessibilityValue(for: readyCount))
        .help(Self.helpText(for: readyCount))
    }
}
