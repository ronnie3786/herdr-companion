import SwiftUI

struct FirstMateProjectNotice: View {
    let text: String
    var warning = false

    var body: some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
            .herdrFont(size: HerdrTheme.TextSize.small)
            .foregroundStyle(warning ? HerdrTheme.warning : HerdrTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HerdrTheme.insetFill, in: .rect(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }
}
