import SwiftUI

struct FirstMateCoordinatorContextView: View {
    let feature: FirstMateFeature
    let capabilityAvailable: Bool

    @Environment(\.colorScheme) private var scheme
    @State private var showsDetails = false

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }
    private var presentation: FirstMateCoordinatorContextPresentation {
        .init(feature: feature, capabilityAvailable: capabilityAvailable)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.summary)
                    .herdrFont(.caption, weight: .medium)
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let pressure = presentation.pressure {
                    Text(pressure)
                        .herdrFont(.caption)
                        .foregroundStyle(pressure.contains("reached") ? .orange : palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button("Context details", systemImage: "info.circle") {
                showsDetails.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .help("How First Mate measures context and performs managed handoff")
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Coordinator context")
                        .herdrFont(.headline)
                    Text(presentation.summary)
                        .herdrFont(.callout)
                    if let pressure = presentation.pressure {
                        Text(pressure).herdrFont(.callout)
                    }
                    if let measurement = presentation.measurement {
                        Text(measurement)
                            .herdrFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(presentation.policy)
                        .herdrFont(.caption)
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
