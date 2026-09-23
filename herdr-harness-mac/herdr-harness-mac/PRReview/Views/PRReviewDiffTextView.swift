import AppKit
import CryptoKit
import SwiftUI
import WebKit

/// Local WebKit host for the same bundled Pierre renderer used by Chat Git and
/// First Mate Git. The document and every syntax grammar ship in the app, so an
/// already-loaded PR remains readable without the companion or network.
final class PRReviewDiffTextView: WKWebView, WKScriptMessageHandler, WKNavigationDelegate, NSPopoverDelegate {
    var askAI: ((PRReviewSelection, NSView, CGRect) -> Void)?
    var questionDraftChanged: ((Bool) -> Void)?
    var onVisibleLinesChange: ((String, Int, Int, PRReviewSide) -> Void)?
    private(set) var renderedIdentity: String?
    private(set) var renderedPlainText = ""
    private(set) var isRendererReady = false
    private(set) var visibleLines: (path: String, start: Int, end: Int, side: PRReviewSide)?
    private var pendingPayload: PRReviewDiffRenderer.Payload?
    private var pendingScroll: (line: Int, side: PRReviewSide)?
    private var rendererURL: URL?
    private var askPopover: NSPopover?

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        super.init(frame: .zero, configuration: configuration)
        configuration.userContentController.add(self, name: Self.bridgeName)
        navigationDelegate = self
        setAccessibilityIdentifier("pr-review-diff-text")
        allowsBackForwardNavigationGestures = false
        allowsLinkPreview = false
        underPageBackgroundColor = NSColor(HerdrTheme.graphite)
        loadBundledRenderer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PRReviewDiffTextView must be created programmatically")
    }

    func render(_ payload: PRReviewDiffRenderer.Payload) {
        if pendingPayload?.identity != payload.identity {
            closePopover()
            visibleLines = nil
            renderedIdentity = nil
            pendingScroll = nil
        }
        pendingPayload = payload
        renderedPlainText = payload.plainText
        guard isRendererReady else { return }
        send(payload)
    }

    func scrollToLine(_ line: Int, side: PRReviewSide) {
        guard line > 0 else { return }
        pendingScroll = (line, side)
        sendPendingScroll()
    }

    private func sendPendingScroll() {
        guard let pendingScroll, let payload = pendingPayload,
              isRendererReady, renderedIdentity == payload.identity,
              let data = try? JSONSerialization.data(withJSONObject: [
                "line": pendingScroll.line, "side": pendingScroll.side == .before ? "old" : "new",
                "identity": payload.identity,
              ]), let json = String(data: data, encoding: .utf8)
        else { return }
        self.pendingScroll = nil
        evaluateJavaScript("window.herdrNativeDiff?.scrollToLine(\(json))")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url == rendererURL ? .allow : .cancel
    }

    func isLineVisible(_ line: Int, side: PRReviewSide) -> Bool {
        guard let visibleLines, visibleLines.side == side else { return false }
        return visibleLines.start...visibleLines.end ~= line
    }

    func closePopover() {
        askPopover?.close()
        askPopover = nil
    }

    func tearDown() {
        closePopover()
        stopLoading()
        configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.name == Self.bridgeName,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        guard kind == "bridgeReady" || body["identity"] as? String == pendingPayload?.identity else { return }
        switch kind {
        case "bridgeReady":
            isRendererReady = true
            if let pendingPayload { send(pendingPayload) }
        case "ready":
            renderedIdentity = body["identity"] as? String
            sendPendingScroll()
        case "visibleLines":
            receiveVisibleLines(body)
        case "ask":
            receiveAsk(body)
        default:
            break
        }
    }

    func popoverDidClose(_ notification: Notification) {
        questionDraftChanged?(false)
        askPopover = nil
    }

    private static let bridgeName = "herdrDiffBridge"

    private func loadBundledRenderer() {
        let bundles = [Bundle.main, Bundle(for: PRReviewDiffTextView.self)]
        guard let url = bundles.lazy.compactMap({
            $0.url(forResource: "PRReviewDiffRenderer", withExtension: "html")
        }).first else {
            loadHTMLString("<html><body style='background:#20212c;color:#e8eaed'>Diff renderer unavailable.</body></html>", baseURL: nil)
            return
        }
        rendererURL = url
        loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    private func send(_ payload: PRReviewDiffRenderer.Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let encoded = data.base64EncodedString()
        evaluateJavaScript("window.herdrNativeDiff?.renderJSON('\(encoded)')")
    }

    private func receiveVisibleLines(_ body: [String: Any]) {
        guard let path = body["path"] as? String,
              let start = body["start"] as? Int,
              let end = body["end"] as? Int,
              let sideValue = body["side"] as? String,
              ["old", "new"].contains(sideValue), start > 0, end >= start,
              path == pendingPayload?.path
        else { return }
        let side: PRReviewSide = sideValue == "old" ? .before : .after
        visibleLines = (path, start, end, side)
        onVisibleLinesChange?(path, start, end, side)
    }

    private func receiveAsk(_ body: [String: Any]) {
        guard let path = body["path"] as? String,
              let oldPath = body["oldPath"] as? String,
              let rawSpans = body["spans"] as? [[String: Any]],
              let rect = Self.rect(from: body["rect"]),
              path == pendingPayload?.path, oldPath == pendingPayload?.oldPath
        else { return }
        let spans = Self.coalescedSpans(rawSpans)
        guard !spans.isEmpty else { return }
        let selectedText = (body["exactCode"] as? String) ?? (body["code"] as? String) ?? ""
        let selection = PRReviewSelection(path: path, oldPath: oldPath, spans: spans, text: selectedText)
        let anchor = isFlipped ? rect : CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        let clipped = anchor.intersection(bounds)
        showQuestionPopover(selection: selection, anchor: clipped.isNull ? CGRect(x: 8, y: 8, width: 1, height: 1) : clipped)
    }

    private func showQuestionPopover(selection: PRReviewSelection, anchor: CGRect) {
        closePopover()
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = NSSize(width: 380, height: 250)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PRReviewAskPopover(
            selection: selection,
            send: { [weak self] question in
                guard let self else { return }
                self.questionDraftChanged?(false)
                self.askPopover?.close()
                var questionSelection = selection
                questionSelection.question = question
                self.askAI?(questionSelection, self, anchor)
            },
            dismiss: { [weak self] in self?.askPopover?.close() },
            draftChanged: { [weak self] isNonEmpty in self?.questionDraftChanged?(isNonEmpty) }
        ))
        askPopover = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    private static func rect(from value: Any?) -> CGRect? {
        guard let value = value as? [String: Any],
              let x = value["x"] as? Double,
              let y = value["y"] as? Double,
              let width = value["width"] as? Double,
              let height = value["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func coalescedSpans(_ rawSpans: [[String: Any]]) -> [PRReviewSelection.Span] {
        var result: [PRReviewSelection.Span] = []
        for raw in rawSpans {
            guard let line = raw["startLine"] as? Int, line > 0,
                  let sideValue = raw["side"] as? String, ["old", "new", "unknown"].contains(sideValue) else { continue }
            let side: PRReviewSide = (raw["side"] as? String) == "old" ? .before : .after
            if let last = result.last, last.side == side, last.end + 1 == line {
                result[result.count - 1].end = line
            } else {
                result.append(.init(side: side, start: line, end: line))
            }
        }
        return result
    }
}

struct PRReviewDiffText: NSViewRepresentable {
    let file: PRReviewDiffFile
    var baseSHA = ""
    var headSHA = ""
    @Environment(\.herdrFontScale) private var fontScale
    var highlight: (start: Int, end: Int, side: PRReviewSide)?
    var scrollRequest: (path: String, line: Int, side: PRReviewSide, token: Int)?
    var askAI: ((PRReviewSelection, NSView, CGRect) -> Void)?
    var questionDraftChanged: ((Bool) -> Void)?
    var onVisibleLinesChange: ((String, Int, Int, PRReviewSide) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PRReviewDiffTextView {
        let view = PRReviewDiffTextView()
        context.coordinator.install(view)
        return view
    }

    func updateNSView(_ view: PRReviewDiffTextView, context: Context) {
        view.askAI = askAI
        view.questionDraftChanged = questionDraftChanged
        view.onVisibleLinesChange = onVisibleLinesChange
        let identity = Coordinator.RenderIdentity(
            path: file.path,
            oldPath: file.oldPath,
            baseSHA: baseSHA,
            headSHA: headSHA,
            fontScale: fontScale
        )
        if context.coordinator.shouldRender(identity: identity, file: file, highlight: highlight) {
            view.render(PRReviewDiffRenderer.payload(
                file: file,
                identity: identity.value,
                fontScale: fontScale,
                highlight: highlight
            ))
            context.coordinator.lastRenderedIdentity = identity
            context.coordinator.lastFile = file
            context.coordinator.lastHighlight = RenderHighlight(highlight)
        }
        if let scrollRequest, scrollRequest.path == file.path,
           context.coordinator.lastScrollToken != scrollRequest.token {
            context.coordinator.lastScrollToken = scrollRequest.token
            view.scrollToLine(scrollRequest.line, side: scrollRequest.side)
        }
    }

    static func dismantleNSView(_ view: PRReviewDiffTextView, coordinator: Coordinator) {
        view.tearDown()
        coordinator.invalidate()
    }

    fileprivate struct RenderHighlight: Equatable {
        let start: Int
        let end: Int
        let side: PRReviewSide

        init?(_ value: (start: Int, end: Int, side: PRReviewSide)?) {
            guard let value else { return nil }
            start = value.start
            end = value.end
            side = value.side
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        struct RenderIdentity: Equatable {
            let path: String
            let oldPath: String?
            let baseSHA: String
            let headSHA: String
            let fontScale: HerdrFontScale

            var value: String {
                [path, oldPath ?? "", baseSHA, headSHA, String(fontScale.rawValue)]
                    .joined(separator: "\u{1f}")
            }
        }

        var lastScrollToken: Int?
        var lastRenderedIdentity: RenderIdentity?
        var lastFile: PRReviewDiffFile?
        fileprivate var lastHighlight: RenderHighlight?
        private weak var view: PRReviewDiffTextView?

        func shouldSetAttributedString(for identity: RenderIdentity) -> Bool {
            lastRenderedIdentity != identity
        }

        fileprivate func shouldRender(
            identity: RenderIdentity,
            file: PRReviewDiffFile,
            highlight: (start: Int, end: Int, side: PRReviewSide)?
        ) -> Bool {
            shouldSetAttributedString(for: identity) || lastFile != file || lastHighlight != RenderHighlight(highlight)
        }

        func install(_ view: PRReviewDiffTextView) { self.view = view }
        func invalidate() { view = nil }
    }
}

enum PRReviewDiffRenderer {
    struct Payload: Encodable {
        struct Highlight: Encodable {
            let start: Int
            let end: Int
            let side: String
        }

        let identity: String
        let path: String
        let oldPath: String
        let patch: String
        let plainText: String
        let fontScale: Double
        let highlight: Highlight?
    }

    static func payload(
        file: PRReviewDiffFile,
        identity: String,
        fontScale: HerdrFontScale = .medium,
        highlight: (start: Int, end: Int, side: PRReviewSide)? = nil
    ) -> Payload {
        let patch = patch(for: file)
        let digest = SHA256.hash(data: Data(patch.utf8)).map { String(format: "%02x", $0) }.joined()
        return Payload(
            identity: identity + ":" + digest,
            path: file.path,
            oldPath: file.oldPath ?? "",
            patch: patch,
            plainText: plainText(for: file),
            fontScale: fontScale.rawValue,
            highlight: highlight.map {
                Payload.Highlight(start: $0.start, end: $0.end, side: $0.side == .before ? "old" : "new")
            }
        )
    }

    static func patch(for file: PRReviewDiffFile) -> String {
        let oldPath = file.oldPath?.isEmpty == false ? (file.oldPath ?? file.path) : file.path
        let before = quotedPath("a/" + oldPath)
        let after = quotedPath("b/" + file.path)
        var lines = ["diff --git \(before) \(after)"]
        switch file.status {
        case "added":
            lines.append("new file mode 100644")
            lines.append("--- /dev/null")
            lines.append("+++ \(after)")
        case "deleted":
            lines.append("deleted file mode 100644")
            lines.append("--- \(before)")
            lines.append("+++ /dev/null")
        default:
            lines.append("--- \(before)")
            lines.append("+++ \(after)")
        }
        for hunk in file.hunks {
            // Use the structured coordinates, not a presentation-only header
            // (legacy/demo snapshots may supply just @@). Partial hunks count
            // only the lines actually available so the parser can show them.
            let oldCount = hunk.lines.filter { $0.kind != "add" }.count
            let newCount = hunk.lines.filter { $0.kind != "del" }.count
            let suffix = hunk.header.components(separatedBy: "@@").dropFirst(2).joined(separator: "@@")
            lines.append("@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@\(suffix)")
            for line in hunk.lines {
                let prefix = line.kind == "add" ? "+" : line.kind == "del" ? "-" : " "
                lines.append(prefix + line.text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quotedPath(_ path: String) -> String {
        guard path.utf8.contains(where: { $0 <= 32 || $0 >= 127 || $0 == 34 || $0 == 92 }) else { return path }
        return "\"" + path.utf8.map { byte -> String in
            switch byte {
            case 34: return "\\\""
            case 92: return "\\\\"
            case 0...31, 127...255: return String(format: "\\%03o", byte)
            default: return String(UnicodeScalar(byte))
            }
        }.joined() + "\""
    }

    static func plainText(for file: PRReviewDiffFile) -> String {
        file.hunks.flatMap { hunk in
            [hunk.header] + hunk.lines.map { line in
                let prefix = line.kind == "add" ? "+" : line.kind == "del" ? "-" : " "
                return prefix + line.text
            }
        }.joined(separator: "\n")
    }
}
