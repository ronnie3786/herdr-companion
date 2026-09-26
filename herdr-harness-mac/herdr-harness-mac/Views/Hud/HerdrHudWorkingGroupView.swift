import SwiftUI

struct HerdrHudWorkingGroupView: View {
    let exchange: HerdrHudExchange
    var stepsOverride: [HerdrHudStep]?
    var interimResponse: String?
    var isLive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    private var steps: [HerdrHudStep] { stepsOverride ?? exchange.steps }
    private var failureCount: Int { steps.count(where: \.isFailure) }

    var body: some View {
        PiDisclosureCard(
            isExpanded: $isExpanded,
            chevronColor: HerdrTheme.iconTint
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps) { step in
                    HerdrHudWorkingStepRow(step: step)
                }
                if let interimResponse, !interimResponse.isEmpty {
                    PiMarkdownMessageView(
                        source: interimResponse,
                        isStreaming: isLive,
                        id: "hud-clanking-response-\(exchange.id)"
                    )
                    .textSelection(.enabled)
                }
                if exchange.stepsTruncated {
                    Text("first 200 steps shown")
                        .herdrFont(size: HerdrTheme.TextSize.caption)
                        .foregroundStyle(HerdrTheme.tertiaryText)
                }
            }
            .padding(.top, 10)
        } label: {
            label
        }
        // Unboxed, like the main chat's activity group.
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: isLive)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityIdentifier("hud-clanking-\(exchange.id)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var label: some View {
        HStack(spacing: 9) {
            ZStack {
                if isLive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.working)
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                } else {
                    Image(systemName: "terminal")
                        .herdrFont(size: 13)
                        .foregroundStyle(HerdrTheme.iconTint)
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                }
            }
            .herdrIconSlot(width: 16, height: 16)
            .accessibilityHidden(true)

            Text(isLive ? "Clanking…" : "Clanking")
                .herdrFont(size: HerdrTheme.TextSize.body, weight: .medium)
                .foregroundStyle(HerdrTheme.secondaryText)
                .contentTransition(.opacity)

            Text(stepSummary)
                .herdrFont(size: HerdrTheme.TextSize.caption)
                .foregroundStyle(HerdrProse.dimmed(HerdrTheme.tertiaryText))
                .lineLimit(1)
                .layoutPriority(1)
                .contentTransition(.opacity)

            if let latestStepTitle = steps.last?.title {
                Text("· \(latestStepTitle)")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrProse.dimmed(HerdrTheme.tertiaryText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }

            if let failureSummary {
                Text("· \(failureSummary)")
                    .herdrFont(size: HerdrTheme.TextSize.caption)
                    .foregroundStyle(HerdrTheme.alert)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Clanking, \(summary)")
        .accessibilityHint("Shows Pi's thinking and tool activity")
    }

    private var stepSummary: String {
        if steps.isEmpty {
            return interimResponse?.isEmpty == false ? "Responding" : "Thinking"
        }
        return "\(steps.count) step\(steps.count == 1 ? "" : "s")"
    }

    private var failureSummary: String? {
        failureCount > 0 ? "\(failureCount) failed" : nil
    }

    private var summary: String {
        var parts = [stepSummary]
        if let latest = steps.last { parts.append(latest.title) }
        if let failureSummary { parts.append(failureSummary) }
        return parts.joined(separator: " · ")
    }
}

private struct HerdrHudWorkingStepRow: View {
    let step: HerdrHudStep

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(step.title, systemImage: step.symbol)
                .herdrFont(size: HerdrTheme.TextSize.small, weight: .medium)
                .foregroundStyle(step.isFailure ? HerdrTheme.alert : HerdrTheme.secondaryText)
            if !step.detail.isEmpty {
                Text(step.detail)
                    .herdrFont(size: HerdrTheme.TextSize.small, monospaced: true)
                    .foregroundStyle(step.isFailure ? HerdrTheme.alert : HerdrTheme.tertiaryText)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
