import SwiftUI

/// Collapses a contiguous run of Pi's sub-process activity, thinking and
/// tool/command invocations, behind one "Clanking…" row, so consecutive
/// assistant messages read as a conversation instead of a machine log.
/// Collapsed by default; the individual `PiThinkingDisclosureView` /
/// `PiToolCardView` cards inside keep their own per-card disclosure.
/// Built on `PiDisclosureCard`, never `DisclosureGroup` (see that type).
struct PiWorkingGroupView: View {
    let group: PiWorkingGroup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hapticPulse = HerdrHapticPulse()

    init(group: PiWorkingGroup, initiallyExpanded: Bool = false) {
        self.group = group
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        PiDisclosureCard(
            isExpanded: $isExpanded,
            chevronColor: chevronColor
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(group.items) { item in
                    PiConversationItemView(item: item)
                        .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.top, 10)
        } label: {
            label
        }
        .background(HerdrTheme.elevated.opacity(0.46), in: RoundedRectangle(cornerRadius: 11))
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: group.isLive)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        .herdrHaptic(trigger: hapticPulse)
        .frame(minHeight: 44)
        .accessibilityIdentifier("pi-working-\(group.id)")
    }

    private var label: some View {
        HStack(spacing: 9) {
            ZStack {
                if group.isLive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(HerdrTheme.working)
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                } else {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(HerdrProse.dimmed(iconColor))
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                }
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)

            Text(group.isLive ? "Clanking…" : "Clanking")
                .font(.caption.weight(.semibold))
                .foregroundStyle(HerdrProse.dimmed(titleColor))
                .contentTransition(.opacity)

            Text(stepSummary)
                .font(.caption)
                .foregroundStyle(HerdrProse.dimmed(summaryColor))
                .lineLimit(1)
                .layoutPriority(1)
                .contentTransition(.opacity)

            if let latestToolTitle = group.latestToolTitle {
                Text("· \(latestToolTitle)")
                    .font(.caption)
                    .foregroundStyle(HerdrProse.dimmed(summaryColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }

            if let failureSummary {
                Text("· \(failureSummary)")
                    .font(.caption)
                    .foregroundStyle(failureCountColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows Pi's thinking and tool activity")
    }

    var chevronColor: Color { HerdrTheme.mist }
    var iconColor: Color { HerdrTheme.muted }
    var titleColor: Color { HerdrTheme.mist }
    var summaryColor: Color { HerdrTheme.muted }
    var failureCountColor: Color { HerdrTheme.alert }

    var stepSummary: String {
        "\(group.stepCount) step\(group.stepCount == 1 ? "" : "s")"
    }

    var failureSummary: String? {
        group.failureCount > 0 ? "\(group.failureCount) failed" : nil
    }

    /// The complete, untruncated summary remains available to assistive technology.
    var summary: String {
        var parts = [stepSummary]
        if let latestToolTitle = group.latestToolTitle { parts.append(latestToolTitle) }
        if let failureSummary { parts.append(failureSummary) }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        (group.isLive ? "Clanking, " : "Clanked, ") + summary
    }
}
