import SwiftUI

/// The inspector's Overview, sized for touch: where the feature stands now,
/// its pull requests and builds, the goal (cut to a few lines until asked),
/// usage, the current focus with its agents, documents and simulator builds,
/// the step's agents, and the latest journal milestones.
struct FirstMateOverviewView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.firstMateInspectorContext) private var context
    @State private var showsFullGoal = false

    /// The same journal milestones as Mac Overview, including First Mate's
    /// private notes from background work; bookkeeping stays in the activity log.
    private var latestMilestones: [FirstMateEvent] {
        Array(snapshot.events.filter(\.isMilestone).sorted { $0.sequence > $1.sequence }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FirstMateActivityView(store: store, snapshot: snapshot)
            if let conversation = context?.conversation, !snapshot.feature.isLead {
                FirstMateNowCard(conversation: conversation, machineName: context?.machineName ?? conversation.machineName)
            }
            if !snapshot.pullRequestLinks.isEmpty {
                FirstMatePullRequestsCard(links: snapshot.pullRequestLinks)
            }
            FirstMateBuildsSection(snapshot: snapshot)

            goal

            VStack(alignment: .leading, spacing: 12) {
                FirstMateUsageDisclosure(usage: snapshot.feature.usage)

                if let visit = snapshot.currentVisit {
                    VStack(alignment: .leading, spacing: 0) {
                        HerdrMicroLabel(text: "Current workflow step")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(visit.title).herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            FirstMateStatusLabel(status: snapshot.displayStatus(for: visit))
                        }
                        .padding(.top, 8)
                        FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                        if visit.status == "awaiting_direction" {
                            Text("The next step waits for your direction in the conversation.")
                                .herdrFont(.footnote).foregroundStyle(HerdrTheme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .herdrCard()
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HerdrMicroLabel(text: "Latest in the journal").padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(latestMilestones) { event in
                        FirstMateJournalRow(event: event)
                    }
                    if latestMilestones.isEmpty {
                        Text("Decisions and progress will appear here as the feature moves forward.")
                            .herdrFont(.subheadline).foregroundStyle(HerdrTheme.tertiaryText)
                    }
                }
                Button("Open workflow", systemImage: "arrow.right") { store.inspector = .workflow }
                    .buttonStyle(.herdrPlain)
                    .herdrFont(.footnote, weight: .medium).foregroundStyle(HerdrTheme.accent)
                    .frame(minHeight: 44).contentShape(.rect)
            }
        }
        .firstMateBuildsRefresh(snapshot: snapshot)
    }

    /// The goal as rendered markdown. A long brief is cut to its first lines
    /// until "Show full brief", so the useful cards below stay in reach.
    private var goal: some View {
        let source = snapshot.feature.goal
        let long = source.count > 320 || source.components(separatedBy: "\n").count > 6
        return VStack(alignment: .leading, spacing: 6) {
            HerdrMicroLabel(text: "Goal")
            FirstMateDocumentContentView(source: source)
                .frame(maxHeight: long && !showsFullGoal ? 132 : nil, alignment: .top)
                .clipped()
                .mask {
                    if long && !showsFullGoal {
                        LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    } else { Color.black }
                }
                .accessibilityIdentifier("first-mate-overview")
            if long {
                Button(showsFullGoal ? "Show less" : "Show full brief") { showsFullGoal.toggle() }
                    .buttonStyle(.herdrPlain)
                    .herdrFont(.footnote, weight: .medium).foregroundStyle(HerdrTheme.accent)
                    .frame(minHeight: 44).contentShape(.rect)
                    .accessibilityIdentifier("first-mate-overview-goal-toggle")
            }
        }
    }
}

/// "Full task usage · $0.05 · 161,340 tokens" on one line, as in the
/// prototype; the full breakdown opens under it.
private struct FirstMateUsageDisclosure: View {
    let usage: FirstMateUsage?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var summary: String {
        guard let usage else { return "Unavailable" }
        return "\(FirstMateUsageFormatting.compactCost(usage)) · \(FirstMateUsageFormatting.tokens(usage.totalTokens)) tokens"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HerdrTheme.iconTint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Full task usage").herdrFont(.body, weight: .semibold).foregroundStyle(HerdrTheme.primaryText)
                    Spacer(minLength: 8)
                    Text(summary).herdrFont(.caption).monospacedDigit().foregroundStyle(HerdrTheme.secondaryText).lineLimit(1)
                }
                .frame(minHeight: 44).contentShape(.rect)
            }
            .buttonStyle(.herdrPlain)
            .accessibilityLabel("Full task usage, \(summary)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides the breakdown" : "Shows the breakdown")
            .accessibilityIdentifier("first-mate-usage-toggle")
            if expanded {
                FirstMateUsageSummaryView(usage: usage, title: "Full task usage")
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .herdrCard()
                    .transition(.opacity)
            }
        }
    }
}
