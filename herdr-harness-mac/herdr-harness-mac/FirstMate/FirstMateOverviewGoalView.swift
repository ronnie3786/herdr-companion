import SwiftUI

/// The complete feature goal, including any structured Markdown supplied by
/// the person or retained from planning. This intentionally does not summarize
/// or strip the source: headings, lists, links, code, and tables are useful
/// context in the Overview.
struct FirstMateOverviewGoalView: View {
    let source: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HerdrMicroLabel(text: "Goal")
            if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No goal added yet.")
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .foregroundStyle(FirstMatePalette(scheme: scheme).tertiaryText)
            } else {
                FirstMateMarkdownContentView(source: source)
                    .environment(\.firstMateMarkdownDensity, .compact)
            }
        }
        .accessibilityIdentifier("first-mate-goal-markdown")
    }
}
