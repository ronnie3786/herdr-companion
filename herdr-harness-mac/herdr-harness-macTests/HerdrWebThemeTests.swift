import AppKit
import SwiftUI
import Testing
import WebKit
@testable import herdr_harness_mac

@Suite("Embedded Mac reading theme", .serialized)
@MainActor
struct HerdrWebThemeTests {
    @Test("The Mac supplies Mono surfaces, change colors, spacing and syntax to the shared renderer")
    func embeddedGitUsesMonoDiffTheme() {
        let css = HerdrWebTheme.css
        #expect(css.contains("--herdr-diff-background:"))
        #expect(css.contains("--herdr-diff-selection:"))
        // Mono × Herdr: the native Git view and the web diffs share one palette,
        // so the Mac now sets the renderer's row, number and syntax variables on
        // `diffs-container` (outer declarations beat the renderer's `:host`).
        #expect(css.contains("--diffs-bg-addition-override: lab("))
        #expect(css.contains("--diffs-line-height: \(HerdrWebTheme.diffLineHeight);"))
        #expect(css.contains("--diffs-token-keyword: #ff8ffd;"))
        #expect(css.contains("--diffs-fg-number-addition-override: #5ee9b5;"))
        // The stylesheet travels inside a JavaScript template literal.
        #expect(!css.contains("`"))
        #expect(!css.contains("${"))
        #expect(!css.contains("\\"))
        // Actual syntax, row colours and line spacing are asserted against the
        // bundled production renderer in PRReviewDiffTextTests.
    }

    @Test("Lab mix targets reproduce the native row colors through Pierre's formula")
    func labTargetsMatchNativeRows() async throws {
        let view = try await themedPage("<body>Synthetic diff host</body>")
        defer { view.stopLoading() }
        let base = HerdrTheme.windowBackground
        let addRow = HerdrWebTheme.over(HerdrTheme.diffAddRow, base)
        let removeRow = HerdrWebTheme.over(HerdrTheme.diffRemoveRow, base)
        let values = try await view.evaluateJavaScript("""
            (() => {
              const toRGB = (color) => {
                const canvas = document.createElement('canvas');
                canvas.width = 1; canvas.height = 1;
                const context = canvas.getContext('2d');
                context.fillStyle = color;
                context.fillRect(0, 0, 1, 1);
                return [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
              };
              const diff = document.createElement('diffs-container');
              document.body.appendChild(diff);
              const shadow = diff.attachShadow({mode: 'open'});
              shadow.innerHTML = '<style>:host { --diffs-bg: var(--herdr-diff-background); '
                + '--diffs-bg-addition-override: rgba(46, 160, 67, 0.30); --diffs-line-height: 1.85; } '
                + '.add { background: color-mix(in lab, var(--diffs-bg) 80%, var(--diffs-bg-addition-override)); '
                + 'line-height: var(--diffs-line-height); font-size: 12px; } '
                + '.del { background: color-mix(in lab, var(--diffs-bg) 80%, var(--diffs-bg-deletion-override)); }</style>'
                + '<p class="add">+ added</p><p class="del">- removed</p>';
              const add = getComputedStyle(shadow.querySelector('.add'));
              const del = getComputedStyle(shadow.querySelector('.del'));
              return [...toRGB(add.backgroundColor), ...toRGB(del.backgroundColor), parseFloat(add.lineHeight)];
            })();
            """) as? [Double]
        let measured = try #require(values)
        try #require(measured.count == 7)
        let expected = rgb(addRow) + rgb(removeRow)
        for index in 0..<6 {
            #expect(abs(measured[index] - expected[index]) <= 3, "channel \(index): \(measured) vs \(expected)")
        }
        #expect(abs(measured[6] - 20) < 0.1, "Mono diff rows are 20px at the 12px code size")
    }

