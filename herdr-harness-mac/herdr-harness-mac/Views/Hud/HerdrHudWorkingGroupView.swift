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
            chevronColor: HerdrTheme.mist
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
                        .herdrFont(.caption)
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
            .padding(.top, 10)
        } label: {
            label
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(HerdrTheme.elevated.opacity(0.2), in: RoundedRectangle(cornerRadius: HerdrTheme.compactRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                .strokeBorder(HerdrTheme.subtleSeparator, lineWidth: 1)
        }
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
                        .foregroundStyle(HerdrProse.dimmed(HerdrTheme.muted))
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)

            Text(isLive ? "Clanking…" : "Clanking")
                .herdrFont(.caption, weight: .medium)
                .foregroundStyle(HerdrProse.dimmed(HerdrTheme.mist))
                .contentTransition(.opacity)

            Text(stepSummary)
                .herdrFont(.caption)
                .foregroundStyle(HerdrProse.dimmed(HerdrTheme.muted))
                .lineLimit(1)
                .layoutPriority(1)
                .contentTransition(.opacity)

            if let latestStepTitle = steps.last?.title {
                Text("· \(latestStepTitle)")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrProse.dimmed(HerdrTheme.muted))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }

            if let failureSummary {
                Text("· \(failureSummary)")
                    .herdrFont(.caption)
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
                .herdrFont(.caption, weight: .semibold)
            if !step.detail.isEmpty {
                Text(step.detail)
                    .herdrFont(.caption, monospaced: true)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(step.isFailure ? HerdrTheme.alert : HerdrTheme.mist)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
