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

    /// Local reports need a small document stylesheet because they do not use
    /// the embedded web app's class names, while keeping the existing theme script stable.
    static func reportUserScript() -> WKUserScript {
        WKUserScript(
            source: """
            (() => {
              const existing = document.getElementById('herdr-pr-review-report');
              if (existing) existing.remove();
              const style = document.createElement('style');
              style.id = 'herdr-pr-review-report';
              style.textContent = [
                'body { background: var(--bg); color: var(--text); font-family: var(--font);',
                'max-width: 980px; margin: 0 auto; padding: 24px; }',
                'a { color: var(--accent); }',
                'pre, code { background: var(--panel); }',
                'table { border-color: var(--line); }'
              ].join('');
              (document.head || document.documentElement).appendChild(style);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
    }

    /// `#rrggbb` for opaque tokens, `rgb(r g b / a)` for Mono's translucent fills and lines.
    private static func hex(_ color: Color) -> String {
        let value = NSColor(color).usingColorSpace(.sRGB)!
        let red = Int((value.redComponent * 255).rounded())
        let green = Int((value.greenComponent * 255).rounded())
        let blue = Int((value.blueComponent * 255).rounded())
        if value.alphaComponent < 0.999 {
            return String(format: "rgb(%d %d %d / %.3f)", red, green, blue, value.alphaComponent)
        }
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    static var css: String {
        """
        :root, :root[data-theme] {
          color-scheme: dark;
          --bg: \(hex(HerdrTheme.windowBackground));
          --bg-sidebar-top: \(hex(HerdrTheme.railBackground));
          --bg-sidebar-bottom: \(hex(HerdrTheme.railBackground));
          --bg-detail-top: \(hex(HerdrTheme.windowBackground));
          --bg-detail-bottom: \(hex(HerdrTheme.windowBackground));
          --panel: \(hex(HerdrTheme.elevated));
          --panel-strong: \(hex(HerdrTheme.input));
          --surface: \(hex(HerdrTheme.elevated));
          --raised: \(hex(HerdrTheme.surface));
          --hover: \(hex(HerdrTheme.hoverFill));
          --line: \(hex(HerdrTheme.hairline));
          --line-strong: \(hex(HerdrTheme.outline));
          --text: \(hex(HerdrTheme.primaryText));
          --soft: \(hex(HerdrTheme.proseText));
          --muted: \(hex(HerdrTheme.secondaryText));
          --muted-dim: \(hex(HerdrTheme.tertiaryText));
          --dim: \(hex(HerdrTheme.secondaryText));
          --faint: \(hex(HerdrTheme.tertiaryText));
          --accent: \(hex(HerdrTheme.accent));
          --accent-bg: \(hex(HerdrTheme.selectedFill));
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
          --region: \(hex(HerdrTheme.cardFill));
          --minimap-bg: \(hex(HerdrTheme.elevated));
          --overlay: \(hex(HerdrTheme.elevated));
          --grid: \(hex(HerdrTheme.hairline));
          --gate-pink: \(hex(HerdrTheme.folder));
          --font: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          --radius: 12px;
          /* Mono × Herdr tokens for pages that adopt them directly. */
          --mono-base: \(hex(HerdrTheme.base));
          --mono-ink: \(hex(HerdrTheme.foreground));
          --mono-rail: \(hex(HerdrTheme.railBackground));
          --mono-card: \(hex(HerdrTheme.cardFill));
          --mono-field: \(hex(HerdrTheme.fieldFill));
          --mono-inset: \(hex(HerdrTheme.insetFill));
          --mono-chip: \(hex(HerdrTheme.chipFill));
          --mono-selected: \(hex(HerdrTheme.selectedFill));
          --mono-hairline: \(hex(HerdrTheme.hairline));
          --mono-outline: \(hex(HerdrTheme.outline));
          --mono-row-divider: \(hex(HerdrTheme.rowDivider));
          --mono-prose: \(hex(HerdrTheme.proseText));
          --mono-secondary: \(hex(HerdrTheme.secondaryText));
          --mono-tertiary: \(hex(HerdrTheme.tertiaryText));
          --mono-icon: \(hex(HerdrTheme.iconTint));
          --mono-primary: \(hex(HerdrTheme.primaryAction));
          --mono-on-primary: \(hex(HerdrTheme.onPrimary));
          --mono-diff-add-row: \(hex(HerdrTheme.diffAddRow));
          --mono-diff-add-gutter: \(hex(HerdrTheme.diffAddGutter));
          --mono-diff-add-number: \(hex(HerdrTheme.diffAddNumber));
          --mono-diff-remove-row: \(hex(HerdrTheme.diffRemoveRow));
          --mono-diff-remove-gutter: \(hex(HerdrTheme.diffRemoveGutter));
          --mono-diff-remove-number: \(hex(HerdrTheme.diffRemoveNumber));
          --mono-diff-add: \(hex(HerdrTheme.diffAdd));
          --mono-diff-remove: \(hex(HerdrTheme.diffRemove));
          --mono-diff-modified: \(hex(HerdrTheme.diffModified));
          --mono-diff-untracked: \(hex(HerdrTheme.diffUntracked));
          --mono-syntax-keyword: \(hex(HerdrTheme.Syntax.keyword));
          --mono-syntax-callable: \(hex(HerdrTheme.Syntax.callable));
          --mono-syntax-string: \(hex(HerdrTheme.Syntax.string));
          --mono-syntax-type: \(hex(HerdrTheme.Syntax.type));
          --mono-syntax-comment: \(hex(HerdrTheme.Syntax.comment));
          --mono-syntax-property: \(hex(HerdrTheme.Syntax.property));
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
        /* Keep older companions' file rows readable without a server update. */
        .hz-git-file { gap: 0; }
        .hz-git-file-name {
          flex: 0 0 auto; max-width: 100%; white-space: normal;
          overflow-wrap: anywhere; overflow: visible; text-overflow: clip;
        }
        .hz-git-file-directory {
          order: -1; flex: 0 1 auto; max-width: 35%; font-size: inherit;
          position: relative; padding-right: 0.6em;
        }
        .hz-git-file-directory::after {
          content: "/"; position: absolute; right: 0; bottom: 0; direction: ltr;
        }
        .hz-diff-title { direction: rtl; text-align: left; }
        /* Host surfaces cross Pierre's shadow boundary; the shared renderer owns all styling. */
        diffs-container {
          --herdr-diff-background: \(hex(HerdrTheme.graphite));
          --herdr-diff-gutter-background: \(hex(HerdrTheme.ink));
          --herdr-diff-foreground: \(hex(HerdrTheme.text));
          --herdr-diff-muted: \(hex(HerdrTheme.muted));
          --herdr-diff-separator: \(hex(HerdrTheme.selection));
          --herdr-diff-hover: \(hex(HerdrTheme.elevated));
          --herdr-diff-selection: \(hex(HerdrTheme.selection));
          --herdr-diff-selection-number: \(hex(HerdrTheme.selection));
        }
        """
    }
}
