import AppKit
import SwiftUI

@MainActor
final class PRReviewDocumentWindow: NSWindowController, NSWindowDelegate {
    /// The pinned key and independent store a document window is built from.
    ///
    /// `makeSession` is the production construction path. The store it returns
    /// belongs to the window alone, so neither a main-window host switch nor a
    /// closing pop-out can retarget or invalidate a retained download.
    struct Session {
        let reuseKey: String
        let store: PRReviewStore
    }

    private static var windows: [String: PRReviewDocumentWindow] = [:]
    private let identifier: String
    /// The window-owned store retains the pinned transport for the window's
    /// whole lifetime, independently of the store that opened it.
    private let documentStore: PRReviewStore

    private init(identifier: String, title: String, documentStore: PRReviewStore, rootView: some View) {
        self.identifier = identifier
        self.documentStore = documentStore
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AnyView(rootView))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PRReviewDocumentWindow is created in code only")
    }

    /// Builds the window's independent, host-pinned store from the originating
    /// presentation store. The transport is captured here and the originating
    /// store is never consulted again, so a failed document can retry after
    /// that store switches hosts or is invalidated by its pop-out closing.
    static func makeSession(
        kind: String,
        document: PRReviewDocument,
        store: PRReviewStore
    ) -> Session? {
        guard let transport = store.documentTransport(for: document) else { return nil }
        return Session(
            reuseKey: reuseKey(kind: kind, transport: transport, documentID: document.id),
            store: transport.makeStore()
        )
    }

    static func showMarkdown(document: PRReviewDocument, store: PRReviewStore) {
        guard let session = makeSession(kind: "markdown", document: document, store: store) else { return }
        if let existing = windows[session.reuseKey] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PRReviewDocumentWindow(
            identifier: session.reuseKey,
            title: document.title,
            documentStore: session.store,
            rootView: PRReviewMarkdownDocumentView(store: session.store, document: document)
        )
        windows[session.reuseKey] = controller
        controller.showWindow(nil)
    }

    static func showHTML(document: PRReviewDocument, store: PRReviewStore) {
        guard let session = makeSession(kind: "html", document: document, store: store) else { return }
        if let existing = windows[session.reuseKey] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PRReviewDocumentWindow(
            identifier: session.reuseKey,
            title: document.title,
            documentStore: session.store,
            rootView: PRReviewHTMLReportView(store: session.store, document: document)
        )
        windows[session.reuseKey] = controller
        controller.showWindow(nil)
    }

    /// Document identity is scoped by machine, review, document, and kind:
    /// server-local document ids can repeat (even for the same review id) on
    /// two configured hosts.
    static func reuseKey(kind: String, document: PRReviewDocument, store: PRReviewStore) -> String {
        reuseKey(
            kind: kind,
            machineID: store.currentMachineID,
            reviewID: document.reviewID,
            documentID: document.id
        )
    }

    static func reuseKey(kind: String, transport: PRReviewDocumentTransport, documentID: String) -> String {
        reuseKey(
            kind: kind,
            machineID: transport.machineID,
            reviewID: transport.reviewID,
            documentID: documentID
        )
    }

    func windowWillClose(_ notification: Notification) {
        Self.windows.removeValue(forKey: identifier)
    }

    private static func reuseKey(
        kind: String,
        machineID: String?,
        reviewID: String,
        documentID: String
    ) -> String {
        "\(kind)|\(machineID ?? "unconfigured")|\(reviewID)|\(documentID)"
    }
}

private struct PRReviewMarkdownDocumentView: View {
    @Bindable var store: PRReviewStore
    let document: PRReviewDocument
    @State private var source: String?
    @State private var localURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView("Document unavailable", systemImage: "doc.text", description: Text(errorMessage))
            } else if let source {
                ScrollView {
                    PiMarkdownMessageView(source: source, isStreaming: false, id: document.id, detectsPaneLinks: false)
                        .frame(maxWidth: HerdrTheme.readingWidth, alignment: .leading)
                        .padding(HerdrTheme.pagePadding)
                }
            } else {
                ProgressView("Loading document…")
            }
        }
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.graphite)
        .task(id: document.id) {
            do {
                let url = try await store.localURL(for: document)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 4 * 1_024 * 1_024 else {
                    errorMessage = "This document is too large to render inline."
                    return
                }
                localURL = url
                store.protectDocumentURL(url)
                source = String(decoding: data, as: UTF8.self)
            } catch {
                guard !HerdrCancellation.isCancellation(error) else { return }
                errorMessage = error.localizedDescription
            }
        }
        .onDisappear {
            if let localURL { store.unprotectDocumentURL(localURL) }
        }
    }
}
