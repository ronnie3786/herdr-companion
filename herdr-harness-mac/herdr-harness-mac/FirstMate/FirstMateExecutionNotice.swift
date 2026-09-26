import SwiftUI

/// An execution warning strip above the composer: warning text on a warning
/// wash, under a hairline.
struct FirstMateExecutionNotice: View {
    let text: String
    var lastSuccessAt: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: "exclamationmark.triangle")
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                .foregroundStyle(HerdrTheme.warning)
            if let lastSuccessAt {
                Text("Last successful monitoring pass: \(lastSuccessAt)")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.tertiaryText)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HerdrTheme.warning.opacity(0.08))
        .herdrHairline(.top)
        .accessibilityIdentifier("first-mate-execution-notice")
    }
}
