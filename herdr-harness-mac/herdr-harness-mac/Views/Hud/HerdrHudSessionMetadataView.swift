import SwiftUI

struct HerdrHudSessionMetadataView: View {
    let metadata: HerdrHudSessionMetadata
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.herdrHudShowsModel) private var showsModel

    var body: some View {
        ZStack(alignment: .trailing) {
            if let label = metadata.label(showsModel: showsModel) {
                Text(label)
                    .herdrFont(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(label)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(HerdrTheme.mist)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
        .help(metadata.accessibilitySummary)
        .accessibilityLabel(metadata.accessibilitySummary)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: showsModel)
    }
}
