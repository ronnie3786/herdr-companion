import SwiftUI

struct DashboardReviewsSection: View {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
    /// One line instead of a list: nothing to review, or no host chosen yet.
    let compact: Bool

    private var reviews: [PRReviewSummary] {
        DashboardReviewPresentation.filtered(shell.prReview.reviews, focusMode: shell.dashboard.focusMode, query: shell.dashboard.search)
    }
    private var lastUpdated: Date? {
        let values = shell.prReview.reviews.filter { $0.viewerReview?.isOwnPR != true }
        guard !values.isEmpty, values.allSatisfy({ $0.viewerReview?.updatedAt != nil }) else { return nil }
        return values.compactMap { $0.viewerReview?.updatedAt.flatMap(HerdrTimestamp.date) }.min()
    }
    private var hasStaleStates: Bool { shell.prReview.reviews.contains { $0.viewerReview?.error != nil } }
    private var failure: String? { shell.prReview.error ?? shell.dashboard.reviewRefreshError }

    var body: some View {
        let reviews = reviews
        VStack(alignment: .leading, spacing: 10) {
            header(count: reviews.count)
            if !compact { content(reviews) }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            DashboardSectionHeading(title: "PR Reviews", identifier: "dashboard-pr-reviews") {
                shell.show(.prReview, model: model)
            }
            if shell.prReview.unconfigured, !model.isDemoMode {
                hostMenu
            } else if shell.prReview.unsupported {
                note("The review host needs a companion update.")
            } else if compact {
                note(shell.dashboard.focusMode ? "None waiting on you" : shell.dashboard.search.isEmpty ? "No active reviews" : "No matches")
            } else {
                Text(shell.dashboard.focusMode ? "\(count) waiting on you" : "\(count) active")
                    .herdrFont(.subheadline, monospacedDigit: true)
                    .foregroundStyle(HerdrTheme.muted)
            }
            Spacer(minLength: 4)
            if !shell.prReview.unconfigured {
                if let lastUpdated, isStale(lastUpdated) || hasStaleStates || failure != nil {
                    HStack(spacing: 3) {
                        Text("Updated")
                        DashboardAgeText(date: lastUpdated)
                    }
                    .herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted).lineLimit(1).fixedSize()
                }
                DashboardIconButton(title: "Refresh review states", systemImage: "arrow.clockwise",
                                    help: "Ask GitHub for the latest review states") { refresh() }
                    .disabled(shell.dashboard.isRefreshingReviews)
            }
        }
    }

    /// The review host is a saved choice; picking it here is the same as
    /// choosing it in Settings → Machines.
    private var hostMenu: some View {
        Menu {
            ForEach(model.machines) { machine in
                Button(machine.name) {
                    model.setPRReviewMachineOverride(machine.id)
                }
            }
            if model.machines.isEmpty { Text("Connect a machine in Settings → Machines") }
        } label: {
            Text("Choose a review host")
                .herdrFont(.subheadline)
                .foregroundStyle(HerdrTheme.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The machine that runs PR Reviews. Also in Settings → Machines.")
        .accessibilityIdentifier("dashboard-pr-review-host")
    }

    @ViewBuilder
    private func content(_ reviews: [PRReviewSummary]) -> some View {
        let owningMachineID = shell.prReview.currentMachineID
        if !shell.prReview.hasLoaded {
            if let failure { notice(failure, symbol: "exclamationmark.triangle") }
            else {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            DashboardSkeletonBar(width: 260)
                            DashboardSkeletonBar(width: 160, height: 8)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading reviews")
            }
        } else {
            if let failure { notice(failure, symbol: "exclamationmark.triangle") }
            else if hasStaleStates { notice("GitHub couldn't refresh. Showing the last known review states.", symbol: "exclamationmark.triangle") }
            if reviews.isEmpty {
                notice(shell.dashboard.focusMode ? "No reviews are waiting for you." : shell.dashboard.search.isEmpty ? "No active reviews." : "No reviews match your search.",
                       symbol: "checkmark.circle")
            } else {
                VStack(spacing: 0) {
                    ForEach(reviews) { review in
                        DashboardReviewRow(review: review) {
                            guard let owningMachineID, shell.prReview.currentMachineID == owningMachineID else { return }
                            shell.showPRReview(machineID: owningMachineID, reviewID: review.id, model: model)
                        }
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1) }
            }
        }
    }

    private func isStale(_ date: Date) -> Bool { Date.now.timeIntervalSince(date) > 120 }

    private func refresh() {
        Task {
            shell.dashboard.isRefreshingReviews = true
            defer { shell.dashboard.isRefreshingReviews = false }
            shell.dashboard.reviewRefreshError = await shell.prReview.refreshDashboard(requestGitHubRefresh: true)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted).lineLimit(1)
    }

    private func notice(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .herdrFont(.callout).foregroundStyle(HerdrTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }
}

struct DashboardReviewRow: View {
    let review: PRReviewSummary
    let open: () -> Void
    @State private var isHovered = false
    private var state: DashboardReviewState { review.viewerReview ?? .init(state: "unknown") }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(HerdrTheme.mauve).frame(width: 2)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(review.title)
                            .herdrFont(.body, weight: state.needsAttention ? .semibold : .regular)
                            .foregroundStyle(HerdrTheme.text)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Label(state.label, systemImage: state.symbol)
                            .herdrFont(.subheadline, weight: state.needsAttention ? .semibold : .regular)
                            .foregroundStyle(state.needsAttention ? HerdrTheme.attention : HerdrTheme.muted)
                            .lineLimit(1).fixedSize()
                        if state.error != nil {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(HerdrTheme.muted)
                                .help("Last known review state. GitHub refresh failed.")
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("\(review.owner)/\(review.repo) #\(review.number)").foregroundStyle(HerdrTheme.mauve)
                        Text(" · \(review.author)").foregroundStyle(HerdrTheme.muted)
                        Spacer(minLength: 12)
                        Text(skillLabel).foregroundStyle(HerdrTheme.muted).truncationMode(.middle)
                            .help(skillLabel)
                    }
                    .herdrFont(.subheadline)
                    .lineLimit(1)
                }
            }
            // The accent rule takes the row's height, never the section's.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 9).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? HerdrTheme.elevated : .clear, in: .rect(cornerRadius: 6))
            .overlay(alignment: .bottom) { Rectangle().fill(HerdrTheme.subtleSeparator).frame(height: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboard-review-\(review.id)")
    }

    private var skillLabel: String {
        guard let runs = review.skillRuns else {
            return review.runningRuns > 0 ? "\(review.runningRuns) skills running" : ""
        }
        return runs.isEmpty ? "No skills run" : runs.map(\.label).joined(separator: " · ")
    }
}
