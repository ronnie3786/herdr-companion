import SwiftUI

struct HomeFocusCard: View {
    var item: HomeFocusItem
    var onCommand: (HomeCommand) -> Void
    @Environment(\.homeActionsEnabled) private var actionsEnabled
    @Environment(\.homeReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            HomeItemMark(symbol: item.symbol, emoji: item.emoji, watcherAvatar: item.watcherAvatar,
                         tone: item.tone, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    HomeFlowLayout(spacing: 10, lineSpacing: 4) {
                        Button(item.title) { onCommand(.open(item.route)) }
                            .herdrFont(size: 17, weight: .semibold).foregroundStyle(HomePalette.ink)
                            .buttonStyle(HomeButtonStyle())
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("home.focus.title")
                        Text(item.reason).herdrFont(size: 12.5, weight: .semibold)
                            .foregroundStyle(HomePalette.color(item.tone))
                    }
                    if actionsEnabled {
                    Button { onCommand(.ask("Tell me about \(item.title).", context: item.route)) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles").herdrFont(size: 13).foregroundStyle(HomePalette.accent)
                            Text("Ask about this").herdrFont(size: 12).foregroundStyle(HomePalette.secondary)
                        }
                        .padding(.horizontal, 8).frame(minHeight: 24)
                    }
                    .buttonStyle(HomeButtonStyle())
                    .fixedSize()
                    .accessibilityLabel("Ask about \(item.title)")
                    .accessibilityIdentifier("home.focus.ask")
                    }
                }
                HomeRichText(text: item.body, size: 15, lineSpacing: 7) { onCommand(.open($0)) }
                    .padding(.top, 6)
                if item.isStale {
                    Label("Last known state", systemImage: "clock.arrow.circlepath")
                        .herdrFont(size: 11.5).foregroundStyle(HomePalette.secondary).padding(.top, 8)
                }
                if !item.actions.isEmpty {
                    HomeFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(item.actions) { action in
                            HomeActionButton(action: action, onCommand: onCommand)
                                .accessibilityIdentifier("home.focus.\(item.id).\(action.id)")
                        }
                    }
                    .padding(.top, 16)
                }
            }
        }
        .padding(.vertical, 22).padding(.leading, 22).padding(.trailing, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(HomePalette.color(0x1F1D29).opacity(reduceTransparency ? 1 : 0.97))
                .overlay {
                    LinearGradient(stops: [.init(color: HomePalette.color(item.tone).opacity(0.09), location: 0),
                                           .init(color: .clear, location: 0.6)],
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(.rect(cornerRadius: 16))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomePalette.color(item.tone).opacity(0.32)))
        .shadow(color: .black.opacity(0.30), radius: 20, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.focus.card")
    }
}
