import SwiftUI

struct HomeWaitingChats: View {
    var title: String
    var items: [HomeChatItem]
    var onCommand: (HomeCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).herdrFont(size: 13.5, weight: .semibold).foregroundStyle(HomePalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(items.count.formatted()).herdrFont(size: 11, weight: .semibold)
                    .foregroundStyle(HomePalette.secondary)
                    .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 18)
                    .background(HomePalette.ink.opacity(0.1), in: .capsule)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: HomeGeometry.chatMinimum), spacing: 10, alignment: .top)],
                      alignment: .leading, spacing: 10) {
                ForEach(items) { item in HomeChatCard(item: item, onCommand: onCommand) }
            }
        }
    }
}
