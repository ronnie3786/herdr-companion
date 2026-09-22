import SwiftUI

/// Small color contract for the shared native-selection and Markdown renderer.
/// Chat keeps its existing dark defaults; lighter hosts can override prose
/// without forking parsing, selection, quote, table, or code behavior.
struct ChatProsePalette: Equatable {
    var text: Color
    var secondaryText: Color
    var accent: Color
    var separator: Color

    static let chat = Self(
        text: HerdrTheme.text,
        secondaryText: HerdrTheme.mist,
        accent: HerdrTheme.accent,
        separator: HerdrTheme.separator
    )
}

extension EnvironmentValues {
    @Entry var chatProsePalette: ChatProsePalette = .chat
}
