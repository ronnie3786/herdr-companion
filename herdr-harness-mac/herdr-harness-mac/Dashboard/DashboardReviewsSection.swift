import SwiftUI

struct DashboardReviewsSection: View {
    let model: HerdrAppModel
    @Bindable var shell: HerdrShellState
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
        let owningMachineID = shell.prReview.currentMachineID
        let generation = model.connectionGeneration
        let configuration = model.prReviewConfiguration(machineID: owningMachineID)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Button { shell.show(.prReview, model: model) } label: {
                    HStack(spacing: 5) {
                        Text("PR Reviews").herdrFont(.headline)
                        Image(systemName: "chevron.right").herdrFont(.caption2)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("dashboard-pr-reviews")
                Text("\(reviews.count) active").herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                Spacer(minLength: 4)
                if let lastUpdated {
                    HStack(spacing: 3) {
                        Text(hasStaleStates || failure != nil ? "Last updated" : "Updated")
                        DashboardAgeText(date: lastUpdated)
                    }.herdrFont(.caption2).foregroundStyle(HerdrTheme.muted).lineLimit(1)
                }
                Button("Refresh review states", systemImage: "arrow.clockwise") {
                    Task {
                        shell.dashboard.isRefreshingReviews = true
                        defer { shell.dashboard.isRefreshingReviews = false }
                        shell.dashboard.reviewRefreshError = await shell.prReview.refreshDashboard(requestGitHubRefresh: true)
                    }
                }.labelStyle(.iconOnly).buttonStyle(.plain).herdrHitTarget()
                    .disabled(shell.dashboard.isRefreshingReviews || shell.prReview.isRefreshing || shell.prReview.unconfigured)
            }
            if shell.prReview.unconfigured {
                notice("Choose the PR review host in Settings → Machines", symbol: "desktopcomputer")
            } else if shell.prReview.unsupported {
                notice("The PR review host needs a companion update.", symbol: "arrow.down.circle")
            } else if !shell.prReview.hasLoaded {
                if let failure { notice(failure, symbol: "exclamationmark.triangle") }
                else { notice("Loading reviews…", symbol: "arrow.down.circle") }
            } else {
                if let failure { notice(failure, symbol: "exclamationmark.triangle") }
                else if hasStaleStates { notice("GitHub could not refresh. Last known review states are shown.", symbol: "exclamationmark.triangle") }
                if reviews.isEmpty {
                    notice(shell.dashboard.focusMode ? "No reviews are waiting for you." : shell.dashboard.search.isEmpty ? "No active reviews" : "No reviews match your search.", symbol: "checkmark.circle")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(reviews) { review in
                            DashboardReviewRow(review: review) {
                                guard let owningMachineID,
                                      shell.prReview.currentMachineID == owningMachineID,
                                      model.connectionGeneration == generation,
                                      model.prReviewConfiguration(machineID: owningMachineID) == configuration else { return }
                                shell.showPRReview(machineID: owningMachineID, reviewID: review.id, model: model)
                            }
                        }
                    }
                }
                if shell.dashboard.focusMode, shell.prReview.reviews.contains(where: { $0.viewerReview == nil || $0.viewerReview?.state == "unknown" }) {
                    Text("Some review states are unavailable. Turn off Focus mode to see them.")
                        .herdrFont(.caption).foregroundStyle(HerdrTheme.muted)
                }
            }
        }
    }
    private func notice(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).herdrFont(.subheadline).foregroundStyle(HerdrTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
    }
}