    @Test("Git page rules beat the page's own section and row selectors")
    func restylesGitPage() async throws {
        let view = try await themedPage("""
            <head><style>
            .hz-git-section-staged .hz-git-badge { color: rgb(1, 2, 3); }
            .hz-git-section-heading h2 { font-size: 10.5px; }
            .hz-git-row { min-height: 36px; border-bottom: 1px solid red; }
            .hz-git-row-diffable:hover { background: red; }
            .hz-git-row:hover .hz-git-row-action { background: red; }
            .hz-git-commit-hash { color: rgb(1, 2, 3); }
            </style></head><body>
            <section class="hz-git-section hz-git-section-staged">
              <div class="hz-git-section-heading"><h2>Staged</h2><span>2</span></div>
              <div class="hz-git-file-list">
                <div class="hz-git-row hz-git-row-diffable hz-git-row-selected" id="selected">
                  <button class="hz-git-row-open"><span class="hz-git-badge mono">M</span>
                    <span class="hz-git-file"><span class="hz-git-file-name mono">GardenBed.swift</span></span></button>
                  <button class="hz-git-row-action">Unstage</button>
                </div>
                <div class="hz-git-row hz-git-row-diffable" id="resting">
                  <button class="hz-git-row-open"><span class="hz-git-file"><span class="hz-git-file-name mono">Seeds.swift</span></span></button>
                  <button class="hz-git-row-action">Unstage</button>
                </div>
              </div>
            </section>
            <span class="hz-git-commit-hash mono">111aaaa</span>
            </body>
            """)
        defer { view.stopLoading() }
        let values = try await view.evaluateJavaScript("""
            (() => {
              const style = (selector) => getComputedStyle(document.querySelector(selector));
              return [
                style('.hz-git-badge').color,
                style('.hz-git-section-heading h2').fontSize,
                style('.hz-git-section-heading span').height,
                style('#selected').minHeight,
                style('#selected').borderBottomWidth,
                style('#selected .hz-git-row-action').opacity,
                style('#resting .hz-git-row-action').opacity,
                style('#resting .hz-git-row-action').pointerEvents,
                style('#resting .hz-git-row-action').height,
                style('.hz-git-commit-hash').color,
                style('.hz-git-file-name').fontSize
              ];
            })();
            """) as? [String]
        #expect(values == [
            "rgb(0, 212, 146)", "10px", "16px", "28px", "0px", "1", "0", "none", "28px",
            "rgb(169, 169, 173)", "13px",
        ])
    }

    @Test("Report styling is installed separately from the embedded web theme")
    func installsReportStyle() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(HerdrWebTheme.reportUserScript())
        let view = WKWebView(frame: .zero, configuration: configuration)
        defer { view.stopLoading() }
        view.loadHTMLString("<html><body>Fictional report</body></html>", baseURL: nil)

        var installed = false
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript(
                "!!document.getElementById('herdr-pr-review-report')"
            )) as? Bool == true {
                installed = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(installed)
    }

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
              shadow.innerHTML = '<style>:host { --diffs-bg: var(--herdr-diff-background, #0b0e13); } p { background: var(--diffs-bg); }</style><p>Synthetic diff</p>';
              return [getComputedStyle(document.body).backgroundColor,
                      getComputedStyle(document.body).color,
                      getComputedStyle(shadow.querySelector('p')).backgroundColor];
            })();
            """) as? [String]
        #expect(values == ["rgb(21, 21, 25)", "rgb(233, 233, 236)", "rgb(21, 21, 25)"])

        let fileStyles = try await view.evaluateJavaScript("""
            (() => {
              const row = document.createElement('div');
              row.innerHTML = '<span class="hz-git-file" title="Sources/Garden/WateringSchedule.swift"><span class="hz-git-file-name">WateringSchedule.swift</span><span class="hz-git-file-directory">Sources/Garden</span></span>';
              document.body.appendChild(row);
              const name = getComputedStyle(row.querySelector('.hz-git-file-name'));
              const directory = getComputedStyle(row.querySelector('.hz-git-file-directory'));
              const slash = getComputedStyle(row.querySelector('.hz-git-file-directory'), '::after');
              return [name.flexShrink, name.textOverflow, name.whiteSpace, directory.order, slash.content,
                      row.querySelector('.hz-git-file').title];
            })();
            """) as? [String]
        // MonoCode's order: the name first (13px/500, one line, ellipsized only
        // after the folder has given way), then the folder with no added "/".
        // This replaces the directory-first rule for older companions; the
        // row's title still carries the full path.
        #expect(fileStyles == ["1", "ellipsis", "nowrap", "0", "none", "Sources/Garden/WateringSchedule.swift"])
    }

    // MARK: Helpers

    private func themedPage(_ html: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(HerdrWebTheme.userScript())
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        view.loadHTMLString("<html>\(html)</html>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript(
                "!!document.getElementById('herdr-mac-comfortable-reading')"
            )) as? Bool == true {
                return view
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        view.stopLoading()
        throw CancellationError()
    }

    /// sRGB channels 0...255 of an opaque color.
    private func rgb(_ color: Color) -> [Double] {
        let value = HerdrTheme.resolved(color)
        return [value.redComponent, value.greenComponent, value.blueComponent].map { Double($0) * 255 }
    }
}
