import SwiftUI

extension View {
    /// Presents First Mate Git full screen for `item`.
    func firstMateGitCover(item: Binding<FirstMateGitTarget?>, model: HerdrAppModel) -> some View {
        fullScreenCover(item: item) { target in
            FirstMateGitScreen(target: target, model: model)
        }
    }
}

/// First Mate Git for one feature, full screen. Regular width (iPad) shows
/// the changes and commits beside the selected diff. Compact width (iPhone)
/// shows the list first; a file or commit pushes its diff.
struct FirstMateGitScreen: View {
    let target: FirstMateGitTarget
    let model: HerdrAppModel
    @State private var store: FirstMateGitStore
    @State private var path: [FirstMateGitSelection]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(target: FirstMateGitTarget, model: HerdrAppModel) {
        self.init(target: target, model: model,
                  store: FirstMateGitStore(pinnedCheckoutID: target.workspaceID, commitSHA: target.commitSHA))
    }

    /// Tests pass a store they have already loaded, and on iPhone the row
    /// they have already opened.
    init(target: FirstMateGitTarget, model: HerdrAppModel, store: FirstMateGitStore, pushed: FirstMateGitSelection? = nil) {
        self.target = target
        self.model = model
        _store = State(initialValue: store)
        // On iPhone a commit receipt opens with that commit pushed.
        let route = pushed ?? target.commitSHA.map { FirstMateGitSelection.commit(hash: $0) }
        _path = State(initialValue: route.map { [$0] } ?? [])
    }

    var body: some View {
        Group {
            if sizeClass == .compact { compact } else { regular }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("first-mate-git")
        .herdrAppChrome(separateSurface: true)
        .task {
            guard !store.hasStarted else { return }
            await store.start(backend: makeBackend())
        }
    }

    // MARK: Layouts

    private var regular: some View {
        VStack(spacing: 0) {
            header(compact: false)
            content {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        FirstMateGitListView(store: store, compact: false) { store.select($0) }
                            .frame(width: min(max(300, proxy.size.width * 0.34), proxy.size.width * 0.5))
                            .background { FirstMateGitSurface.list.ignoresSafeArea(edges: .bottom) }
                            .herdrHairline(.trailing)
                            .composerLayoutMeasurement(id: "first-mate-git-list-column")
                        FirstMateGitDetailView(store: store, checkoutTitle: checkoutTitle, compact: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background { FirstMateGitSurface.diff.ignoresSafeArea(edges: .bottom) }
                            .composerLayoutMeasurement(id: "first-mate-git-detail-column")
                    }
                }
            }
        }
    }

