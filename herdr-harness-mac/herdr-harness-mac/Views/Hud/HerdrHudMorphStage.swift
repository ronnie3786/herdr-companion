import SwiftUI

/// Draws one frame of the resting-circle ↔ orb morph around the real HUD.
///
/// The orb row and the agents block are the ordinary collapsed HUD views,
/// mounted here for the whole life of the collapsed state so their hover
/// regions, hit targets, and accessibility never change hands mid-animation.
/// At `.full` the stage is a plain pass-through. At `.rest` it draws the
/// resting circle pixel for pixel, so the root can swap in the real indicator
/// without a visible seam.
struct HerdrHudMorphStage<Orb: View, Agents: View>: View {
    let state: HerdrHudMorph.State
    let tone: HerdrHudNotificationPresentation.UltraCompactTone
    /// The resting circle's working pulse at the moment of hand-off, so a
    /// breathing signal does not snap to full opacity as it starts to grow.
    var pulseOpacity: Double = 1
    /// The 88 × 72 orb lane, possibly with its result rail on the left.
    @ViewBuilder let orbRow: () -> Orb
    /// Everything that hangs beneath the orb.
    @ViewBuilder let agents: () -> Agents

    var body: some View {
        VStack(alignment: .trailing, spacing: HerdrHudPlacement.chipSpacing) {
            ZStack(alignment: .topTrailing) {
                orbRow()
                    .opacity(HerdrHudMorph.faceOpacity(orb: state.orb))
                    .scaleEffect(faceScale, anchor: .topTrailing)
                    .offset(faceOffset)
                if state.orb < 1 {
                    rim
                        .frame(
                            width: HerdrHudPlacement.collapsedSize.width,
                            height: HerdrHudPlacement.collapsedSize.height
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            agents()
        }
    }

    private var faceScale: CGFloat { HerdrHudMorph.faceScale(orb: state.orb) }

    /// Scaling about the top-trailing corner keeps this independent of the
    /// row's width (the result rail widens it). The offset then puts the orb's
    /// centre exactly where the rim is: the orb centre `(W − 44, 28)` scaled
    /// lands at `(W − 44·s, 28·s)`, and the rim is at `(W − 44, centerY)`.
    private var faceOffset: CGSize {
        CGSize(
            width: -HerdrHudMorph.laneCenterX * (1 - faceScale),
            height: HerdrHudMorph.centerY(orb: state.orb) - HerdrHudMorph.orbCenterY * faceScale
        )
    }

    /// The status colour: a solid disc at rest, a rim once the orb has grown.
    private var rim: some View {
        let orb = state.orb
        let color = HerdrHudNotificationPresentation.ultraCompactColor(for: tone)
        let outer = HerdrHudMorph.ringOuterDiameter(orb: orb)
        return HerdrHudMorphRimShape(innerDiameter: outer - 2 * HerdrHudMorph.ringLineWidth(orb: orb))
            .fill(color, style: FillStyle(eoFill: true))
            .overlay {
                Circle().strokeBorder(
                    HerdrTheme.text.opacity(
                        HerdrHudMorph.hairlineOpacity(orb: orb, resting: tone == .offline ? 0.28 : 0.55)
                    ),
                    lineWidth: 1
                )
            }
            .frame(width: outer, height: outer)
            .shadow(
                color: color.opacity(HerdrHudMorph.glowOpacity(orb: orb)),
                radius: HerdrHudMorph.glowRadius(orb: orb)
            )
            .opacity(
                HerdrHudMorph.ringOpacity(orb: orb)
                    * HerdrHudMorph.pulseHandoff(orb: orb, pulse: pulseOpacity)
            )
            .position(x: HerdrHudMorph.laneCenterX, y: HerdrHudMorph.centerY(orb: orb))
    }
}

/// A disc with a hole, filled even-odd. A stroke wide enough to fill a circle
/// folds over itself at the centre and leaves a pinhole; this stays solid
/// until the opening is genuinely wider than zero.
struct HerdrHudMorphRimShape: Shape {
    var innerDiameter: CGFloat

    var animatableData: CGFloat {
        get { innerDiameter }
        set { innerDiameter = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(ellipseIn: rect)
        let inner = min(innerDiameter, min(rect.width, rect.height))
        if inner > 0 {
            path.addEllipse(in: CGRect(
                x: rect.midX - inner / 2,
                y: rect.midY - inner / 2,
                width: inner,
                height: inner
            ))
        }
        return path
    }
}

/// One agent chip's share of the unfurl: it slides down from under the orb,
/// growing from its top-trailing corner, and fades in as it settles.
private struct HerdrHudMorphChipReveal: ViewModifier {
    let reveal: Double

    func body(content: Content) -> some View {
        content
            .opacity(reveal)
            .scaleEffect(HerdrHudMorph.chipScale(reveal: reveal), anchor: HerdrHudMorph.chipAnchor)
            .offset(y: HerdrHudMorph.chipOffset(reveal: reveal))
    }
}

/// Companion surfaces beneath the chips settle with the block as a whole.
private struct HerdrHudMorphCompanionReveal: ViewModifier {
    let agents: Double

    func body(content: Content) -> some View {
        content
            .opacity(HerdrHudMorph.companionOpacity(agents: agents))
            .offset(y: HerdrHudMorph.companionOffset(agents: agents))
    }
}

extension View {
    func herdrHudMorphChipReveal(_ reveal: Double) -> some View {
        modifier(HerdrHudMorphChipReveal(reveal: reveal))
    }

    func herdrHudMorphCompanionReveal(_ agents: Double) -> some View {
        modifier(HerdrHudMorphCompanionReveal(agents: agents))
    }
}
