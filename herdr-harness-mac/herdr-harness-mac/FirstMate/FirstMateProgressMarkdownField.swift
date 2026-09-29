import SwiftUI

/// A labeled worker-authored progress field. Labels remain structural chrome;
/// the value keeps the worker's Markdown without concatenating trusted labels
/// into that untrusted source.
struct FirstMateProgressMarkdownField: View {
    let label: String
    let source: String
    var emphasis = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = FirstMatePalette(scheme: scheme)
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .herdrFont(
                    size: emphasis ? HerdrTheme.TextSize.small : HerdrTheme.TextSize.caption,
                    weight: emphasis ? .semibold : .regular
                )
                .foregroundStyle(emphasis ? palette.text : palette.secondaryText)
            FirstMateMarkdownContentView(source: source)
                .environment(\.firstMateMarkdownDensity, .compact)
        }
    }
}
