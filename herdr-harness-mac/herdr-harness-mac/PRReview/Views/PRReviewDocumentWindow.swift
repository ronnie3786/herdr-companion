import AppKit
import SwiftUI

@MainActor
final class PRReviewDocumentWindow: NSWindowController, NSWindowDelegate {
    /// The pinned key and independent session a document window is built from.
    ///
    /// `makeSession` is the production construction path. The store it returns
    /// belongs to the window alone, so neither a main-window host switch nor a
    /// closing pop-out can retarget or invalidate a retained download.
    struct Session {
        let reuseKey: String
        let windowSession: PRReviewDocumentWindowSession

        var store: PRReviewStore { windowSession.store }
    }

    private static var windows: [String: PRReviewDocumentWindow] = [:]
    private let identifier: String
    /// The window-owned session retains the pinned transport for the window's
    /// whole lifetime, independently of the store that opened it, and observes
    /// later configuration for the same machine through the app model.
    private let windowSession: PRReviewDocumentWindowSession

    private init(
        identifier: String,
        title: String,
        windowSession: PRReviewDocumentWindowSession,
        rootView: some View
    ) {
        self.identifier = identifier
        self.windowSession = windowSession
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

    /// Builds the window's independent, host-pinned session from the
    /// originating presentation store. The transport is captured here and the
    /// originating store is never consulted again, so a failed document can
    /// retry after that store switches hosts or is invalidated by its pop-out
    /// closing.
    static func makeSession(
        kind: String,
        document: PRReviewDocument,
        store: PRReviewStore
    ) -> Session? {
        guard let transport = store.documentTransport(for: document) else { return nil }
        let windowStore = transport.makeStore()
        return Session(
            reuseKey: reuseKey(kind: kind, transport: transport, documentID: document.id),
            windowSession: PRReviewDocumentWindowSession(document: document, store: windowStore)
        )
    }

    static func showMarkdown(document: PRReviewDocument, store: PRReviewStore, host: HerdrAppModel? = nil) {
        show(kind: "markdown", documentKind: .markdown, document: document, store: store, host: host)
    }

    static func showHTML(document: PRReviewDocument, store: PRReviewStore, host: HerdrAppModel? = nil) {
        show(kind: "html", documentKind: .html, document: document, store: store, host: host)
    }

    private static func show(
        kind: String,
        documentKind: PRReviewDocumentWindowKind,
        document: PRReviewDocument,
        store: PRReviewStore,
        host: HerdrAppModel?
    ) {
        guard let session = makeSession(kind: kind, document: document, store: store) else { return }
        if let existing = windows[session.reuseKey] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PRReviewDocumentWindow(
            identifier: session.reuseKey,
            title: document.title,
            windowSession: session.windowSession,
            rootView: PRReviewDocumentWindowRoot(
                kind: documentKind,
                session: session.windowSession,
                host: host
            )
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
        windowSession.stop()
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

/// The root of one retained document window.
///
/// `host` is the live app model when the window was opened from the app. The
/// root then observes the same machine's configuration independently of the
/// originating review window: a credential rotation reconnects the pinned
/// store, a removed host shows an unavailable state instead of keeping an
/// authenticated transport, and a re-added host retries with the new client.
/// `host == nil` (standalone tests and previews) keeps the transport exactly
/// as it was captured.
struct PRReviewDocumentWindowRoot: View {
    let kind: PRReviewDocumentWindowKind
    @Bindable var session: PRReviewDocumentWindowSession
    let host: HerdrAppModel?

    private var document: PRReviewDocument { session.document }

    var body: some View {
        Group {
            if host == nil {
                content
            } else {
                switch session.hostState {
                case .demo, .available:
                    content.id(session.revision)
                case .missingHost:
                    unavailable(
                        title: "Machine unavailable",
                        detail: "\(machineName) is no longer configured. Add it in Settings → Machines, or close this window."
                    )
                case .unconfigured:
                    unavailable(
                        title: "PR Review is not configured",
                        detail: "Add a companion token for \(machineName) in Settings → Machines, then try again."
                    )
                case .checking:
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Opening \(document.title)…")
                            .herdrFont(.caption, monospaced: true, weight: .medium)
                            .foregroundStyle(HerdrTheme.mist)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(HerdrTheme.graphite)
        .foregroundStyle(HerdrTheme.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pr-review-document-window-\(document.id)")
        .task(id: activationIdentity) {
            await activate()
        }
        .onDisappear {
            session.stop()
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .markdown:
            PRReviewMarkdownDocumentView(store: session.store, document: document)
        case .html:
            PRReviewHTMLReportView(store: session.store, document: document)
        }
    }

    private var machineName: String {
        guard let machineID = session.machineID,
              let machine = host?.machines.first(where: { $0.id == machineID })
        else { return "This machine" }
        return machine.name
    }

    /// Reading the probe in the body is what subscribes this window to the
    /// model's machines and connection revision. The identifier deliberately
    /// carries no credential.
    private var activationIdentity: String {
        guard let host, let machineID = session.machineID else { return "pinned" }
        return host.prReviewWindowHostProbe(for: machineID).identifier
    }

    private func activate() async {
        guard let host else { return }
        guard let machineID = session.machineID else {
            await session.activate(identity: "unconfigured", hostState: .unconfigured, client: nil)
            return
        }
        let resolution = host.prReviewWindowHostResolution(for: machineID)
        await session.activate(
            identity: host.prReviewWindowHostProbe(for: machineID).identifier,
            hostState: resolution.state,
            client: resolution.client
        )
    }

    private func unavailable(title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "arrow.triangle.pull")
        } description: {
            Text(detail)
        }
        .foregroundStyle(HerdrTheme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The two in-app document presentations a retained document window shows.
enum PRReviewDocumentWindowKind {
    case markdown
    case html
}

struct PRReviewMarkdownDocumentView: View {
    @Bindable var store: PRReviewStore
    let document: PRReviewDocument
    @State private var source: String?
    @State private var localURL: URL?
    @State private var errorMessage: String?
    @State private var lease: PRReviewDocumentLease?

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
                if let lease { store.releaseDocumentLease(lease) }
                lease = store.acquireDocumentLease(for: url)
                source = String(decoding: data, as: UTF8.self)
            } catch {
                guard !HerdrCancellation.isCancellation(error) else { return }
                errorMessage = error.localizedDescription
            }
        }
        .onDisappear {
            if let lease { store.releaseDocumentLease(lease) }
            lease = nil
        }
    }
}
