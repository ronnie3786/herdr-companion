import SwiftUI

struct HerdrSectionLabel: View {
    let title: String
    var detail: String?
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .fontWeight(.medium)
            Spacer(minLength: 12)
            if let detail {
                Text(detail)
                    .foregroundStyle(HerdrTheme.mist)
            }
        }
        .herdrFont(.subheadline, monospaced: monospaced)
        .foregroundStyle(HerdrTheme.mist)
        .accessibilityElement(children: .combine)
    }
}