    private var compact: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header(compact: true)
                content {
                    FirstMateGitListView(store: store, compact: true) { selection in
                        store.select(selection)
                        path = [selection]
                    }
                    .background { FirstMateGitSurface.list.ignoresSafeArea(edges: .bottom) }
                    .composerLayoutMeasurement(id: "first-mate-git-list-column")
                }
            }
            // The navigation container paints its own surface; give it the dusk.
            .containerBackground(for: .navigation) { FirstMateGitBackdrop() }
            .navigationTitle("Git")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: FirstMateGitSelection.self) { _ in
                FirstMateGitDetailView(store: store, checkoutTitle: checkoutTitle, compact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { FirstMateGitSurface.diff.ignoresSafeArea() }
                    .containerBackground(for: .navigation) { FirstMateGitBackdrop() }
                    .navigationTitle(pushedTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .herdrNavigationBarChrome()
                    .composerLayoutMeasurement(id: "first-mate-git-detail-column")
            }
        }
    }

    private func header(compact: Bool) -> some View {
        FirstMateGitHeaderBar(
            store: store,
            title: "\(target.featureTitle) · Git",
            subtitle: subtitle,
            compact: compact,
            done: { dismiss() },
            chooseCheckout: { id in
                path = []
                Task { await store.selectCheckout(id) }
            }
        )
    }

    /// The catalog and status states around the ready content. States sit
    /// on the pane surface, like the list and diff they stand in for.
    @ViewBuilder
    private func content<Ready: View>(@ViewBuilder ready: () -> Ready) -> some View {
        if let blocking {
            blockingView(blocking)
                .background { FirstMateGitSurface.diff.ignoresSafeArea(edges: .bottom) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("first-mate-git-state")
        } else {
            ready()
        }
    }

    @ViewBuilder
    private func blockingView(_ blocking: Blocking) -> some View {
        switch blocking {
        case let .loading(text):
            FirstMateGitMessage.loading(text)
        case let .message(symbol, title, detail, retries):
            let action: (() -> Void)? = retries ? { retry() } : nil
            FirstMateGitMessage(symbol: symbol, title: title, detail: detail, retry: action)
        }
    }

    private enum Blocking {
        case loading(String)
        case message(symbol: String, title: String, detail: String, retries: Bool)
    }

    private var blocking: Blocking? {
        switch store.phase {
        case .loading:
            return .loading("Loading Git from \(machineName)…")
        case .unsupported:
            return .message(symbol: "arrow.triangle.branch", title: "Git needs a server update",
                            detail: "Update the companion on \(machineName), this feature’s machine, to use First Mate Git.",
                            retries: true)
        case let .failed(message):
            return .message(symbol: "exclamationmark.triangle", title: "Git unavailable", detail: message, retries: true)
        case .ready:
            break
        }
        guard let checkout = store.selectedCheckout else {
            if store.selectedCheckoutID.isEmpty {
                return .message(symbol: "arrow.triangle.branch", title: "Choose a checkout",
                                detail: store.catalog?.selectionMessage ?? "Choose the feature branch from the checkout menu above.",
                                retries: false)
            }
            return .message(symbol: "questionmark.folder", title: "Checkout unavailable",
                            detail: "This feature no longer lists checkout \(store.selectedCheckoutID).", retries: true)
        }
        switch store.statusPhase {
        case .idle, .loading:
            return .loading("Reading \(checkout.title)…")
        case .noRepository:
            return .message(symbol: "folder.badge.questionmark", title: "No Git repository",
                            detail: "\(checkout.path) isn’t inside a Git repository.", retries: true)
        case let .unavailable(message):
            return .message(symbol: "questionmark.folder", title: "Checkout unavailable", detail: message, retries: true)
        case let .failed(message):
            return .message(symbol: "exclamationmark.triangle", title: "Git unavailable", detail: message, retries: true)
        case .loaded:
            return store.status == nil ? .loading("Reading \(checkout.title)…") : nil
        }
    }

    // MARK: Helpers

    private func retry() {
        Task {
            if store.backend == nil { await store.start(backend: makeBackend()) } else { await store.reload() }
        }
    }

    private func makeBackend() -> (any FirstMateGitBackend)? {
        if model.isDemoMode {
            return FirstMateGitDemoBackend(featureID: target.feature.featureID, featureTitle: target.featureTitle)
        }
        return model.client(forMachine: target.feature.machineID)
            .map { FirstMateGitLiveBackend(client: $0, featureID: target.feature.featureID) }
    }

    private var machineName: String {
        model.machines.first { $0.id == target.feature.machineID }?.name ?? target.feature.machineID
    }

    /// "machine · checkout · path", or as much of it as is known.
    private var subtitle: String {
        guard store.phase == .ready else { return machineName }
        guard let checkout = store.selectedCheckout else {
            return [machineName, store.selectedCheckoutID.isEmpty ? "Choose a checkout" : store.selectedCheckoutID]
                .joined(separator: " · ")
        }
        return [machineName, checkout.title, store.status?.rootPath ?? checkout.path].joined(separator: " · ")
    }

    private var checkoutTitle: String {
        store.selectedCheckout?.title ?? (store.selectedCheckoutID.isEmpty ? "No checkout" : store.selectedCheckoutID)
    }

    private var pushedTitle: String {
        switch store.selection {
        case let .file(path, _): FirstMateGitPath(path).name
        case let .commit(hash): String(hash.prefix(7))
        case nil: "Git"
        }
    }
}

/// The cover's surfaces: the list a step lighter than the diff, both over
/// the dusk when Herdr glass is on.
enum FirstMateGitSurface {
    static let diffBase = Color(.sRGB, red: 16 / 255, green: 16 / 255, blue: 20 / 255)

    static var list: some View { HerdrGlassBackground(level: HerdrTheme.Glass.sidebar, base: HerdrTheme.windowBackground) }
    static var diff: some View { HerdrGlassBackground(level: 0.9, base: diffBase) }
    static var bar: some View { HerdrGlassBackground(level: 0.92, base: HerdrTheme.railBackground) }
}

/// Herdr's window backdrop: the dusk while glass is on, else the base.
struct FirstMateGitBackdrop: View {
    @Environment(\.herdrGlassActive) private var active
    var body: some View { HerdrAppBackdrop(active: active) }
}

/// A centered state: loading, unsupported, an error with Try again, or a
/// prompt to choose a checkout.
struct FirstMateGitMessage: View {
    let symbol: String
    let title: String
    let detail: String
    var retry: (() -> Void)?

    static func loading(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().tint(HerdrTheme.accent)
            Text(text)
                .herdrFont(.subheadline)
                .foregroundStyle(HerdrTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(HerdrTheme.iconTint)
                .accessibilityHidden(true)
            Text(title)
                .herdrFont(size: 17, weight: .semibold, relativeTo: .headline)
                .foregroundStyle(HerdrTheme.primaryText)
            Text(detail)
                .herdrFont(.subheadline)
                .foregroundStyle(HerdrTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let retry {
                Button("Try again", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(HerdrButtonStyle(kind: .outline))
                    .padding(.top, 6)
                    .accessibilityIdentifier("first-mate-git-retry")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
