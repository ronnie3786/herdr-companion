import SwiftUI

/// MonoCode's section label: 10/600 uppercase, tracked, tertiary, with an
/// optional detail at 11 on the right.
struct HerdrSectionLabel: View {
    let title: String
    var detail: String?
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .herdrFont(size: HerdrTheme.TextSize.micro, monospaced: monospaced, weight: .semibold)
                .tracking(0.6)
            Spacer(minLength: 12)
            if let detail {
                Text(detail)
                    .herdrFont(size: HerdrTheme.TextSize.caption, monospaced: monospaced)
            }
        }
        .foregroundStyle(HerdrTheme.tertiaryText)
        .accessibilityElement(children: .combine)
    }
}
