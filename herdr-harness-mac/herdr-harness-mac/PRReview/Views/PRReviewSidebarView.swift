import AppKit
import SwiftUI

struct PRReviewSidebarView: View {
    @Bindable var store: PRReviewStore
    let back: () -> Void
    var canControl = false
    var openURL: (URL) -> Void = { _ in }
    var setCreating: (Bool) -> Void = { _ in }
    @State private var pastedURL = ""
    @State private var validationError: String?

    private var reviews: [PRReviewSummary] {
        store.showArchived ? store.archivedReviews : store.reviews
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
            Button("All sessions", systemImage: "chevron.left", action: back)
                .buttonStyle(.plain)
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
                .accessibilityIdentifier("pr-review-back")

            HStack {
                Label("PR Review", systemImage: "arrow.triangle.pull")
                    .herdrFont(.title3, weight: .semibold)
                Spacer()
                Button("New review", systemImage: "plus", action: presentStartSheet)
                    .labelStyle(.iconOnly)
                    .disabled(!canControl)
                    .help("Start a pull request review")
                    .accessibilityIdentifier("pr-review-new")
            }

            TextField("Paste a GitHub pull request link", text: $pastedURL)
                .textFieldStyle(.roundedBorder)
                .herdrFont(.callout)
                .onSubmit(submitPastedURL)
                .accessibilityIdentifier("pr-review-url-field")
            if let validationError {
                Text(validationError)
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.alert)
            }

            Picker("Reviews", selection: $store.showArchived) {
                Text("Active").tag(false)
                Text("Archived").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pr-review-filter")

            TextField("Search reviews", text: $store.search)
                .textFieldStyle(.roundedBorder)
                .herdrFont(.callout)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if store.unconfigured {
                        empty("Choose the PR review host in Settings → Machines", image: "gearshape")
                    } else if store.unsupported {
                        empty(store.error ?? "Update the companion to a version with pr-review-v1", image: "exclamationmark.triangle")
                    } else if reviews.isEmpty {
                        empty(store.showArchived ? "No archived reviews" : "No active reviews", image: "arrow.triangle.pull")
                    } else {
                        ForEach(filteredReviews) { review in
                            reviewRow(review)
                        }
                    }
                }
            }
        }
        .padding(HerdrTheme.cardPadding)
        .background(HerdrTheme.ink)
        .foregroundStyle(HerdrTheme.text)
        .accessibilityIdentifier("pr-review-sidebar")
    }

    private var filteredReviews: [PRReviewSummary] {
        guard !store.search.isEmpty else { return reviews }
        return reviews.filter {
            $0.title.localizedCaseInsensitiveContains(store.search)
                || $0.owner.localizedCaseInsensitiveContains(store.search)
                || $0.repo.localizedCaseInsensitiveContains(store.search)
        }
    }

    private func reviewRow(_ review: PRReviewSummary) -> some View {
        Button { store.select(review.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(review.title)
                    .herdrFont(.subheadline, weight: .semibold)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(review.owner)/\(review.repo) #\(review.number)")
                    Text("·")
                    Text(review.status.rawValue.capitalized)
                    Text("·")
                    Text("\(review.runningRuns) running")
                }
                .herdrFont(.caption)
                .foregroundStyle(HerdrTheme.mist)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(store.selectedReviewID == review.id ? HerdrTheme.selection : .clear,
                        in: .rect(cornerRadius: HerdrTheme.compactRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pr-review-review-\(review.id)")
        .accessibilityAddTraits(store.selectedReviewID == review.id ? .isSelected : [])
        .contextMenu {
            Button("Open on GitHub") { if let url = URL(string: review.url) { openURL(url) } }
            Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(review.url, forType: .string) }
            Button("Refresh") { Task { await store.refreshReview() } }
            Button(review.archivedAt == nil ? "Archive" : "Unarchive") {
                store.select(review.id)
                Task { await store.archive(review.archivedAt == nil) }
            }
        }
    }

    private func empty(_ text: String, image: String) -> some View {
        ContentUnavailableView(text, systemImage: image)
            .foregroundStyle(HerdrTheme.mist)
            .padding(.top, HerdrTheme.pagePadding)
    }

    private func presentStartSheet() {
        validationError = nil
        store.pendingURL = nil
        store.isPresentingStartSheet = true
        setCreating(true)
    }

    private func submitPastedURL() {
        guard isPullRequestURL(pastedURL) else {
            validationError = "Paste a valid GitHub pull request link."
            return
        }
        validationError = nil
        store.pendingURL = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        store.isPresentingStartSheet = true
        setCreating(true)
    }

    private func isPullRequestURL(_ string: String) -> Bool {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com")
        else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 4 && parts[2] == "pull" && Int(parts[3]) != nil
    }
}
