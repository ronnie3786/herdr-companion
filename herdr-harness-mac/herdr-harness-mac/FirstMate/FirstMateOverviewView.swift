import SwiftUI

struct FirstMateOverviewView: View {
    @Bindable var store: FirstMateStore
    let snapshot: FirstMateSnapshot
    @Environment(\.colorScheme) private var scheme
    @AppStorage(MobileAppHubSettings.hubURLKey) private var buildsHubURL = ""
    @State private var builds = MobileAppHubFeed()
    @Environment(\.firstMateSimulator) private var simulator

    private var palette: FirstMatePalette { FirstMatePalette(scheme: scheme) }

    var body: some View {
        let buildsQuery = MobileAppHubSettings.firstMateQuery(hubURLText: buildsHubURL, featureID: snapshot.feature.id)
        VStack(alignment: .leading, spacing: 12) {
            FirstMateActivityView(store: store, snapshot: snapshot)
            FirstMateArchiveSection(store: store, feature: snapshot.feature)
            if !snapshot.pullRequestLinks.isEmpty {
                FirstMatePullRequestsSection(store: store, snapshot: snapshot, surface: .overview)
                    .padding(12)
                    .herdrCard()
            }
            FirstMateBuildsSection(
                featureID: snapshot.feature.id,
                assignments: snapshot.assignments.map { ($0.id, $0.title) },
                feed: builds,
                query: buildsQuery,
                simulator: simulator
            )
            Text("The feature at a glance")
                .herdrFont(size: 15, weight: .semibold)
                .foregroundStyle(palette.text)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            FirstMateOverviewGoalView(source: snapshot.feature.goal)
            if let projectName = snapshot.feature.projectName {
                VStack(alignment: .leading, spacing: 6) {
                    HerdrMicroLabel(text: "Project")
                    Label(projectName, systemImage: "folder")
                        .herdrFont(size: HerdrTheme.TextSize.body, weight: .medium)
                    Text(snapshot.feature.cwd)
                        .herdrFont(size: HerdrTheme.TextSize.small)
                        .foregroundStyle(palette.secondaryText)
                        .textSelection(.enabled)
                        .help("This session keeps the folder chosen when it started.")
                }
                .padding(12)
                .herdrCard()
                .accessibilityIdentifier("first-mate-session-project")
            }
            FirstMateUsageSummaryView(usage: snapshot.feature.usage, title: "Full task usage")
                .padding(12)
                .herdrCard()
            if let visit = snapshot.currentVisit {
                VStack(alignment: .leading, spacing: 0) {
                    HerdrMicroLabel(text: "Current workflow step")
                    HStack(spacing: 8) {
                        Text(visit.title)
                            .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                            .foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        FirstMateStatusLabel(status: snapshot.displayStatus(for: visit))
                    }
                    .padding(.top, 6)
                    FirstMateResourceButtons(store: store, snapshot: snapshot, visit: visit)
                        .padding(.top, 4)
                }
                .padding(12)
                .herdrCard()
            }
            VStack(alignment: .leading, spacing: 0) {
                HerdrMicroLabel(text: "Latest in the journal")
                    .padding(.bottom, 4)
                ForEach(Array(snapshot.events.sorted { $0.sequence > $1.sequence }.prefix(4))) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "clock")
                            .herdrFont(size: 12)
                            .foregroundStyle(palette.iconTint)
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                        FirstMateMarkdownContentView(source: event.summary)
                            .environment(\.firstMateMarkdownDensity, .compact)
                    }
                    .padding(.vertical, 4)
                }
                Button("Open workflow", systemImage: "arrow.right") { store.inspector = .workflow }
                    .labelStyle(DashboardInlineLabelStyle(spacing: 5))
                    .buttonStyle(.herdrPlain)
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .medium)
                    .foregroundStyle(palette.accent)
                    .frame(minHeight: HerdrTheme.minHitTarget)
                    .contentShape(.rect)
            }
            .padding(.top, 2)
        }
        .mobileAppHubRefresh(builds, query: buildsQuery, enabled: !store.isDemo)
        .firstMateSimulatorRefresh(simulator, demoVisitIDs: snapshot.visits.map(\.id))
    }
}
