import SwiftUI

/// Small color contract for the shared native-selection and Markdown renderer.
/// Chat uses Mono × Herdr's dark prose; lighter hosts (First Mate) override
/// every role without forking parsing, selection, quote, table, or code behavior.
struct ChatProsePalette: Equatable {
    /// Running prose: ink 78%.
    var text: Color
    var secondaryText: Color
    var accent: Color
    var separator: Color
    /// Bold runs and headings: full ink.
    var strong: Color = HerdrTheme.primaryText
    /// Inline and block code text.
    var code: Color = HerdrTheme.primaryText
    /// Inline code chips: ink 8%.
    var codeFill: Color = HerdrTheme.chipFill
    /// Code blocks and tables: ink 6%.
    var blockFill: Color = HerdrTheme.codeFill
    /// Block outlines: ink 10%.
    var blockOutline: Color = HerdrTheme.outline
    /// List markers, line numbers and code-block labels.
    var marker: Color = HerdrTheme.tertiaryText

    static let chat = Self(
        text: HerdrTheme.proseText,
        secondaryText: HerdrTheme.secondaryText,
        accent: HerdrTheme.accent,
        separator: HerdrTheme.outline
    )

    /// Reasoning text sits one step back from the answer.
    static let reasoning = Self(
        text: HerdrTheme.tertiaryText,
        secondaryText: HerdrTheme.tertiaryText,
        accent: HerdrTheme.accent,
        separator: HerdrTheme.outline
    )

    /// First Mate's prose in its own dark or MonoCode-light appearance.
    static func firstMate(_ palette: FirstMatePalette) -> Self {
        Self(
            text: palette.proseText,
            secondaryText: palette.secondaryText,
            accent: palette.accent,
            separator: palette.line,
            strong: palette.text,
            code: palette.text,
            codeFill: palette.chipFill,
            blockFill: palette.insetFill,
            blockOutline: palette.line,
            marker: palette.tertiaryText
        )
    }
}

extension EnvironmentValues {
    @Entry var chatProsePalette: ChatProsePalette = .chat
}
