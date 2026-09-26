import SwiftUI

struct ConnectionPill: View {
    let state: ConnectionState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
            .foregroundStyle(state.color)
            .lineLimit(1)
            .fixedSize()
            .frame(minHeight: HerdrTheme.minHitTarget)
            .accessibilityLabel("Server \(state.title)")
    }
}
