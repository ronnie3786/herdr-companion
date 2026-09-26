import SwiftUI

struct DashboardView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MobileAppHubSettings.hubURLKey) private var buildsHubURL = ""
    @AppStorage(MobileAppHubSettings.dashboardBundleIDsKey) private var buildsBundleIDs = ""
    @Environment(\.herdrHostsTitleBar) private var hostsTitleBar

    var body: some View {
        let entries = shell.dashboard.entries(shell: shell, isDemo: model.isDemoMode)
        let buildsQuery = MobileAppHubSettings.dashboardQuery(hubURLText: buildsHubURL, bundleIDsText: buildsBundleIDs)
        VStack(spacing: 0) {
            if !hostsTitleBar {
                DashboardHeaderBar(dashboard: shell.dashboard)
                    .herdrBar()
            }
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 26) {
                        DashboardFirstMatesSection(model: model, shell: shell, entries: entries, width: geometry.size.width)
                        DashboardBuildsSection(dashboard: shell.dashboard, query: buildsQuery)
                        DashboardLowerRegion(model: model, shell: shell, width: geometry.size.width)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
            }
        }
        .herdrTitleBar {
            if hostsTitleBar { DashboardHeaderBar.Leading(dashboard: shell.dashboard) }
        } trailing: {
            if hostsTitleBar { DashboardHeaderBar.Trailing(dashboard: shell.dashboard) }
        }
        .background(HerdrTheme.windowBackground)
        .foregroundStyle(HerdrTheme.primaryText)
        .tint(HerdrTheme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard")
        .task(id: reviewRefreshIdentity) { await observeReviews() }
        .mobileAppHubRefresh(shell.dashboard.builds, query: buildsQuery, enabled: !model.isDemoMode)
    }

    private var reviewRefreshIdentity: String {
        "\(scenePhase == .active)-\(model.connectionGeneration)-\(shell.prReview.currentMachineID ?? "")-\(model.isDemoMode)"
    }

    /// Reviews come from the companion's cache, which its own worker refreshes
    /// from GitHub every minute. The Dashboard asks GitHub directly when it opens
    /// (at most once a minute), then reads the cache every 30 seconds.
    private func observeReviews() async {
        guard scenePhase == .active, !model.isDemoMode else { return }
        var requestGitHub = shell.dashboard.shouldRequestGitHubRefresh()
        while !Task.isCancelled {
            let failure = await shell.prReview.refreshDashboard(requestGitHubRefresh: requestGitHub)
            guard !Task.isCancelled else { return }
            if requestGitHub, shell.dashboard.reviewRefreshError != failure { shell.dashboard.reviewRefreshError = failure }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            // A failed GitHub refresh is retried (at most once a minute) until
            // it succeeds, so a passing network blip does not linger.
            requestGitHub = shell.dashboard.reviewRefreshError != nil && shell.dashboard.shouldRequestGitHubRefresh()
        }
    }
}

/// Search and Focus mode: the only controls the home screen needs. In the
/// main window they sit in the title bar; standalone hosts draw them as a bar.
private struct DashboardHeaderBar: View {
    @Bindable var dashboard: DashboardState

    var body: some View {
        HStack(spacing: 0) {
            Leading(dashboard: dashboard)
            Spacer(minLength: 12)
            Trailing(dashboard: dashboard)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
    }

    /// "Dashboard" and the search field (`.tbar .field`).
    struct Leading: View {
        @Bindable var dashboard: DashboardState
        @FocusState private var searchFocused: Bool

        var body: some View {
            HStack(spacing: 14) {
                Text("Dashboard")
                    .herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .foregroundStyle(HerdrTheme.primaryText)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
                searchField
            }
            .background {
                // ⌘F reaches search without a visible button.
                Button("Search Dashboard") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0).accessibilityHidden(true)
            }
        }

        private var searchField: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.iconTint)
                    .accessibilityHidden(true)
                TextField("Search First Mates, reviews, and chats", text: $dashboard.search, prompt: Text(""))
                .textFieldStyle(.plain)
                .herdrPlaceholder("Search First Mates, reviews, and chats", isVisible: dashboard.search.isEmpty)
                .herdrFont(size: HerdrTheme.TextSize.small)
                .focused($searchFocused)
                .onExitCommand { dashboard.search = ""; searchFocused = false }
                .accessibilityIdentifier("dashboard-search")
                if !dashboard.search.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { dashboard.search = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(HerdrIconButtonStyle(visualSize: HerdrTheme.ControlHeight.mini))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, dashboard.search.isEmpty ? 10 : 0)
            .frame(height: HerdrTheme.ControlHeight.large)
            .frame(minWidth: 200, idealWidth: 300, maxWidth: 300)
            .background(HerdrTheme.fieldFill, in: .rect(cornerRadius: HerdrTheme.Radius.control))
            .overlay {
                // An ink focus ring would be 1.7:1 on base; the accent reads.
                RoundedRectangle(cornerRadius: HerdrTheme.Radius.control)
                    .strokeBorder(searchFocused ? HerdrTheme.accent : HerdrTheme.outline)
            }
        }
    }

    /// The native Focus mode switch (`.tgl`).
    struct Trailing: View {
        @Bindable var dashboard: DashboardState

        var body: some View {
            Toggle(isOn: $dashboard.focusMode) {
                Text("Focus mode")
                    .herdrFont(size: HerdrTheme.TextSize.small)
                    .foregroundStyle(HerdrTheme.secondaryText)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(HerdrTheme.controlAccent)
            .fixedSize()
            .frame(minHeight: HerdrTheme.minHitTarget)
            .help("Show only the First Mates, reviews, and chats waiting for you")
            .accessibilityIdentifier("dashboard-focus-mode")
        }
    }
}

/// PR Reviews and Recent chats. Two columns only when there is review content
/// to fill one; otherwise reviews collapse to a single line.
private struct DashboardLowerRegion: View {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    let width: CGFloat

    private var reviewsHaveContent: Bool {
        let review = shell.prReview
        guard !review.unconfigured, !review.unsupported else { return false }
        return !review.hasLoaded || !DashboardReviewPresentation.filtered(
            review.reviews, focusMode: shell.dashboard.focusMode, query: shell.dashboard.search).isEmpty
    }

    var body: some View {
        let hasReviews = reviewsHaveContent
        Group {
            if width >= 1000, hasReviews {
                HStack(alignment: .top, spacing: 28) {
                    DashboardReviewsSection(model: model, shell: shell, compact: false)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    DashboardChatsSection(model: model, shell: shell)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 26) {
                    DashboardReviewsSection(model: model, shell: shell, compact: !hasReviews)
                    DashboardChatsSection(model: model, shell: shell)
                }
            }
        }
        .padding(.horizontal, DashboardMetrics.pagePadding)
    }
}

/// A section title that links to the full screen it summarizes.
struct DashboardSectionHeading: View {
    let title: String
    let identifier: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).herdrFont(size: HerdrTheme.TextSize.body, weight: .semibold)
                    .foregroundStyle(HerdrTheme.primaryText)
                Image(systemName: "chevron.right")
                    .herdrFont(size: HerdrTheme.TextSize.caption, weight: .semibold)
                    .foregroundStyle(isHovered ? HerdrTheme.primaryText : HerdrTheme.iconTint)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: HerdrTheme.minHitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open \(title)")
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(.isHeader)
    }
}
