import SwiftUI

/// HUD run results belong to the orb. Pane outputs remain on their sessions.
struct HerdrHudOrbResultRow: View {
    @Bindable var model: HerdrAppModel
    let controller: HerdrHudController
    let session: HerdrHudSession
    let artifacts: [AgentResultArtifact]
    var attentionChipCount: Int = 0

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
                Button("Hide HUD", systemImage: "xmark") {
                    controller.setEnabled(false)
                }
                .labelStyle(.iconOnly)
                .herdrFont(.callout, weight: .bold)
                .foregroundStyle(HerdrTheme.text)
                .frame(width: 32, height: 32)
                .background(HerdrTheme.elevated, in: .circle)
                .overlay { Circle().strokeBorder(HerdrTheme.graphite, lineWidth: 3) }
                .contentShape(.circle)
                .buttonStyle(.plain)
                .help("Hide HUD. Restore it with Show HUD in the Herdr menu bar.")
                .accessibilityIdentifier("hud-quick-hide")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                if let voice = controller.quickVoice, voice.isEnabled {
                    QuickVoicePanelView(controller: voice, session: voice.session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .herdrHudHoverRegion("hud-orb", action: controller.setHoveringHud)
            .frame(width: HerdrHudPlacement.collapsedSize.width, height: HerdrHudPlacement.collapsedSize.height)
        }
    }
}
