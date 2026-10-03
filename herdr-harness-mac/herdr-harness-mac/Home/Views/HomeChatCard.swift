import SwiftUI

struct HomeChatCard: View {
    var item: HomeChatItem
    var onCommand: (HomeCommand) -> Void
    @Environment(\.homeReduceTransparency) private var reduceTransparency
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onCommand(.open(item.route)) } label: {
                HStack(spacing: 8) {
                    Circle().fill(HomePalette.color(hex: item.colorHex)).frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(item.title).herdrFont(size: 13.5, weight: .semibold).foregroundStyle(HomePalette.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HomeButtonStyle())
            .accessibilityLabel("Open chat: \(item.title)")
            HomeFlowLayout(spacing: 5, lineSpacing: 3) {
                Text(item.reason).herdrFont(size: 11.5, weight: item.isWaiting ? .semibold : .regular)
                    .foregroundStyle(item.isWaiting ? HomePalette.attention : HomePalette.secondary)
                Text("· \(item.location)").herdrFont(size: 11.5).foregroundStyle(HomePalette.secondary)
                if item.isStale { Text("· Last known state").herdrFont(size: 11.5).foregroundStyle(HomePalette.secondary) }
            }
            .padding(.leading, 17).padding(.top, 3)
            if !item.quote.isEmpty {
                Text(item.quote).herdrFont(size: 13).lineSpacing(5).foregroundStyle(HomePalette.prose)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(HomePalette.ink.opacity(0.12)).frame(width: 2) }
                    .padding(.leading, 17).padding(.top, 9)
            }
            if !item.actions.isEmpty {
                HomeFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(item.actions) { action in
                        HomeActionButton(action: action, compact: true, onCommand: onCommand)
                    }
                }
                .padding(.leading, 17).padding(.top, 11)
            }
            HomeQuickReplyView(route: item.route, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(reduceTransparency ? HomePalette.color(0x282630) : HomePalette.ink.opacity(0.035), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovering ? HomePalette.border : HomePalette.hairline))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.chat.\(item.id)")
    }
}
