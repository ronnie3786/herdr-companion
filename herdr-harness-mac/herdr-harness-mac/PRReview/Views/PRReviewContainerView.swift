import AppKit
import SwiftUI

struct PRReviewContainerView: View {
    @Bindable var store: PRReviewStore
    var canControl = false
    var openURL: (URL) -> Void = { _ in }
    var askAI: (PRReviewSelection, NSView, CGRect) -> Void = { _, _, _ in }
    var questionDraftChanged: (Bool) -> Void = { _ in }
    var setCreating: (Bool) -> Void = { _ in }
    var openPane: (String, String?) -> Void = { _, _ in }
    var setAddingSkill: (Bool) -> Void = { _ in }

    var body: some View {
        ZStack {
            HerdrBackground()
            VStack(spacing: 0) {
                if let review = store.snapshot?.review ?? store.selectedReview {
                    header(review)
                    Rectangle().fill(HerdrTheme.separator).frame(height: 1)
                    Picker("View", selection: $store.tab) {
                        Text("Files").tag(PRReviewTab.files)
                        Text("Context (\(review.documentCount))").tag(PRReviewTab.context)
                        Text("Agents (\(review.runningRuns) running)").tag(PRReviewTab.agents)
                        Text("Skills").tag(PRReviewTab.skills)
                    }
                    .pickerStyle(.segmented)
                    .tint(HerdrTheme.controlAccent)
                    .padding(10)
                    .accessibilityIdentifier("pr-review-mode-picker")
                    content(review)
                } else if store.unconfigured || store.unsupported {
                    ContentUnavailableView(store.error ?? "PR Review is unavailable", systemImage: "arrow.triangle.pull")
                        .accessibilityIdentifier("pr-review-unavailable")
                } else if !store.hasLoaded || store.isRefreshing {
                    ContentUnavailableView("Loading PR reviews", systemImage: "arrow.triangle.2.circlepath")
                        .accessibilityIdentifier("pr-review-loading")
                } else {
                    ContentUnavailableView("Choose a PR review", systemImage: "arrow.triangle.pull")
                        .accessibilityIdentifier("pr-review-empty")
                }
            }
        }
        .navigationTitle("PR Review")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-review-container")
        .sheet(isPresented: $store.isPresentingStartSheet, onDismiss: { setCreating(false) }) {
            PRReviewStartSheet(store: store) {
                store.pendingURL = nil
                store.isPresentingStartSheet = false
                setCreating(false)
            }
        }
    }

    private func header(_ review: PRReviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(review.title).herdrFont(size: 30, weight: .semibold, relativeTo: .largeTitle).lineLimit(1)
                Spacer()
                Button("Refresh") { Task { await store.refreshReview() } }.disabled(!canControl)
                Button(review.archivedAt == nil ? "Archive" : "Unarchive") {
                    Task { await store.archive(review.archivedAt == nil) }
                }.disabled(!canControl)
            }
            HStack(spacing: 10) {
                Button("\(review.owner)/\(review.repo) #\(review.number)") {
                    if let url = URL(string: review.url) { openURL(url) }
                }.buttonStyle(.link)
                Text("\(review.headRef) → \(review.baseRef)")
                Text("+\(review.additions) −\(review.deletions) · \(review.changedFiles) files")
                Text("by \(review.author)")
                Text(review.status.rawValue.capitalized).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(HerdrTheme.elevated, in: .capsule)
                rankingChip(review)
            }
            .herdrFont(.caption)
            .foregroundStyle(HerdrTheme.mist)
            if let error = store.error ?? review.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .herdrFont(.caption).foregroundStyle(HerdrTheme.alert)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(HerdrTheme.elevated, in: .rect(cornerRadius: HerdrTheme.compactRadius))
            }
        }
        .padding(HerdrTheme.cardPadding)
    }

    private func rankingChip(_ review: PRReviewSummary) -> some View {
        Group {
            if review.rankingState == .running { Text("Ranking…") }
            else if review.rankingState == .done { Text("Ranked") }
            else { Button("Rank files") { Task { await store.rank() } }.disabled(!canControl) }
        }
    }

    @ViewBuilder private func content(_ review: PRReviewSummary) -> some View {
        switch store.tab {
        case .files:
            PRReviewFilesView(
                store: store,
                openURL: openURL,
                askAI: askAI,
                questionDraftChanged: questionDraftChanged
            )
        case .context:
            PRReviewContextView(store: store)
        case .agents:
            PRReviewAgentsView(store: store, openPane: openPane)
        case .skills:
            PRReviewSkillsView(store: store, setAddingSkill: setAddingSkill)
        }
    }
}
