import SwiftUI

/// Keeps finished outputs visible when a HUD run auto-opens the full card.
/// The same constellation used beside collapsed sessions docks to a small
/// agent core here, preserving one visual language across both HUD states.
struct HerdrHudExpandedResultStripView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var model: HerdrAppModel

    private var artifacts: [AgentResultArtifact] {
        model.unopenedResultArtifacts
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent outputs")
                    .herdrFont(size: 10, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(HerdrTheme.accent)
                Text("\(artifacts.count) unviewed")
                    .herdrFont(size: 9, relativeTo: .caption2)
                    .foregroundStyle(HerdrTheme.mist)
            }

            Spacer(minLength: 8)

            HerdrHudResultArtifactRailView(model: model, artifacts: artifacts)
            agentCore
        }
        .padding(.horizontal, HerdrTheme.cardPadding)
        .frame(height: 46)
        .background(HerdrTheme.graphite)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(HerdrTheme.separator)
                .frame(height: 1)
        }
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .top).combined(with: .opacity)
        )
        .accessibilityIdentifier("hud-expanded-result-strip")
    }

    private var agentCore: some View {
        ZStack {
            Circle()
                .fill(HerdrTheme.ink)
                .shadow(color: HerdrTheme.accent.opacity(0.42), radius: 6)
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [HerdrTheme.mauve, HerdrTheme.accent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(HerdrTheme.accent)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
