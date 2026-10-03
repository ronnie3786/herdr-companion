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
    var revealRequest: HomeRevealRequest? = nil
    var onRevealHandled: (UUID) -> Void = { _ in }
    var searchFocusRequest = 0
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealLedger = HomeRevealLedger()
    @State private var highlightedTarget: HomeRevealRequest.Target?
    @State private var revealNotice: String?
    @State private var pastedURL = ""
    @State private var validationError: String?

    private var reviews: [PRReviewSummary] {
        store.showArchived ? store.archivedReviews : store.reviews
    }

    var newReviewHelp: String {
        canControl ? "Start a pull request review" : "Choose a PR review host in Settings → Machines or pick a machine"
    }

    static func walkthroughAccessibilityIdentifier(reviewID: String, rowID: String? = nil) -> String {
        "pr-review-walkthrough-\(rowID ?? reviewID)"
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
                    .help(newReviewHelp)
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
                .focused($searchFocused)
                .accessibilityIdentifier("pr-review-search")

            ScrollViewReader { scroll in
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let revealNotice {
                        Label(revealNotice, systemImage: "info.circle")
                            .herdrFont(.caption).foregroundStyle(HerdrTheme.secondaryText)
                            .padding(10).id("home-review-reveal-notice")
                            .accessibilityIdentifier("pr-review-reveal-notice")
                    }
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
                        } else if entries.isEmpty, !fleet.hasLoaded {
                            ProgressView("Loading reviews…")
                                .frame(maxWidth: .infinity)
                                .padding(.top, HerdrTheme.pagePadding)
                                .accessibilityIdentifier("pr-review-fleet-loading")
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
              .task(id: revealAttempt) { await applyReveal(scroll: scroll) }
            }
        }
        .padding(HerdrTheme.cardPadding)
        .herdrPaneBackground(HerdrTheme.railBackground)
        .foregroundStyle(HerdrTheme.text)
        .accessibilityIdentifier("pr-review-sidebar")
        .onChange(of: searchFocusRequest, initial: true) { _, request in
            if request > 0 { searchFocused = true }
        }
        .task(id: highlightedTarget) {
            guard highlightedTarget != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            highlightedTarget = nil
        }
    }

    private var revealAttempt: HomeRevealAttempt {
        if let fleet {
            let available = Set((fleet.active + fleet.archived).map {
                HomeRevealRequest.Target.review(machineID: $0.machineID, reviewID: $0.review.id)
            })
            let present = revealRequest.map { available.contains($0.target) } ?? false
            return HomeRevealAttempt(request: revealRequest,
                                     isReady: present || (fleet.hasLoaded && !fleet.isRefreshing) || fleet.sourceCount == 0,
                                     available: available)
        }
        let available = Set((store.reviews + store.archivedReviews).compactMap { review -> HomeRevealRequest.Target? in
            guard let machineID = store.currentMachineID else { return nil }
            return .review(machineID: machineID, reviewID: review.id)
        })
        let present = revealRequest.map { available.contains($0.target) } ?? false
        return HomeRevealAttempt(request: revealRequest,
                                 isReady: present || (store.hasLoaded && !store.isRefreshing) || store.unconfigured,
                                 available: available)
    }

    @MainActor private func applyReveal(scroll: ScrollViewProxy) async {
        guard let request = revealRequest, case .review(let machineID, let reviewID) = request.target else { return }
        let attempt = revealAttempt
        switch revealLedger.resolve(request, isReady: attempt.isReady, available: attempt.available) {
        case .waiting, .alreadyHandled: return
        case .missing(let message):
            revealNotice = message
            highlightedTarget = nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            scroll.scrollTo("home-review-reveal-notice", anchor: .top)
        case .available:
            revealNotice = nil
            store.search = ""
            if let fleet {
                store.showArchived = !fleet.active.contains { $0.machineID == machineID && $0.review.id == reviewID }
            } else {
                store.showArchived = !store.reviews.contains { $0.id == reviewID }
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo(request.target, anchor: .center) }
            highlightedTarget = request.target
        }
        revealLedger.markHandled(request)
        onRevealHandled(request.id)
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
            reviewLabel(review, selected: selected, machineName: entry.machineName, rowID: entry.id.id)
        }
        .buttonStyle(.herdrPlain)
        .id(HomeRevealRequest.Target.review(machineID: entry.machineID, reviewID: review.id))
        .overlay(RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
            .strokeBorder(highlightedTarget == .review(machineID: entry.machineID, reviewID: review.id) ? HerdrTheme.accent : .clear, lineWidth: 2)
            .allowsHitTesting(false))
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
        .id(HomeRevealRequest.Target.review(machineID: store.currentMachineID ?? "", reviewID: review.id))
        .overlay(RoundedRectangle(cornerRadius: HerdrTheme.compactRadius)
            .strokeBorder(highlightedTarget == .review(machineID: store.currentMachineID ?? "", reviewID: review.id) ? HerdrTheme.accent : .clear, lineWidth: 2)
            .allowsHitTesting(false))
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

    private func reviewLabel(_ review: PRReviewSummary, selected: Bool, machineName: String? = nil, rowID: String? = nil) -> some View {
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
                    .accessibilityIdentifier(Self.walkthroughAccessibilityIdentifier(reviewID: review.id, rowID: rowID))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(selected ? HerdrTheme.selection : .clear,
                    in: .rect(cornerRadius: HerdrTheme.compactRadius))
        .contentShape(.rect)
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
