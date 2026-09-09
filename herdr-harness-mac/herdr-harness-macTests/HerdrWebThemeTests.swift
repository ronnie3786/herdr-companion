import Testing
import WebKit
@testable import herdr_harness_mac

@Suite("Embedded Mac reading theme", .serialized)
@MainActor
struct HerdrWebThemeTests {
    @Test("Mac palette overrides page styles and reaches dynamic diff shadow content")
    func appliesToPageAndShadowContent() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(HerdrWebTheme.userScript())
        let view = WKWebView(frame: .zero, configuration: configuration)
        defer { view.stopLoading() }
        view.loadHTMLString("""
            <html data-theme="light"><head><style>
            :root[data-theme="light"] { --bg: white; --text: black; }
            body { background: var(--bg); color: var(--text); }
            </style></head><body>Synthetic embedded content</body></html>
            """, baseURL: nil)

        // A bounded wait for the actual document-end script, not just loadHTMLString.
        var installed = false
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript(
                "!!document.getElementById('herdr-mac-comfortable-reading')"
            )) as? Bool == true {
                installed = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(installed)
        let values = try await view.evaluateJavaScript("""
            (() => {
              const diff = document.createElement('diffs-container');
              document.body.appendChild(diff);
              const shadow = diff.attachShadow({mode: 'open'});
              shadow.innerHTML = '<style>:host { --diffs-bg: #0b0e13; } p { background: var(--diffs-bg); }</style><p>Synthetic diff</p>';
              return [getComputedStyle(document.body).backgroundColor,
                      getComputedStyle(document.body).color,
                      getComputedStyle(shadow.querySelector('p')).backgroundColor];
            })();
            """) as? [String]
        #expect(values == ["rgb(32, 33, 44)", "rgb(228, 229, 237)", "rgb(32, 33, 44)"])

        let highlights = try await view.evaluateJavaScript("""
            (() => {
              const style = getComputedStyle(document.querySelector('diffs-container'));
              return ['addition', 'deletion'].flatMap(kind =>
                ['', '-number', '-emphasis'].map(part =>
                  style.getPropertyValue(`--diffs-bg-${kind}${part}-override`).trim()));
            })();
            """) as? [String]
        #expect(highlights == [
            "rgb(46 160 67 / 0.30)", "rgb(46 160 67 / 0.42)", "rgb(46 160 67 / 0.55)",
            "rgb(248 81 73 / 0.30)", "rgb(248 81 73 / 0.42)", "rgb(248 81 73 / 0.55)"
        ])

        let fileStyles = try await view.evaluateJavaScript("""
            (() => {
              const row = document.createElement('div');
              row.innerHTML = '<span class="hz-git-file" title="Sources/Garden/WateringSchedule.swift"><span class="hz-git-file-name">WateringSchedule.swift</span><span class="hz-git-file-directory">Sources/Garden</span></span>';
              document.body.appendChild(row);
              const name = getComputedStyle(row.querySelector('.hz-git-file-name'));
              const directory = getComputedStyle(row.querySelector('.hz-git-file-directory'));
              return [name.flexShrink, name.textOverflow, name.overflowWrap, directory.order,
                      row.querySelector('.hz-git-file').title];
            })();
            """) as? [String]
        #expect(fileStyles == ["0", "clip", "anywhere", "-1", "Sources/Garden/WateringSchedule.swift"])
    }
}
