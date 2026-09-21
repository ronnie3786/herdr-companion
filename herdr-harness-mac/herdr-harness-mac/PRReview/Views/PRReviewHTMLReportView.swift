import AppKit
import SwiftUI

struct PRReviewHTMLReportView: View {
    @Bindable var store: PRReviewStore
    let document: PRReviewDocument
    @State private var phase: PaneGitWebLoadPhase = .loading
    @State private var reloadID = 0
    @State private var localURL: URL?

    var body: some View {
        ZStack {
            if let localURL {
                PRReviewHTMLContainer(
                    document: PRReviewHTMLDocument(cachedFileURL: localURL),
                    phase: $phase,
                    openExternal: openExternal
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
        .task(id: "\(document.id)|\(reloadID)") {
            do {
                let url = try await store.localURL(for: document)
                store.protectDocumentURL(url)
                localURL = url
            } catch {
                guard !HerdrCancellation.isCancellation(error) else { return }
                phase = .failed(error.localizedDescription)
            }
        }
        .onDisappear {
            if let localURL { store.unprotectDocumentURL(localURL) }
        }
    }

    private func openExternal(_ url: URL) {
        Task { try? await ActiveWorkLinkOpener.open(url) }
    }
}
