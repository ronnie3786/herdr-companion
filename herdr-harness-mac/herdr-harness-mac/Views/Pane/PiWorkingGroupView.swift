import SwiftUI

/// Collapses Pi's activity, including thinking, tools, and optionally interim
/// assistant commentary, behind one "Clanking" row.
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
            VStack(alignment: .leading, spacing: 4) {
                ForEach(group.items) { item in
                    PiConversationItemView(item: item)
                        .transition(PiChatMotion.itemTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.top, 4)
            .padding(.leading, 18)
        } label: {
            label
        }
        .animation(PiChatMotion.disclosureAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(PiChatMotion.stateAnimation(reduceMotion: reduceMotion), value: group.isLive)
        .onChange(of: isExpanded) { _, expanded in
            hapticPulse.fire(expanded ? .controlsExpanded : .controlsCollapsed)
        }
        .herdrHaptic(trigger: hapticPulse)
        .accessibilityIdentifier("pi-working-\(group.id)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var label: some View {
        HStack(spacing: 6) {
            ZStack {
                if group.isLive {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(HerdrTheme.working)
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                } else {
                    Image(systemName: "terminal")
                        .herdrFont(size: HerdrTheme.TextSize.reading)
                        .foregroundStyle(iconColor)
                        .transition(PiChatMotion.stateTransition(reduceMotion: reduceMotion))
                }
            }
            .herdrIconSlot(width: 16, height: 16)
            .accessibilityHidden(true)

            Text(group.isLive ? "Clanking…" : "Clanking")
                .herdrFont(size: HerdrTheme.TextSize.reading)
                .foregroundStyle(titleColor)
                .contentTransition(.opacity)

            Text(stepSummary)
                .herdrFont(size: HerdrTheme.TextSize.body)
                .foregroundStyle(summaryColor)
                .lineLimit(1)
                .layoutPriority(1)
                .contentTransition(.opacity)

            if let latestToolTitle = group.latestToolTitle {
                Text("· \(latestToolTitle)")
                    .herdrFont(size: HerdrTheme.TextSize.body)
                    .foregroundStyle(summaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }

            if let failureSummary {
                Text("· \(failureSummary)")
                    .herdrFont(size: HerdrTheme.TextSize.body)
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
        .accessibilityHint("Shows Pi's thinking, commentary, and tool activity")
    }

    // MonoCode's unboxed tool row: icons at 50% ink, words at 64%.
    var chevronColor: Color { HerdrTheme.iconTint }
    var borderColor: Color { .clear }
    var iconColor: Color { HerdrTheme.iconTint }
    var titleColor: Color { HerdrTheme.tertiaryText }
    var summaryColor: Color { HerdrTheme.tertiaryText }
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
        (group.isLive ? "Clanking, working, " : "Clanking, ") + summary
    }
}
