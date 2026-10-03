import SwiftUI

/// Bordered Home controls with both hover and keyboard focus affordances.
struct HomeButtonStyle: ButtonStyle {
    var fill: Color = .clear
    var hoverFill: Color = HomePalette.ink.opacity(0.06)
    var border: Color = .clear
    var hoverBorder: Color = .clear
    var radius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        HomeButtonSurface(configuration: configuration, style: self)
    }
}

private struct HomeButtonSurface: View {
    let configuration: ButtonStyleConfiguration
    let style: HomeButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(hovering || configuration.isPressed ? style.hoverFill : style.fill,
                        in: .rect(cornerRadius: style.radius))
            .overlay(RoundedRectangle(cornerRadius: style.radius)
                .strokeBorder(hovering ? style.hoverBorder : style.border, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: style.radius + 2)
                .strokeBorder(isFocused ? HomePalette.accent : .clear, lineWidth: 2)
                .padding(-3))
            .contentShape(.rect(cornerRadius: style.radius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .onHover { hovering = $0 }
    }
}
