import AppKit
import SwiftUI
import WebKit

struct PRReviewHTMLContainer: NSViewRepresentable {
    static let contentSecurityPolicy = "default-src 'none'; img-src file: data:; style-src 'unsafe-inline' file:"
    let document: PRReviewHTMLDocument
    @Binding var phase: PaneGitWebLoadPhase
    let openExternal: (URL) -> Void

    func makeCoordinator() -> PRReviewHTMLNavigationDelegate {
        PRReviewHTMLNavigationDelegate(phase: $phase, openExternal: openExternal)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = Self.webConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.underPageBackgroundColor = NSColor(HerdrTheme.graphite)
        context.coordinator.load(document, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedDocument != document {
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(Self.contentSecurityPolicyUserScript())
        }
        context.coordinator.load(document, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: PRReviewHTMLNavigationDelegate) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
    }

    static func webConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.addUserScript(contentSecurityPolicyUserScript())
        return configuration
    }

    private static func contentSecurityPolicyUserScript() -> WKUserScript {
        WKUserScript(
            source: """
            const meta = document.createElement('meta');
            meta.httpEquiv = 'Content-Security-Policy';
            meta.content = \"\(Self.contentSecurityPolicy)\";
            (document.head || document.documentElement).appendChild(meta);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}

@MainActor
final class PRReviewHTMLNavigationDelegate: NSObject, WKNavigationDelegate {
    private var phase: Binding<PaneGitWebLoadPhase>
    private let openExternal: (URL) -> Void
    private(set) var loadedDocument: PRReviewHTMLDocument?

    init(phase: Binding<PaneGitWebLoadPhase>, openExternal: @escaping (URL) -> Void) {
        self.phase = phase
        self.openExternal = openExternal
    }

    func load(_ document: PRReviewHTMLDocument, in webView: WKWebView) {
        guard loadedDocument != document else { return }
        loadedDocument = document
        phase.wrappedValue = .loading
        webView.loadFileURL(document.fileURL, allowingReadAccessTo: document.readAccessURL)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if loadedDocument?.allows(url) == true { return .allow }
        if action.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            openExternal(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        phase.wrappedValue = .loading
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        phase.wrappedValue = .ready
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        guard !HerdrCancellation.isCancellation(error) else { return }
        phase.wrappedValue = .failed(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        guard !HerdrCancellation.isCancellation(error) else { return }
        phase.wrappedValue = .failed(error.localizedDescription)
    }
}
