import SwiftUI

/// The persisted HUD resting surface. Its visible status circle stays tiny,
/// while the surrounding frame retains a Mac-sized pointer target.
struct HerdrHudUltraCompactIndicator: View {
    let controller: HerdrHudController
    let tone: HerdrHudNotificationPresentation.UltraCompactTone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if tone == .working, !reduceMotion {
                TimelineView(.periodic(from: .now, by: HerdrHudOrbMotion.timelineCadence)) { context in
                    indicator(opacity: HerdrHudOrbMotion.workingOpacity(at: context.date))
                }
            } else {
                indicator(opacity: 1)
            }
        }
        .frame(
            width: HerdrHudPlacement.ultraCompactHitTargetSize,
            height: HerdrHudPlacement.ultraCompactHitTargetSize
        )
        .contentShape(Circle())
        .herdrHudHoverRegion("hud-ultra-compact", action: controller.setHoveringHud)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Herdr ultra-compact HUD")
        .accessibilityValue(HerdrHudNotificationPresentation.ultraCompactAccessibilityValue(for: tone))
        .accessibilityHint("Hover to preview the HUD. Activate to open chat.")
        .accessibilityAction { controller.summon() }
        .accessibilityIdentifier("hud-ultra-compact-indicator")
    }

    private func indicator(opacity: Double) -> some View {
        let color = HerdrHudNotificationPresentation.ultraCompactColor(for: tone)
        return Circle()
            .fill(color)
            .overlay {
                Circle()
                    .strokeBorder(HerdrTheme.text.opacity(tone == .offline ? 0.28 : 0.55), lineWidth: 1)
            }
            .shadow(color: color.opacity(0.9), radius: 6)
            .shadow(color: color.opacity(0.45), radius: 10)
            .opacity(opacity)
            .frame(
                width: HerdrHudPlacement.ultraCompactIndicatorSize,
                height: HerdrHudPlacement.ultraCompactIndicatorSize
            )
            .accessibilityHidden(true)
    }
}
