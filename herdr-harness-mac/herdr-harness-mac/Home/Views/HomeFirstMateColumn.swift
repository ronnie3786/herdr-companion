import SwiftUI

struct HomeFirstMateColumn: View {
    var snapshot: HomeSnapshot
    var isVisible: Bool
    var onCommand: (HomeCommand) -> Void
    @Environment(\.homeActionsEnabled) private var actionsEnabled

    var body: some View {
        VStack(spacing: 0) {
            Button { onCommand(actionsEnabled ? .ask("", context: nil) : .open(.firstMateLead)) } label: {
                HomeAvatar(mood: snapshot.mood, size: HomeGeometry.avatar, showsRing: true, animated: isVisible)
            }
            .buttonStyle(HomeButtonStyle(radius: 84))
            .accessibilityLabel("Talk to My First Mate")
            .accessibilityIdentifier("home.firstMate.face")
            Text("My First Mate")
                .herdrFont(size: 17, weight: .semibold)
                .tracking(-0.17)
                .foregroundStyle(HomePalette.ink)
                .padding(.top, 16)
            Text(snapshot.statusLine)
                .herdrFont(size: 12.5)
                .lineSpacing(3)
                .foregroundStyle(HomePalette.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 250)
                .padding(.top, 4)
            Button { onCommand(.open(.firstMateLead)) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sailboat")
                        .herdrFont(size: 16)
                        .foregroundStyle(HomePalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open First Mate").herdrFont(size: 13, weight: .semibold).foregroundStyle(HomePalette.ink)
                        Text(snapshot.firstMateStatus).herdrFont(size: 11.5).foregroundStyle(HomePalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "arrow.up.right").herdrFont(size: 12).foregroundStyle(HomePalette.icon)
                }
                .padding(.vertical, 9).padding(.leading, 13).padding(.trailing, 12)
                .frame(width: 240, alignment: .leading)
            }
            .buttonStyle(HomeButtonStyle(fill: HomePalette.ink.opacity(0.04), hoverFill: HomePalette.accentWash,
                                          border: HomePalette.border, hoverBorder: HomePalette.accentLine, radius: 12))
            .padding(.top, 16)
            .accessibilityLabel("Open First Mate window. \(snapshot.firstMateStatus)")
            .accessibilityIdentifier("home.firstMate.window")
            if !snapshot.radar.isEmpty {
                VStack(spacing: 10) {
                    Text("ON MY RADAR")
                        .herdrFont(size: 11, weight: .semibold).tracking(0.66)
                        .foregroundStyle(HomePalette.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(snapshot.radar) { item in
                        HomeRadarCard(item: item, onCommand: onCommand)
                    }
                }
                .padding(.top, 24)
            }
        }
    }
}
