import AppKit
import SwiftUI

struct PRReviewSidebarView: View {
    @Bindable var store: PRReviewStore
    let back: () -> Void
    var canControl = false
    var openURL: (URL) -> Void = { _ in }
    var setCreating: (Bool) -> Void = { _ in }
    var popOut: ((PRReviewWindowTarget) -> Void)?
    var fleet: PRReviewFleetIndex? = nil
    var openFleetReview: ((PRReviewWindowTarget) -> Void)? = nil
    var archiveFleetReview: ((PRReviewWindowTarget, Bool) -> Void)? = nil
    var refreshFleetReview: ((PRReviewWindowTarget) -> Void)? = nil
    @State private var pastedURL = ""
    @State private var validationError: String?

    private var reviews: [PRReviewSummary] {
        store.showArchived ? store.archivedReviews : store.reviews
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HerdrTheme.rowSpacing) {
            Button("All sessions", systemImage: "chevron.left", action: back)
                .buttonStyle(.herdrPlain)
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
            .tint(HerdrTheme.controlAccent)
            .accessibilityIdentifier("pr-review-filter")

            TextField("Search reviews", text: $store.search)
                .textFieldStyle(.roundedBorder)
                .herdrFont(.callout)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let fleet {
                        ForEach(fleet.notices) { notice in
                            Label("\(notice.machineName): \(notice.message)", systemImage: "exclamationmark.triangle")
                                .herdrFont(.caption)
                                .foregroundStyle(HerdrTheme.alert)
                                .padding(10)
                                .accessibilityIdentifier("pr-review-host-notice-\(notice.machineID)")
                        }
                        let entries = filteredFleetReviews(fleet)
                        if fleet.sourceCount == 0 {
                            empty("Pair a machine in Settings → Machines", image: "gearshape")
                        } else if entries.isEmpty {
                            empty(store.showArchived ? "No archived reviews" : "No active reviews", image: "arrow.triangle.pull")
                        } else {
                            ForEach(entries) { entry in
                                fleetReviewRow(entry)
                            }
                        }
                    } else if store.unconfigured {
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
        .herdrPaneBackground(HerdrTheme.railBackground)
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

    private func filteredFleetReviews(_ fleet: PRReviewFleetIndex) -> [PRReviewFleetEntry] {
        let entries = store.showArchived ? fleet.archived : fleet.active
        guard !store.search.isEmpty else { return entries }
        return entries.filter {
            $0.review.title.localizedCaseInsensitiveContains(store.search)
                || $0.review.owner.localizedCaseInsensitiveContains(store.search)
                || $0.review.repo.localizedCaseInsensitiveContains(store.search)
                || $0.machineName.localizedCaseInsensitiveContains(store.search)
        }
    }

    private func fleetReviewRow(_ entry: PRReviewFleetEntry) -> some View {
        let review = entry.review
        let selected = entry.machineID == store.currentMachineID && review.id == store.selectedReviewID
        return Button { openFleetReview?(entry.id) } label: {
            reviewLabel(review, selected: selected, machineName: entry.machineName)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityIdentifier("pr-review-review-\(entry.id.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if let popOut, review.archivedAt == nil {
                let target = PRReviewWindowTarget(machineID: entry.machineID, reviewID: review.id)
                Button("Pop Out into Window") { popOut(target) }
                    .accessibilityIdentifier(target.popOutActionAccessibilityIdentifier)
            }
            Button("Open on GitHub") { if let url = URL(string: review.url) { openURL(url) } }
            Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(review.url, forType: .string) }
            Button("Refresh") { refreshFleetReview?(entry.id) }
            Button(review.archivedAt == nil ? "Archive" : "Unarchive") {
                archiveFleetReview?(entry.id, review.archivedAt == nil)
            }
        }
    }

    private func reviewRow(_ review: PRReviewSummary) -> some View {
        Button { store.select(review.id) } label: {
            reviewLabel(review, selected: store.selectedReviewID == review.id)
        }
        .buttonStyle(.herdrPlain)
        .accessibilityIdentifier("pr-review-review-\(review.id)")
        .accessibilityAddTraits(store.selectedReviewID == review.id ? .isSelected : [])
        .contextMenu {
            if let popOut, review.archivedAt == nil, let machineID = store.currentMachineID {
                let target = PRReviewWindowTarget(machineID: machineID, reviewID: review.id)
                Button("Pop Out into Window") { popOut(target) }
                    .accessibilityIdentifier(target.popOutActionAccessibilityIdentifier)
            }
            Button("Open on GitHub") { if let url = URL(string: review.url) { openURL(url) } }
            Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(review.url, forType: .string) }
            Button("Refresh") { Task { await store.refreshReview() } }
            Button(review.archivedAt == nil ? "Archive" : "Unarchive") {
                store.select(review.id)
                Task { await store.archive(review.archivedAt == nil) }
            }
        }
    }

    private func reviewLabel(_ review: PRReviewSummary, selected: Bool, machineName: String? = nil) -> some View {
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
            if let machineName {
                Label(machineName, systemImage: "desktopcomputer")
                    .herdrFont(.caption)
                    .foregroundStyle(HerdrTheme.mist)
            }
            if let walkthrough = PRReviewWalkthroughRowStatus(review.walkthrough) {
                Label(walkthrough.text, systemImage: walkthrough.systemImage)
                    .herdrFont(.caption, weight: walkthrough.isNew ? .semibold : .regular)
                    .foregroundStyle(walkthrough.failed ? HerdrTheme.alert : walkthrough.isNew ? HerdrTheme.accent : HerdrTheme.mist)
                    .accessibilityIdentifier("pr-review-walkthrough-\(review.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(selected ? HerdrTheme.selection : .clear,
                    in: .rect(cornerRadius: HerdrTheme.compactRadius))
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

/// A review row's walkthrough line: preparing, newly ready, or newly failed.
/// A walkthrough someone already opened needs no line.
struct PRReviewWalkthroughRowStatus: Equatable {
    let text: String
    let systemImage: String
    let isNew: Bool
    let failed: Bool

    init?(_ walkthrough: PRReviewWalkthroughSummary?) {
        guard let walkthrough else { return nil }
        switch walkthrough.state {
        case "running":
            (text, systemImage, isNew, failed) = ("Preparing walkthrough…", "hourglass", false, false)
        case "finished" where walkthrough.isNew:
            (text, systemImage, isNew, failed) = ("Walkthrough ready", "sparkles", true, false)
        case "failed" where walkthrough.isNew:
            (text, systemImage, isNew, failed) = ("Walkthrough couldn’t finish", "exclamationmark.triangle", true, true)
        default:
            return nil
        }
    }
}
