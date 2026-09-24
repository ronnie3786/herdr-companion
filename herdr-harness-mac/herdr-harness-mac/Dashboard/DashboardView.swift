import SwiftUI

struct DashboardView: View {
    @Bindable var model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let entries = shell.dashboard.entries(shell: shell, isDemo: model.isDemoMode)
        VStack(spacing: 0) {
            DashboardHeaderBar(dashboard: shell.dashboard)
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 28) {
                        DashboardFirstMatesSection(model: model, shell: shell, entries: entries, width: geometry.size.width)
                        DashboardLowerRegion(model: model, shell: shell, width: geometry.size.width)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.automatic)
            }
        }
        .background(HerdrTheme.graphite)
        .foregroundStyle(HerdrTheme.text)
        .tint(HerdrTheme.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard")
        .task(id: reviewRefreshIdentity) { await observeReviews() }
    }

    private var reviewRefreshIdentity: String {
        "\(scenePhase == .active)-\(model.connectionGeneration)-\(shell.prReview.currentMachineID ?? "")-\(model.isDemoMode)"
    }

    /// Reviews come from the companion's cache, which its own worker refreshes
    /// from GitHub every minute. The Dashboard asks GitHub directly when it opens
    /// (at most once a minute), then reads the cache every 30 seconds.
    private func observeReviews() async {
        guard scenePhase == .active, !model.isDemoMode else { return }
        var first = shell.dashboard.shouldRequestGitHubRefresh()
        while !Task.isCancelled {
            let failure = await shell.prReview.refreshDashboard(requestGitHubRefresh: first)
            guard !Task.isCancelled else { return }
            if first, shell.dashboard.reviewRefreshError != failure { shell.dashboard.reviewRefreshError = failure }
            first = false
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }
}

/// Search and Focus mode: the only controls the home screen needs.
private struct DashboardHeaderBar: View {
    @Bindable var dashboard: DashboardState
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(HerdrTheme.muted)
                    .accessibilityHidden(true)
                TextField("Search First Mates, reviews, and chats", text: $dashboard.search)
                    .textFieldStyle(.plain)
                    .herdrFont(.callout)
                    .focused($searchFocused)
                    .onExitCommand { dashboard.search = ""; searchFocused = false }
                    .accessibilityIdentifier("dashboard-search")
                if !dashboard.search.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { dashboard.search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(minWidth: 200, idealWidth: 320, maxWidth: 340)
            .background(HerdrTheme.input, in: .rect(cornerRadius: HerdrTheme.compactRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
                    .stroke(searchFocused ? HerdrTheme.accent : HerdrTheme.separator)
            }
            Spacer(minLength: 12)
            Toggle("Focus mode", isOn: $dashboard.focusMode)
                .toggleStyle(.switch)
                .controlSize(.small)
                .herdrFont(.callout)
                .tint(HerdrTheme.controlAccent)
                .fixedSize()
                .help("Show only the First Mates, reviews, and chats waiting for you")
                .accessibilityIdentifier("dashboard-focus-mode")
        }
        .padding(.horizontal, HerdrTheme.pagePadding)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1) }
        .background {
            // ⌘F reaches search without a visible button.
            Button("Search Dashboard") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).accessibilityHidden(true)
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
        Group {
            if width >= 1100, reviewsHaveContent {
                HStack(alignment: .top, spacing: 40) {
                    DashboardReviewsSection(model: model, shell: shell, compact: false)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    DashboardChatsSection(model: model, shell: shell)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    DashboardReviewsSection(model: model, shell: shell, compact: !reviewsHaveContent)
                    DashboardChatsSection(model: model, shell: shell)
                }
            }
        }
        .padding(.horizontal, HerdrTheme.pagePadding)
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
            HStack(spacing: 5) {
                Text(title).herdrFont(.title3, weight: .semibold)
                    .foregroundStyle(HerdrTheme.text)
                Image(systemName: "chevron.right")
                    .herdrFont(.subheadline, weight: .semibold)
                    .foregroundStyle(isHovered ? HerdrTheme.text : HerdrTheme.accent)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open \(title)")
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(.isHeader)
    }
}
