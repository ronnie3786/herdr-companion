import SwiftUI

struct DashboardFocusToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("Focus mode", isOn: $isOn)
            .toggleStyle(.switch).controlSize(.small)
            .herdrFont(.subheadline).fixedSize()
            .tint(HerdrTheme.controlAccent)
            .help("Show only First Mates, reviews, and chats waiting for you")
            .accessibilityIdentifier("dashboard-focus-mode")
    }
}
