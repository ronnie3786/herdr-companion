import SwiftUI

struct FirstMateMarkdownText: View {
    let source: String
    let role: HerdrProse.Role
    let color: Color?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.herdrFontScale) private var fontScale

    init(_ source: String, role: HerdrProse.Role, color: Color? = nil) {
        self.source = source
        self.role = role
        self.color = color
    }

    var body: some View {
        let palette = FirstMatePalette(scheme: scheme)
        let rendered = PiMarkdownInlineCache.shared.rendered(source)
        let styled = PiMarkdownInlineCache.shared.styled(
            rendered,
            source: source,
            font: HerdrProse.inlineCodeFont(role, scale: fontScale),
            color: palette.secondaryText
        )
        Text(styled)
            .font(HerdrProse.font(role, scale: fontScale))
            .foregroundStyle(color ?? palette.text)
            .tint(palette.accent)
            .textSelection(.enabled)
    }
}
