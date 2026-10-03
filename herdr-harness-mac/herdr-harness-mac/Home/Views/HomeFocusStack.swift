import SwiftUI

struct HomeFocusStack: View {
    var items: [HomeFocusItem]
    var selectedID: String?
    var onSelect: (String) -> Void
    var onCommand: (HomeCommand) -> Void
    @Environment(\.homeActionsEnabled) private var actionsEnabled

    private var selectedIndex: Int { items.firstIndex { $0.id == selectedID } ?? 0 }
    private var depth: Int { min(2, max(0, items.count - 1)) }
    private var nextItems: [HomeFocusItem] {
        guard items.count > 1 else { return [] }
        return (1...min(2, items.count - 1)).map { items[(selectedIndex + $0) % items.count] }
    }

    var body: some View {
        if !items.isEmpty {
            let item = items[selectedIndex]
            VStack(alignment: .leading, spacing: 18) {
                HomeFocusCard(item: item, onCommand: onCommand)
                    .background {
                        if depth > 1 { HomeStackLayer(scale: 0.93, offset: 20, opacity: 0.45) }
                        if depth > 0 { HomeStackLayer(scale: 0.965, offset: 10, opacity: 0.75) }
                    }
                    .padding(.bottom, CGFloat(depth) * 10)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HomeFlowLayout(spacing: 10, lineSpacing: 6) {
                        Text(items.count == 1 ? "Just this one" : "\(item.isIdea ? "Idea" : "Up next") \(selectedIndex + 1) of \(items.count)")
                            .herdrFont(size: 12.5, weight: .semibold).foregroundStyle(HomePalette.ink)
                        if !nextItems.isEmpty {
                            Text("Then").herdrFont(size: 12.5).foregroundStyle(HomePalette.secondary)
                            ForEach(nextItems) { next in
                                Button(next.title) { onSelect(next.id) }
                                    .herdrFont(size: 12.5).foregroundStyle(HomePalette.accent)
                                    .buttonStyle(HomeButtonStyle())
                                    .accessibilityLabel("Show next focus: \(next.title)")
                            }
                        }
                    }
                    if actionsEnabled && items.count > 1 {
                        Button { onCommand(.skip) } label: {
                            HStack(spacing: 4) {
                                Text("Skip for now")
                                Image(systemName: "chevron.right").imageScale(.small)
                            }
                            .herdrFont(size: 12.5, weight: .semibold).foregroundStyle(HomePalette.accent)
                            .padding(.vertical, 3)
                        }
                        .fixedSize().buttonStyle(HomeButtonStyle())
                        .accessibilityIdentifier("home.focus.skip")
                    }
                }
            }
        }
    }
}

private struct HomeStackLayer: View {
    var scale: CGFloat
    var offset: CGFloat
    var opacity: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(HomePalette.color(0x282634).opacity(0.6))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(HomePalette.border))
            .scaleEffect(scale).offset(y: offset).opacity(opacity)
            .accessibilityHidden(true)
    }
}
