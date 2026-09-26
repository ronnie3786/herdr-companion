import SwiftUI

struct PiConversationNoticeView: View {
    let notice: PiConversationNotice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(tint)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                    .foregroundStyle(HerdrTheme.primaryText)
                if let detail = notice.detail, !detail.isEmpty {
                    Text(detail)
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .lineLimit(4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .herdrCard(radius: HerdrTheme.Radius.control, fill: tint.opacity(0.08), outline: tint.opacity(0.22))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice.tone {
        case .neutral: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var tint: Color {
        switch notice.tone {
        case .neutral: HerdrTheme.accent
        case .warning: HerdrTheme.warning
        case .error: HerdrTheme.alert
        }
    }
}
