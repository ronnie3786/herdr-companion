import SwiftUI

struct HomeRecap: View {
    var title: String
    var items: [HomeRecapItem]
    @Binding var isExpanded: Bool
    var onCommand: (HomeCommand) -> Void
    @Environment(\.homeReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock").herdrFont(size: 15).foregroundStyle(HomePalette.icon)
                    Text(title).herdrFont(size: 13, weight: .semibold).foregroundStyle(HomePalette.ink)
                    Text("\(items.count) updates").herdrFont(size: 13).foregroundStyle(HomePalette.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .herdrFont(size: 13).foregroundStyle(HomePalette.icon)
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
            }
            .buttonStyle(HomeButtonStyle(radius: 12))
            .accessibilityLabel("\(title), \(items.count) updates")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide recent updates")
            .accessibilityIdentifier("home.recap.disclosure")
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.timeLabel).herdrFont(size: 11.5).monospacedDigit()
                                .foregroundStyle(HomePalette.secondary).frame(width: 64, alignment: .leading)
                            Image(systemName: item.symbol).herdrFont(size: 13)
                                .foregroundStyle(HomePalette.color(item.tone)).frame(width: 16)
                                .accessibilityHidden(true)
                            HomeRichText(text: item.body, size: 12.5, lineSpacing: 5) { onCommand(.open($0)) }
                            if let route = item.route {
                                Button("Open update", systemImage: "arrow.up.right") { onCommand(.open(route)) }
                                    .labelStyle(.iconOnly).herdrFont(size: 11)
                                    .foregroundStyle(HomePalette.accent)
                                    .buttonStyle(HomeButtonStyle())
                                    .help("Open this update")
                                    .accessibilityLabel("Open update: \(item.body.plainText)")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("home.recap.row.\(item.id)")
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .background(reduceTransparency ? HomePalette.color(0x26242E) : HomePalette.ink.opacity(0.025), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HomePalette.hairline))
    }
}
