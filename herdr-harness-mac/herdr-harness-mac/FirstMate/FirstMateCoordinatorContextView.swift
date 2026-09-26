import SwiftUI

/// The composer's context line (MonoCode's `.ctxline`): a 14pt ring, one
/// line of tertiary text, and an info button for the full measurement.
struct FirstMateCoordinatorContextView: View {
    let feature: FirstMateFeature
    let capabilityAvailable: Bool

    @State private var showsDetails = false

    private var presentation: FirstMateCoordinatorContextPresentation {
        .init(feature: feature, capabilityAvailable: capabilityAvailable)
    }

    var body: some View {
        let presentation = presentation
        HStack(spacing: 10) {
            HerdrProgressRing(fraction: presentation.fraction ?? 0, color: HerdrTheme.iconTint)
            Text(presentation.compactLine)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .foregroundStyle(presentation.pressureReached ? HerdrTheme.warning : HerdrTheme.tertiaryText)
                .lineLimit(1)
                .help([presentation.summary, presentation.pressure].compactMap { $0 }.joined(separator: "\n"))
            Spacer(minLength: 4)
            Button("Context details", systemImage: "info.circle") {
                showsDetails.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.mini))
            .help("How First Mate measures context and performs managed handoff")
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Coordinator context")
                        .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                        .foregroundStyle(HerdrTheme.primaryText)
                    Text(presentation.summary)
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .foregroundStyle(HerdrTheme.secondaryText)
                    if let pressure = presentation.pressure {
                        Text(pressure)
                            .herdrFont(size: HerdrTheme.TextSize.small)
                            .foregroundStyle(presentation.pressureReached ? HerdrTheme.warning : HerdrTheme.secondaryText)
                    }
                    if let measurement = presentation.measurement {
                        Text(measurement)
                            .herdrFont(size: HerdrTheme.TextSize.caption)
                            .foregroundStyle(HerdrTheme.tertiaryText)
                    }
                    Rectangle().fill(HerdrTheme.hairline).frame(height: 1)
                    Text(presentation.policy)
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 310)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-context")
    }
}
