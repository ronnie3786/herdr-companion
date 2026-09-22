import SwiftUI

struct PaneNavigationTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(HerdrTheme.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel("Pane title: \(title)")
            .accessibilityIdentifier("pane-session-title")
            .composerLayoutMeasurement(id: "pane-navigation-title", label: title)
    }
}
