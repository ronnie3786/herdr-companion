import SwiftUI

struct HerdrHudSessionMetadataView: View {
    let metadata: HerdrHudSessionMetadata
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.herdrHudReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.herdrHudShowsModel) private var showsModel

    private var reduceMotion: Bool {
        Self.usesReducedMotion(systemValue: systemReduceMotion, override: reduceMotionOverride)
    }

    /// Resolves the fade's reduced-motion state. Production passes the system
    /// value and no override; render tests pass an explicit override so the
    /// offscreen fade branch is deterministic.
    static func usesReducedMotion(systemValue: Bool, override: Bool?) -> Bool {
        override ?? systemValue
    }

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
