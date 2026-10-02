import SwiftUI

struct SkimReplyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SkimReplyButtonBody(configuration: configuration)
    }
}

private struct SkimReplyButtonBody: View {
    let configuration: SkimReplyButtonStyle.Configuration
    @Environment(\.chatProsePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? palette.accent : palette.secondaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .frame(minHeight: HerdrTheme.minHitTarget)
            .background(palette.codeFill, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                    .strokeBorder(isEnabled && (hovering || configuration.isPressed) ? palette.accent : palette.separator,
                                  lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: HerdrTheme.Radius.control))
            .onHover { hovering = $0 }
    }
}
