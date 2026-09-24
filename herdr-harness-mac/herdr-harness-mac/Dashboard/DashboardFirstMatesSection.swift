import SwiftUI

struct DashboardFirstMatesSection: View {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    let entries: [DashboardFeatureEntry]
    let width: CGFloat
    @State private var position = ScrollPosition(idType: String.self)
    @State private var visibleIDs: [String] = []

    static let newFeatureID = "new-feature"

    /// Three wide cards with a fourth peeking in (two on narrow windows, four on
    /// very wide ones), so the strip always reads as scrollable when it is.
    static func cardWidth(for width: CGFloat) -> CGFloat {
        let slots: CGFloat = width < 1100 ? 2 : width < 2200 ? 3 : 4
        let available = width - HerdrTheme.pagePadding * 2 - slots * 16 - 64
        return min(max(available / slots, 300), 560)
    }

    private var visible: [DashboardFeatureEntry] {
        DashboardFeatureEntry.ordered(entries, focusMode: shell.dashboard.focusMode, query: shell.dashboard.search)
    }

    var body: some View {
        let visible = visible
        let cardWidth = Self.cardWidth(for: width)
        let overflows = CGFloat(visible.count) * (cardWidth + 16) + 150 > width - HerdrTheme.pagePadding * 2
        VStack(alignment: .leading, spacing: 12) {
            header(visible: visible, overflows: overflows)
                .padding(.horizontal, HerdrTheme.pagePadding)
            hostProblems
            if isLoading {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in DashboardFeatureCardSkeleton(width: cardWidth) }
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading First Mates")
            } else if entries.isEmpty, !shell.dashboard.focusMode, shell.dashboard.search.isEmpty {
                HStack(spacing: 12) {
                    Text(model.isDemoMode || !model.machines.isEmpty ? "No First Mates yet." : "Connect a companion in Settings → Machines to start a First Mate.")
                        .herdrFont(.callout).foregroundStyle(HerdrTheme.muted)
                    DashboardCreateFeatureMenu(model: model, shell: shell) {
                        Label("New feature", systemImage: "plus")
                            .herdrFont(.callout).foregroundStyle(HerdrTheme.accent)
                            .contentShape(.rect)
                    }
                }
                .padding(.horizontal, HerdrTheme.pagePadding)
            } else if visible.isEmpty, !entries.isEmpty || shell.dashboard.focusMode || !shell.dashboard.search.isEmpty {
                Text(shell.dashboard.search.isEmpty ? "No First Mates are waiting for you." : "No First Mates match your search.")
                    .herdrFont(.callout).foregroundStyle(HerdrTheme.muted)
                    .padding(.horizontal, HerdrTheme.pagePadding)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(visible) { entry in
                            DashboardFeatureCard(entry: entry, width: cardWidth) {
                                shell.showFirstMate(machineID: entry.machineID, featureID: entry.feature.id,
                                                    inspector: .overview, model: model)
                            }
                            .id(entry.id)
                        }
                        DashboardNewFeatureTile(model: model, shell: shell)
                            .id(Self.newFeatureID)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollTargetLayout()
                }
                .scrollPosition($position)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, HerdrTheme.pagePadding, for: .scrollContent)
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { visibleIDs = $0 }
            }
        }
    }

    private var isLoading: Bool {
        !model.isDemoMode && !shell.firstMateFleet.hosts.isEmpty && !shell.firstMateFleet.hasLoadedAnyHost
    }

    private func header(visible: [DashboardFeatureEntry], overflows: Bool) -> some View {
        let attention = entries.filter(\.needsAttention).count
        return HStack(spacing: 12) {
            DashboardSectionHeading(title: "First Mates", identifier: "dashboard-first-mates") {
                shell.show(.firstMate, model: model)
            }
            Text(entries.isEmpty ? "None active" : "\(entries.count) active · \(attention) \(attention == 1 ? "needs" : "need") you")
                .herdrFont(.subheadline, monospacedDigit: true)
                .foregroundStyle(HerdrTheme.muted)
            Spacer(minLength: 8)
            if overflows {
                DashboardIconButton(title: "Previous First Mate", systemImage: "chevron.left") { move(-1, ids: visible.map(\.id)) }
                DashboardIconButton(title: "Next First Mate", systemImage: "chevron.right") { move(1, ids: visible.map(\.id)) }
            }
            Button {
                shell.show(.agentBoard, model: model)
            } label: {
                Label("Agent view", systemImage: "rectangle.split.3x1")
                    .herdrFont(.callout, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(HerdrTheme.controlAccent, in: .rect(cornerRadius: HerdrTheme.compactRadius))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open every First Mate side by side (Shift-Command-A)")
            .accessibilityIdentifier("dashboard-open-agent-view")
        }
    }

    @ViewBuilder
    private var hostProblems: some View {
        if !model.isDemoMode {
            ForEach(shell.firstMateFleet.hosts.filter { $0.unsupported || $0.error != nil }) { host in
                HStack(spacing: 8) {
                    Image(systemName: host.unsupported ? "arrow.down.circle" : "wifi.slash")
                        .accessibilityHidden(true)
                    Text(host.unsupported ? "\(host.machineName) needs a companion update" : "\(host.machineName) is offline · showing last known work")
                    if !host.unsupported {
                        Button("Retry") { Task { await shell.firstMateFleet.refresh() } }
                            .buttonStyle(.plain).foregroundStyle(HerdrTheme.accent)
                    }
                }
                .herdrFont(.subheadline)
                .foregroundStyle(HerdrTheme.attention)
                .help(host.error ?? "")
                .padding(.horizontal, HerdrTheme.pagePadding)
            }
        }
    }

    private func move(_ offset: Int, ids: [String]) {
        let all = ids + [Self.newFeatureID]
        let anchor = offset < 0 ? visibleIDs.compactMap { all.firstIndex(of: $0) }.min() : visibleIDs.compactMap { all.firstIndex(of: $0) }.max()
        guard let anchor else { return }
        let target = min(max(anchor + offset, 0), all.count - 1)
        position.scrollTo(id: all[target], anchor: offset < 0 ? .leading : .trailing)
    }
}

struct DashboardFeatureCard: View {
    let entry: DashboardFeatureEntry
    let width: CGFloat
    let open: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var meta: String {
        [entry.machineName, entry.feature.workItemID].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    DashboardStatusPill(status: entry.feature.status, awaitingTurn: entry.awaitingTurn)
                    Spacer(minLength: 6)
                    Text(meta).herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                }
                Text(entry.title)
                    .herdrFont(.title3, weight: .medium)
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DashboardNowBlock(stageTitle: entry.summary?.currentStageTitle, stageIndex: entry.summary?.currentStageIndex)
                Text(entry.preview ?? "No replies yet")
                    .herdrFont(.callout)
                    .foregroundStyle(entry.preview == nil ? HerdrTheme.muted : HerdrTheme.mist)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, HerdrTheme.cardPadding)
            .padding(.vertical, 14)
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                    .stroke(isFocused ? HerdrTheme.accent : isHovered ? HerdrTheme.selection : HerdrTheme.separator,
                            lineWidth: isFocused ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: HerdrTheme.cardRadius))
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help("Open \(entry.title) on \(entry.machineName)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens in First Mate")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("dashboard-feature-\(entry.id)")
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if entry.needsAttention {
                // A parked turn's prompt is its latest reply, already shown above.
                Text("→ \(footerPrompt)")
                    .herdrFont(.callout, weight: .semibold)
                    .foregroundStyle(HerdrTheme.attention)
                    .lineLimit(1)
                    .help(entry.attentionPrompt ?? "")
            } else if let running = entry.summary?.runningAssignmentCount, running > 0 {
                Label("\(running) agent\(running == 1 ? "" : "s") running", systemImage: "circle.lefthalf.filled")
                    .herdrFont(.subheadline)
                    .foregroundStyle(HerdrTheme.mist)
            }
            Spacer(minLength: 0)
            if entry.hostError != nil, let seen = entry.lastUpdated {
                HStack(spacing: 3) {
                    Text("Last seen")
                    DashboardAgeText(date: seen)
                }
                .herdrFont(.subheadline)
                .foregroundStyle(HerdrTheme.attention)
                .fixedSize()
            } else if let date = entry.activityDate {
                DashboardAgeText(date: date)
                    .herdrFont(.subheadline, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.muted)
                    .fixedSize()
            }
        }
    }

    private var footerPrompt: String {
        let decisionPending = FirstMateAttention.needsHumanDecision(status: entry.feature.status)
        if !decisionPending || entry.attentionPrompt == nil || entry.attentionPrompt == entry.preview {
            return "Reply in First Mate"
        }
        return entry.attentionPrompt ?? "Reply in First Mate"
    }

    private var accessibilityText: String {
        let status = FeatureStatusPresentation(status: entry.feature.status, awaitingTurn: entry.awaitingTurn).label
        let now = entry.summary?.currentStageTitle.map { "Now: \($0)." } ?? ""
        let detail = entry.needsAttention ? (entry.attentionPrompt ?? "Waiting for your direction") : (entry.preview ?? "")
        return "\(entry.title). \(status). \(now) \(detail)"
    }
}

private struct DashboardFeatureCardSkeleton: View {
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DashboardSkeletonBar(width: 90, height: 14)
            DashboardSkeletonBar(width: width * 0.7, height: 14)
            RoundedRectangle(cornerRadius: HerdrTheme.nowRadius).fill(HerdrTheme.surface.opacity(0.6)).frame(height: 52)
            DashboardSkeletonBar(width: width * 0.8)
            DashboardSkeletonBar(width: width * 0.55)
        }
        .padding(16)
        .frame(width: width, height: 210, alignment: .topLeading)
        .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: HerdrTheme.cardRadius).stroke(HerdrTheme.separator) }
    }
}

private struct DashboardNewFeatureTile: View {
    let model: HerdrAppModel
    let shell: HerdrShellState
    @State private var isHovered = false

    var body: some View {
        DashboardCreateFeatureMenu(model: model, shell: shell) {
            Label("New feature", systemImage: "plus")
                .herdrFont(.callout)
                .foregroundStyle(isHovered ? HerdrTheme.text : HerdrTheme.muted)
                .frame(width: 150)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: HerdrTheme.cardRadius)
                .strokeBorder(isHovered ? HerdrTheme.selection : HerdrTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("dashboard-new-feature")
    }
}
