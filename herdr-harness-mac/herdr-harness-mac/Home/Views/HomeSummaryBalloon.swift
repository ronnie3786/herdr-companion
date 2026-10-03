import SwiftUI

struct HomeSummaryBalloon: View {
    var snapshot: HomeSnapshot
    var onCommand: (HomeCommand) -> Void
    @Environment(\.homeReduceTransparency) private var reduceTransparency
    @Environment(\.homeReduceMotion) private var reduceMotion

    private var narrative: HomeText {
        HomeText(runs: snapshot.summary.enumerated().flatMap { index, sentence in
            (index == 0 ? [] : [HomeTextRun.text(" ")]) + sentence.runs
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(snapshot.greeting)
                .herdrFont(size: 30, weight: .semibold).tracking(-0.66)
                .foregroundStyle(HomePalette.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.greeting")
            if !snapshot.dateLine.isEmpty {
                Text(snapshot.dateLine).herdrFont(size: 12.5)
                    .foregroundStyle(HomePalette.secondary).padding(.top, 7)
            }
            HomeRichText(text: narrative, size: 16.5, lineSpacing: 9) { onCommand(.open($0)) }
                .padding(.top, 14)
            if snapshot.isLoading {
                HStack(spacing: 8) {
                    if reduceMotion {
                        Image(systemName: "circle.dotted").foregroundStyle(HomePalette.secondary)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Checking current work…").herdrFont(size: 12.5).foregroundStyle(HomePalette.secondary)
                }
                .padding(.top, 12)
            }
            if snapshot.availability == .noMachines {
                Label("Connect a machine to get started", systemImage: "desktopcomputer")
                    .herdrFont(size: 12.5).foregroundStyle(HomePalette.secondary).padding(.top, 12)
            }
            if !snapshot.coverageLine.isEmpty {
                Text(snapshot.coverageLine).herdrFont(size: 11.5)
                    .foregroundStyle(HomePalette.secondary).padding(.top, 10)
                    .accessibilityIdentifier("home.coverage")
            }
            ForEach(Array(snapshot.notices.enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "info.circle")
                    .herdrFont(size: 12.5).foregroundStyle(HomePalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if !snapshot.moving.plainText.isEmpty {
                Rectangle().fill(HomePalette.hairline).frame(height: 1).padding(.top, 14)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sailboat").herdrFont(size: 15)
                        .foregroundStyle(HomePalette.icon).padding(.top, 3)
                    HomeRichText(text: snapshot.moving, size: 13, lineSpacing: 6) { onCommand(.open($0)) }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 26).padding(.horizontal, 30).padding(.bottom, 22)
        .background(reduceTransparency ? HomePalette.color(0x302D38) : HomePalette.ink.opacity(0.05), in: .rect(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(HomePalette.border, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            HomeBalloonTail().fill(HomePalette.ink.opacity(0.09))
                .frame(width: 11, height: 20).offset(x: -11, y: 74)
                .accessibilityHidden(true)
        }
    }
}

private struct HomeBalloonTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
