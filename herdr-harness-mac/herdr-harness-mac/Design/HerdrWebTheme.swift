import AppKit
import SwiftUI
import WebKit

/// Presentation scoped to the Mac's embedded Git and Active Work pages.
/// Authentication bootstrap and navigation policy remain owned by each container.
@MainActor
enum HerdrWebTheme {
    static func userScript() -> WKUserScript {
        return WKUserScript(
            source: """
            (() => {
              const style = document.createElement('style');
              style.id = 'herdr-mac-comfortable-reading';
              style.textContent = `\(css)`;
              (document.head || document.documentElement).appendChild(style);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    private static func hex(_ color: Color) -> String {
        let value = NSColor(color).usingColorSpace(.sRGB)!
        return String(
            format: "#%02x%02x%02x",
            Int((value.redComponent * 255).rounded()),
            Int((value.greenComponent * 255).rounded()),
            Int((value.blueComponent * 255).rounded())
        )
    }

    static var css: String {
        """
        :root, :root[data-theme] {
          color-scheme: dark;
          --bg: \(hex(HerdrTheme.graphite));
          --bg-sidebar-top: \(hex(HerdrTheme.ink));
          --bg-sidebar-bottom: \(hex(HerdrTheme.ink));
          --bg-detail-top: \(hex(HerdrTheme.graphite));
          --bg-detail-bottom: \(hex(HerdrTheme.graphite));
          --panel: \(hex(HerdrTheme.elevated));
          --panel-strong: \(hex(HerdrTheme.input));
          --surface: \(hex(HerdrTheme.elevated));
          --raised: \(hex(HerdrTheme.input));
          --hover: \(hex(HerdrTheme.selection));
          --line: \(hex(HerdrTheme.separator));
          --line-strong: \(hex(HerdrTheme.surface));
          --text: \(hex(HerdrTheme.text));
          --soft: \(hex(HerdrTheme.mist));
          --muted: \(hex(HerdrTheme.mist));
          --muted-dim: \(hex(HerdrTheme.muted));
          --dim: \(hex(HerdrTheme.mist));
          --faint: \(hex(HerdrTheme.muted));
          --accent: \(hex(HerdrTheme.accent));
          --accent-bg: \(hex(HerdrTheme.selection));
          --green: \(hex(HerdrTheme.success));
          --success: \(hex(HerdrTheme.success));
          --orange: \(hex(HerdrTheme.working));
          --red: \(hex(HerdrTheme.alert));
          --danger: \(hex(HerdrTheme.alert));
          --complete-text: \(hex(HerdrTheme.signal));
          --complete-bg: rgb(156 205 185 / 0.12);
          --working-border: rgb(156 205 185 / 0.24);
          --working-bg: rgb(156 205 185 / 0.08);
          --watch-ring: rgb(156 205 185 / 0.16);
          --region: rgb(41 43 57 / 0.5);
          --minimap-bg: \(hex(HerdrTheme.elevated));
          --overlay: \(hex(HerdrTheme.elevated));
          --grid: \(hex(HerdrTheme.separator));
          --gate-pink: \(hex(HerdrTheme.mauve));
          --font: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          --radius: 12px;
        }
        .hz-git-workbench, .hz-diff-inspector { background: var(--bg); }
        .hz-git-navigator { background: var(--bg-sidebar-top); }
        .hz-git-row-selected, .hz-diff-segment .hz-diff-control-active,
        .hz-diff-wrap.hz-diff-control-active,
        .hz-git-context-menu button:hover, .hz-git-context-menu button:focus-visible {
          background: var(--accent-bg); color: var(--text);
        }
        .hz-git-repo-mark { background: var(--accent-bg); border-color: var(--line); }
        .hz-git-eyebrow, .hz-diff-eyebrow {
          font-family: var(--font); font-size: 11px;
          font-weight: 500; letter-spacing: normal; text-transform: none;
        }
        :root .act-bubble, :root .act-bubble::after, :root .act-chip {
          background: var(--raised); color: var(--text); border-color: var(--line);
        }
        /* These public host variables cross the diff renderer's shadow boundary. */
        diffs-container {
          --diffs-bg: \(hex(HerdrTheme.graphite));
          --diffs-bg-context: \(hex(HerdrTheme.graphite));
          --diffs-bg-context-gutter: \(hex(HerdrTheme.ink));
          --diffs-fg: \(hex(HerdrTheme.text));
          --diffs-fg-number: \(hex(HerdrTheme.muted));
          --diffs-bg-separator: \(hex(HerdrTheme.selection));
          --diffs-bg-addition-override: rgb(131 188 145 / 0.16);
          --diffs-bg-addition-number-override: rgb(131 188 145 / 0.22);
          --diffs-bg-addition-emphasis-override: rgb(131 188 145 / 0.32);
          --diffs-bg-deletion-override: rgb(217 151 162 / 0.16);
          --diffs-bg-deletion-number-override: rgb(217 151 162 / 0.22);
          --diffs-bg-deletion-emphasis-override: rgb(217 151 162 / 0.32);
          --diffs-bg-hover-override: \(hex(HerdrTheme.elevated));
          --diffs-bg-selection-override: \(hex(HerdrTheme.selection));
          --diffs-bg-selection-number-override: \(hex(HerdrTheme.selection));
          --diffs-font-size: 12px;
          --diffs-line-height: 1.65;
        }
        """
    }
}
