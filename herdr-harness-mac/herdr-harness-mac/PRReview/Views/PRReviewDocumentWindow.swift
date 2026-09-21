import AppKit
import SwiftUI

@MainActor
final class PRReviewDocumentWindow: NSWindowController, NSWindowDelegate {
    private static var windows: [String: PRReviewDocumentWindow] = [:]
    private let identifier: String

    private init(identifier: String, title: String, rootView: some View) {
        self.identifier = identifier
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

    static func showMarkdown(document: PRReviewDocument, store: PRReviewStore) {
        let key = reuseKey(kind: "markdown", document: document, store: store)
        if let existing = windows[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PRReviewDocumentWindow(
            identifier: key,
            title: document.title,
            rootView: PRReviewMarkdownDocumentView(store: store, document: document)
        )
        windows[key] = controller
        controller.showWindow(nil)
    }

    static func showHTML(document: PRReviewDocument, store: PRReviewStore) {
        let key = reuseKey(kind: "html", document: document, store: store)
        if let existing = windows[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = PRReviewDocumentWindow(
            identifier: key,
            title: document.title,
            rootView: PRReviewHTMLReportView(store: store, document: document)
        )
        windows[key] = controller
        controller.showWindow(nil)
    }

    /// Document identity is scoped by machine, review, document, and kind:
    /// server-local document ids can repeat (even for the same review id) on
    /// two configured hosts.
    static func reuseKey(kind: String, document: PRReviewDocument, store: PRReviewStore) -> String {
        let machine = store.currentMachineID ?? "unconfigured"
        return "\(kind)|\(machine)|\(document.reviewID)|\(document.id)"
    }

    func windowWillClose(_ notification: Notification) {
        Self.windows.removeValue(forKey: identifier)
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
