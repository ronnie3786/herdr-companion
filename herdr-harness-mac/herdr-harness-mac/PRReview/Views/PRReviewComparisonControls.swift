import SwiftUI

struct PRReviewComparisonControls: View {
    @Bindable var store: PRReviewStore
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                HStack {
                    Text("Compare").herdrFont(.caption, weight: .semibold)
                    Spacer(minLength: 0)
                    if store.isLoadingComparison { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 6) {
                    Text("Before").herdrFont(.caption).frame(width: 38, alignment: .leading)
                    endpointMenu(before: true)
                }
                HStack(spacing: 6) {
                    Text("After").herdrFont(.caption).frame(width: 38, alignment: .leading)
                    endpointMenu(before: false)
                }
                HStack(spacing: 8) {
                    displayControls.labelsHidden()
                }
            } else {
                HStack(spacing: 10) {
                    Text("Compare").herdrFont(.caption, weight: .semibold)
                    endpointMenu(before: true)
                    Image(systemName: "arrow.right").foregroundStyle(HerdrTheme.mist).accessibilityHidden(true)
                    endpointMenu(before: false)
                    Spacer(minLength: 0)
                    if store.isLoadingComparison { ProgressView().controlSize(.small) }
                    displayControls
                }
            }
            if let message = store.comparisonLoadError {
                HStack {
                    Text(message).herdrFont(.caption).foregroundStyle(HerdrTheme.alert)
                    Button("Retry") { Task { await store.loadComparison() } }
                }
            }
        }
        .padding(10)
        .background(HerdrTheme.ink)
        .accessibilityIdentifier("pr-review-comparison-controls")
    }

    @ViewBuilder private var displayControls: some View {
        Picker("Diff layout", selection: $store.diffStyle) {
            Text("Unified").tag("unified")
            Text("Split").tag("split")
        }
        .accessibilityIdentifier("pr-review-diff-layout")
        .help("Unified or split diff layout")
        Picker("Long lines", selection: $store.diffOverflow) {
            Text("Scroll").tag("scroll")
            Text("Wrap").tag("wrap")
        }
        .accessibilityIdentifier("pr-review-diff-overflow")
        .help("Scroll or wrap long lines")
    }

    private func endpointMenu(before: Bool) -> some View {
        let selected = before ? store.comparisonBeforeSHA : store.comparisonAfterSHA
        return Menu {
            if let listing = store.comparisonCommits {
                if before {
                    Button("\(listing.baselineLabel) · baseline") {
                        store.selectComparison(before: listing.baselineSHA, after: store.comparisonAfterSHA)
                    }
                }
                ForEach(availableCommits(before: before)) { commit in
                    Button(commit.label) {
                        store.selectComparison(before: before ? commit.sha : store.comparisonBeforeSHA,
                                               after: before ? store.comparisonAfterSHA : commit.sha)
                    }
                }
            }
        } label: {
            Text(endpointLabel(selected)).lineLimit(1).truncationMode(.middle)
        }
        .disabled(store.comparisonCommits == nil)
        .accessibilityLabel(before ? "Before revision" : "After revision")
        .accessibilityValue(endpointLabel(selected))
        .accessibilityIdentifier(before ? "pr-review-before-revision" : "pr-review-after-revision")
        .help(before ? "Select an older tree" : "Select a newer tree")
    }

    private func endpointLabel(_ sha: String) -> String {
        if let listing = store.comparisonCommits {
            if sha == listing.baselineSHA { return "\(listing.baselineLabel) · baseline" }
            if let commit = listing.commits.first(where: { $0.sha == sha }) { return commit.label }
        }
        return sha.isEmpty ? "Loading commits…" : String(sha.prefix(7))
    }

    private func availableCommits(before: Bool) -> [GitCommit] {
        guard let listing = store.comparisonCommits else { return [] }
        return listing.commits.filter { commit in
            listing.allows(before: before ? commit.sha : store.comparisonBeforeSHA,
                           after: before ? store.comparisonAfterSHA : commit.sha)
        }
    }
}
