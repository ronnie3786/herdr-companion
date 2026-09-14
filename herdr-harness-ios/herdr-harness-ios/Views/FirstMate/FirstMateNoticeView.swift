import SwiftUI

struct FirstMateNoticeView: View {
    let title: String
    let message: String
    let symbol: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(FirstMatePalette(scheme: scheme).secondaryText)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FirstMatePalette(scheme: scheme).surface, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
