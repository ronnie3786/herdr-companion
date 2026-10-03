import AppKit
import SwiftUI

struct PRReviewHTMLReportView: View {
    @Bindable var store: PRReviewStore
    let document: PRReviewDocument
    var documentHost: HerdrAppModel? = nil
    @State private var linkError: String?
    @State private var phase: PaneGitWebLoadPhase = .loading
    @State private var reloadID = 0
    @State private var localURL: URL?
    @State private var lease: PRReviewDocumentLease?

    var body: some View {
        ZStack {
            if let localURL {
                PRReviewHTMLContainer(
                    document: PRReviewHTMLDocument(cachedFileURL: localURL),
                    phase: $phase,
                    openExternal: openExternal,
                    openDocument: openDocument
                )
                .id(reloadID)
            }
            switch phase {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading review report…")
                        .herdrFont(.caption, monospaced: true, weight: .medium)
                        .foregroundStyle(HerdrTheme.mist)
                }
            case .ready:
                EmptyView()
            case let .failed(message):
                ContentUnavailableView {
                    Label("Report unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        phase = .loading
                        reloadID &+= 1
                    }
                    .herdrProminentButton()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.graphite)
        .accessibilityIdentifier("pr-review-html-report")
        .overlay(alignment: .bottom) {
            if let linkError {
                Text(linkError).herdrFont(.callout).foregroundStyle(HerdrTheme.alert)
                    .padding(12).background(HerdrTheme.windowBackground)
            }
        }
        .task(id: "\(document.id)|\(reloadID)") {
            do {
                let url = try await store.localURL(for: document)
                if let lease { store.releaseDocumentLease(lease) }
                lease = store.acquireDocumentLease(for: url)
                localURL = url
            } catch {
                guard !HerdrCancellation.isCancellation(error) else { return }
                phase = .failed(error.localizedDescription)
            }
        }
        .onDisappear {
            if let lease { store.releaseDocumentLease(lease) }
            lease = nil
        }
    }

    private func openExternal(_ url: URL) {
        Task { try? await HerdrExternalLinkOpener.open(url) }
    }

    private func openDocument(_ id: String) {
        linkError = nil
        Task {
            do {
                let linked = try await store.linkedReportDocument(id: id, reviewID: document.reviewID)
                switch linked.kind {
                case .markdown: PRReviewDocumentWindow.showMarkdown(document: linked, store: store, host: documentHost)
                case .html: PRReviewDocumentWindow.showHTML(document: linked, store: store, host: documentHost)
                default: linkError = "This link does not point to a review report."
                }
            } catch {
                guard !HerdrCancellation.isCancellation(error) else { return }
                linkError = error.localizedDescription
            }
        }
    }
}
