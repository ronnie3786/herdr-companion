import SwiftUI

extension EnvironmentValues {
    @Entry var herdrHudShowsModel = true
}

/// One timeline supplies the phase to the entire stack, including overflow rows.
struct HerdrHudSessionMetadataClock: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.periodic(from: HerdrHudSessionMetadataCycle.epoch, by: HerdrHudSessionMetadataCycle.interval)) { context in
            content.environment(\.herdrHudShowsModel, HerdrHudSessionMetadataCycle.showsModel(at: context.date))
        }
    }
}
