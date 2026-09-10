import SwiftUI

/// HUD run results belong to the orb. Pane outputs remain on their sessions.
struct HerdrHudOrbResultRow: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession
    let artifacts: [AgentResultArtifact]
    var attentionChipCount: Int = 0
    var notes: HerdrHudNotesState?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if !artifacts.isEmpty {
                HerdrHudResultArtifactRailView(
                    model: model,
                    artifacts: artifacts,
                    expandsTitles: controller.areAttachmentTitlesExpanded,
                    hoverRegionID: "hud-results",
                    onHoverHud: controller.setHoveringHud
                )
            }

            ZStack(alignment: .topLeading) {
                HerdrHudOrbView(
                    model: model,
                    controller: controller,
                    session: session,
                    attentionChipCount: attentionChipCount
                )
                .frame(width: 56, height: 56)
                orbControls
                .opacity(controller.areOrbControlsVisible ? 1 : 0)
                .allowsHitTesting(controller.areOrbControlsVisible)
                .accessibilityHidden(!controller.areOrbControlsVisible)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: controller.areOrbControlsVisible)
            }
            .herdrHudHoverRegion("hud-orb", action: controller.setHoveringHud)
            .frame(width: HerdrHudPlacement.collapsedSize.width, height: HerdrHudPlacement.collapsedSize.height)
        }
    }

    @ViewBuilder
    private var orbControls: some View {
        Button("Hide HUD", systemImage: "xmark") {
            controller.setEnabled(false)
        }
        .labelStyle(.iconOnly)
        .herdrFont(.callout, weight: .bold)
        .foregroundStyle(HerdrTheme.text)
        .frame(width: 32, height: 32)
        .background(HerdrTheme.elevated, in: .circle)
        .overlay { Circle().strokeBorder(HerdrTheme.graphite, lineWidth: 3) }
        .scaleEffect(0.625 * HerdrHudPlacement.orbControlScale)
        .contentShape(.circle)
        .buttonStyle(.plain)
        .offset(y: -4)
        .help("Hide HUD. Restore it with Show HUD in the Herdr menu bar.")
        .accessibilityIdentifier("hud-quick-hide")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

        if let notes, notes.layout != .hidden {
            HerdrNotesToggleButton(notes: notes)
                .scaleEffect(HerdrHudPlacement.orbControlScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        if let voice = controller.quickVoice, voice.isEnabled {
            QuickVoicePanelView(controller: voice, session: voice.session)
                .scaleEffect(HerdrHudPlacement.orbControlScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}
