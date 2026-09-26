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
        :root .act-bubble, :root .act-bubble::after, :root .act-chip {
          background: var(--raised); color: var(--text); border-color: var(--line);
        }
        \(gitPageCSS)
        \(diffCSS)
        """
    }

    // MARK: Git page (GitStatusView and DiffSheet)

    /// MonoCode's source-control panel for the companion's Git page. The page
    /// stylesheet loads first, so equal specificity already wins; `:root`
    /// prefixes beat its two-class section rules. Status letters keep the
    /// page's section semantics (staged / unstaged) because CSS cannot read
    /// the letter itself.
    private static var gitPageCSS: String {
        """
        .hz-git-workbench, .hz-diff-inspector { background: var(--bg); }
        :root .hz-git-navigator { background: var(--bg); }
        :root .hz-git-divider::after { width: 1px; }
        :root .hz-git-header { background: transparent; border-bottom: 1px solid var(--mono-hairline); }
        :root .hz-git-header-main { min-height: 36px; padding: 0 6px 0 12px; gap: 8px; }
        :root .hz-git-repo-mark {
          width: 16px; height: 16px; border: 0; border-radius: 0; background: transparent; color: var(--mono-icon);
        }
        :root .hz-git-repo-mark svg { width: 14px; height: 14px; }
        :root .hz-git-repo-copy { gap: 0; }
        :root .hz-git-eyebrow { display: none; }
        :root .hz-git-identity { gap: 8px; }
        :root .hz-git-repo-name { color: var(--text); font: 600 13px var(--font); }
        :root .hz-git-branch {
          padding: 0; border: 0; border-radius: 0; color: var(--mono-secondary); font: 500 12px \(monoFont);
        }
        :root .hz-git-refresh {
          width: 28px; min-height: 28px; height: 28px; padding: 1px; border: 0; border-radius: 7px;
          background: transparent; background-clip: content-box; color: var(--mono-icon);
        }
        :root .hz-git-refresh:hover, :root .hz-git-refresh:focus-visible {
          background-color: var(--mono-selected); color: var(--text);
        }
        :root .hz-git-header .hz-git-header-meta {
          min-height: 0; gap: 8px; padding: 8px 12px; border-top: 1px solid var(--mono-hairline); background: transparent;
        }
        :root .hz-git-changed { padding-left: 0; font: 500 11px var(--font); }
        :root .hz-git-changed::before { display: none; }
        :root .hz-git-path { color: var(--mono-tertiary); font-size: 11px; }
        :root .hz-git-navigator-scroll { padding: 4px 0 16px; }
        :root .hz-git-change-stack { gap: 0; }
        :root .hz-git-section-heading, :root .hz-git-history-heading {
          min-height: 28px; margin-top: 4px; padding: 0 12px; gap: 6px;
        }
        :root .hz-git-section-heading h2, :root .hz-git-history-heading h2 {
          color: var(--mono-tertiary); font: 600 10px var(--font); letter-spacing: 0.04em;
        }
        :root .hz-git-section-heading span {
          min-width: 16px; height: 16px; padding: 0 4px; border-radius: 8px;
          background: \(hex(HerdrTheme.badgeFill)); color: \(hex(HerdrTheme.onBadge));
          font: 600 9px/16px var(--font); text-align: center;
        }
        :root .hz-git-file-list { border: 0; border-radius: 0; background: transparent; }
        :root .hz-git-row { min-height: 28px; gap: 0; padding: 0 8px 0 0; border-bottom: 0; }
        :root .hz-git-row-diffable:hover { background: var(--mono-inset); }
        :root .hz-git-row.hz-git-row-selected { background: var(--mono-selected); }
        :root .hz-git-row-open { min-height: 28px; gap: 6px; padding: 0 0 0 10px; }
        :root .hz-git-row-open:focus-visible { background: var(--mono-inset); }
        :root .hz-git-row .hz-git-badge {
          order: 1; width: 14px; font: 600 11px \(monoFont); text-align: right;
        }
        :root .hz-git-section-staged .hz-git-badge { color: \(hex(HerdrTheme.diffAdd)); }
        :root .hz-git-section-unstaged .hz-git-badge { color: \(hex(HerdrTheme.diffModified)); }
        :root .hz-git-section-untracked .hz-git-badge { color: \(hex(HerdrTheme.diffUntracked)); }
        /* MonoCode's file row: the name (13px/500), then its folder (11px tertiary).
           The folder gives way first; the row's title keeps the full path. */
        :root .hz-git-file { gap: 6px; align-items: baseline; font: 500 13px var(--font); }
        :root .hz-git-file .hz-git-file-name {
          flex: 0 1 auto; min-width: 0; max-width: none; overflow: hidden; text-overflow: ellipsis;
          white-space: nowrap; overflow-wrap: normal; color: var(--text); font: 500 13px var(--font);
        }
        :root .hz-git-file .hz-git-file-directory {
          order: 0; flex: 0 10000 auto; min-width: 0; max-width: none; padding-right: 0; overflow: hidden;
          direction: ltr; text-overflow: ellipsis; white-space: nowrap;
          color: var(--mono-tertiary); font: 400 11px var(--font);
        }
        :root .hz-git-file .hz-git-file-directory::after { content: none; }
        /* Stage and Unstage: a ghost button over the row's tail, shown on hover,
           selection or keyboard focus. The file text gives way to it first. */
        :root .hz-git-row .hz-git-row-action {
          position: absolute; top: 50%; right: 28px; transform: translateY(-50%);
          height: 28px; min-height: 28px; padding: 0 8px; border: 0; border-radius: 6px;
          background: \(hex(HerdrTheme.inkSolid(0.05))); color: var(--mono-secondary); font: 500 12px var(--font);
          opacity: 0; pointer-events: none;
        }
        :root .hz-git-row.hz-git-row-selected .hz-git-row-action { background: \(hex(HerdrTheme.inkSolid(0.10))); }
        :root .hz-git-row:hover .hz-git-row-action, :root .hz-git-row.hz-git-row-selected .hz-git-row-action,
        :root .hz-git-row .hz-git-row-action:focus-visible {
          opacity: 1; pointer-events: auto; border-color: transparent;
        }
        :root .hz-git-row:hover .hz-git-file, :root .hz-git-row.hz-git-row-selected .hz-git-file,
        :root .hz-git-row:focus-within .hz-git-file {
          margin-right: 72px;
        }
        :root .hz-git-row .hz-git-row-action:hover, :root .hz-git-row .hz-git-row-action:focus-visible {
          background: \(hex(HerdrTheme.inkSolid(0.15))); color: var(--text);
        }
        :root .hz-git-history { margin-top: 4px; padding-top: 0; border-top: 0; }
        :root .hz-git-history-heading > div { gap: 6px; color: var(--mono-icon); }
        :root .hz-git-history-heading > span { color: var(--mono-tertiary); font-size: 11px; }
        :root .hz-git-commits { border: 0; border-radius: 0; }
        :root .hz-git-commit { border-bottom: 0; }
        :root .hz-git-commit-row { min-height: 28px; gap: 10px; padding: 0 12px 0 16px; }
        :root .hz-git-commit-row:hover, :root .hz-git-commit-expanded > .hz-git-commit-row {
          background: var(--mono-inset); color: var(--text);
        }
        :root .hz-git-commit-hash { color: var(--mono-tertiary); font-size: 11px; }
        :root .hz-git-commit-message { color: var(--text); font-size: 13px; }
        :root .hz-git-commit-files, :root .hz-git-commit-state { background: transparent; }
        :root .hz-git-commit-file { min-height: 28px; }
        :root .hz-git-commit-file:hover { background: var(--mono-inset); }
        :root .hz-git-clean-state {
          margin: 8px 12px; border: 1px solid var(--mono-outline); border-radius: 12px; background: var(--mono-card);
        }
        :root .hz-git-clean-pulse { box-shadow: none; }
        :root .hz-git-refresh-warning {
          margin: 8px 12px; border: 1px solid \(hex(HerdrTheme.working.opacity(0.22)));
          border-radius: 6px; background: \(hex(HerdrTheme.working.opacity(0.08))); font-size: 12px;
        }
        :root .hz-git-context-menu {
          padding: 4px; border: 1px solid var(--mono-outline); border-radius: 12px; background: var(--bg);
        }
        :root .hz-git-context-menu button { min-height: 28px; border-radius: 6px; font-size: 12px; }
        :root .hz-git-context-menu button:hover, :root .hz-git-context-menu button:focus-visible {
          background: var(--mono-selected); color: var(--text);
        }
        :root .hz-git-context-menu svg { color: var(--mono-icon); }
        :root .hz-diff-header {
          min-height: 32px; gap: 12px; padding: 0 6px 0 12px;
          border-bottom: 1px solid var(--mono-hairline); background: transparent;
        }
        :root .hz-diff-heading { display: flex; align-items: baseline; gap: 8px; }
        :root .hz-diff-eyebrow {
          color: var(--mono-secondary); font: 400 12px var(--font); letter-spacing: normal; text-transform: none;
        }
        :root .hz-diff-eyebrow::first-letter { text-transform: uppercase; }
        :root .hz-diff-title {
          direction: rtl; text-align: left; color: \(hex(HerdrTheme.inkSolid(0.85))); font: 400 12px \(monoFont);
        }
        :root .hz-diff-segment { gap: 1px; border: 0; background: transparent; }
        :root .hz-diff-segment button, :root .hz-diff-wrap {
          height: 28px; min-height: 28px; padding: 0 8px; border: 0; border-radius: 6px;
          background: transparent; color: var(--mono-tertiary); font: 400 12px var(--font);
        }
        :root .hz-diff-segment button + button { border-left: 0; }
        :root .hz-diff-segment button:hover, :root .hz-diff-wrap:hover { background: var(--mono-inset); color: var(--text); }
        :root .hz-diff-segment .hz-diff-control-active, :root .hz-diff-wrap.hz-diff-control-active {
          background: var(--mono-selected); color: var(--text);
        }
        :root .hz-diff-truncated-warning {
          border-bottom: 1px solid \(hex(HerdrTheme.warning.opacity(0.22)));
          background: \(hex(HerdrTheme.warning.opacity(0.08))); color: \(hex(HerdrTheme.warning));
        }
        :root .hz-inline-ask-launcher {
          border-color: \(hex(HerdrTheme.accent.opacity(0.42))); background: var(--bg); color: var(--accent);
        }
        :root .hz-inline-ask-launcher:hover { border-color: var(--accent); color: var(--text); }
        """
    }

    // MARK: Diff renderer (Pierre, shared by the Git page and PR Review)

    /// The unified diff in MonoCode's colors, from the same tokens as the
    /// native `WorkspaceGitView`.
    ///
    /// `--herdr-diff-*` are the shared renderer's public surfaces; the bundled
    /// PR Review document declares them on its own `:root`, so they are set on
    /// `:root` here. Declarations on the `diffs-container` element itself beat
    /// the renderer's `:host` block (outer context wins for normal
    /// declarations), which reaches the row colors, line height, gutter
    /// width and Shiki's `--diffs-token-*` slots.
    ///
    /// Pierre mixes each row as `color-mix(in lab, bg 80%, target)` and each
    /// number cell as `bg 85%`, inside the shadow tree. The row targets below
    /// are solved in Lab so a mixed row equals the native row exactly; number
    /// cells are held to the in-range part of the same solution (about 60% of
    /// the native gutter tint). Not reachable from the host: the 22px hunk bar
    /// (Pierre's line-info bar is 32px) and 11px line numbers.
    private static var diffCSS: String {
        let base = HerdrTheme.windowBackground
        let addRow = over(HerdrTheme.diffAddRow, base)
        let removeRow = over(HerdrTheme.diffRemoveRow, base)
        let addGutter = over(HerdrTheme.diffAddGutter, addRow)
        let removeGutter = over(HerdrTheme.diffRemoveGutter, removeRow)
        return """
        :root {
          --herdr-diff-background: \(hex(base));
          --herdr-diff-gutter-background: \(hex(base));
          --herdr-diff-foreground: \(hex(HerdrTheme.inkSolid(0.80)));
          --herdr-diff-muted: \(hex(HerdrTheme.tertiaryText));
          --herdr-diff-separator: \(hex(HerdrTheme.inkSolid(0.08)));
          --herdr-diff-hover: \(hex(HerdrTheme.inkSolid(0.55)));
          --herdr-diff-selection: \(hex(over(HerdrTheme.accent.opacity(0.50), base)));
          --herdr-diff-selection-number: \(hex(over(HerdrTheme.accent.opacity(0.60), base)));
        }
        diffs-container {
          --diffs-line-height: \(diffLineHeight);
          --diffs-header-font-family: \(monoFont);
          --diffs-min-number-column-width: 3.5ch;
          --diffs-bg-addition-override: \(labMixTarget(result: addRow, base: base, basePercent: 0.80));
          --diffs-bg-deletion-override: \(labMixTarget(result: removeRow, base: base, basePercent: 0.80));
          --diffs-bg-addition-number-override: \(labMixTarget(result: addGutter, base: base, basePercent: 0.85));
          --diffs-bg-deletion-number-override: \(labMixTarget(result: removeGutter, base: base, basePercent: 0.85));
          --diffs-bg-addition-emphasis-override: \(hex(opaque(HerdrTheme.diffAddRow).opacity(0.30)));
          --diffs-bg-deletion-emphasis-override: \(hex(opaque(HerdrTheme.diffRemoveRow).opacity(0.30)));
          --diffs-fg-number-addition-override: \(hex(HerdrTheme.diffAddNumber));
          --diffs-fg-number-deletion-override: \(hex(HerdrTheme.diffRemoveNumber));
          --diffs-addition-color-override: \(hex(opaque(HerdrTheme.diffAddRow)));
          --diffs-deletion-color-override: \(hex(opaque(HerdrTheme.diffRemoveRow)));
          --diffs-modified-color-override: \(hex(HerdrTheme.diffModified));
          --diffs-foreground: \(hex(HerdrTheme.inkSolid(0.80)));
          --diffs-token-keyword: \(hex(HerdrTheme.Syntax.keyword));
          --diffs-token-function: \(hex(HerdrTheme.Syntax.callable));
          --diffs-token-string: \(hex(HerdrTheme.Syntax.string));
          --diffs-token-string-expression: \(hex(HerdrTheme.Syntax.string));
          --diffs-token-comment: \(hex(HerdrTheme.Syntax.comment));
          --diffs-token-constant: \(hex(HerdrTheme.Syntax.property));
          --diffs-token-parameter: \(hex(HerdrTheme.inkSolid(0.80)));
          --diffs-token-punctuation: \(hex(HerdrTheme.secondaryText));
          --diffs-token-link: \(hex(HerdrTheme.accent));
        }
        :root .native-ask, :root .native-comment {
          height: 28px; padding: 0 10px; border: 1px solid var(--mono-outline); border-radius: 6px;
          background: var(--bg); color: var(--mono-secondary); font: 500 12px/26px var(--font);
        }
        :root .native-ask:hover, :root .native-comment:hover {
          background: \(hex(HerdrTheme.inkSolid(0.08))); color: var(--text);
        }
        :root .native-ask:focus-visible, :root .native-comment:focus-visible {
          outline: 2px solid var(--accent); outline-offset: 2px;
        }
        :root .native-ask span { color: var(--accent); }
        :root .native-comment span { color: \(hex(HerdrTheme.diffAdd)); }
        """
    }

    /// 20px rows at the renderer's 12px code size.
    static let diffLineHeight = "1.667"
    private static let monoFont = "ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, monospace"

    // MARK: Color math

    private typealias RGB = (red: Double, green: Double, blue: Double)

    /// sRGB channels (0...255) and alpha.
    private static func components(_ color: Color) -> (rgb: RGB, alpha: Double) {
        let value = NSColor(color).usingColorSpace(.sRGB)!
        return (
            (Double(value.redComponent) * 255, Double(value.greenComponent) * 255, Double(value.blueComponent) * 255),
            Double(value.alphaComponent)
        )
    }

    private static func opaque(_ color: Color) -> Color {
        let rgb = components(color).rgb
        return Color(.sRGB, red: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, opacity: 1)
    }

    /// A translucent `top` composited over an opaque `bottom`, rounded to whole channels.
    static func over(_ top: Color, _ bottom: Color) -> Color {
        let (upper, alpha) = components(top)
        let lower = components(bottom).rgb
        func channel(_ a: Double, _ b: Double) -> Double { ((a * alpha + b * (1 - alpha))).rounded() / 255 }
        return Color(
            .sRGB,
            red: channel(upper.red, lower.red),
            green: channel(upper.green, lower.green),
            blue: channel(upper.blue, lower.blue),
            opacity: 1
        )
    }

    /// The CSS `lab()` color T for which `color-mix(in lab, base p, T)` equals
    /// `result`. Lightness is limited to 0–100 (CSS clamps it), so a target
    /// past that is pulled toward `base` along the same line: the mix keeps
    /// the hue and lands as close to `result` as the formula allows.
    static func labMixTarget(result: Color, base: Color, basePercent: Double) -> String {
        let target = lab(components(result).rgb)
        let origin = lab(components(base).rgb)
        var reach = 1 / (1 - basePercent)
        let lightness = origin.l + reach * (target.l - origin.l)
        if lightness > 100, target.l != origin.l {
            reach = (100 - origin.l) / (target.l - origin.l)
        } else if lightness < 0, target.l != origin.l {
            reach = (0 - origin.l) / (target.l - origin.l)
        }
        func value(_ start: Double, _ end: Double) -> String {
            String(format: "%.2f", start + reach * (end - start))
        }
        return "lab(\(value(origin.l, target.l)) \(value(origin.a, target.a)) \(value(origin.b, target.b)))"
    }

    /// sRGB (0...255) to CIE Lab (D50), as CSS Color 4 defines `lab()`.
    private static func lab(_ rgb: RGB) -> (l: Double, a: Double, b: Double) {
        func linear(_ channel: Double) -> Double {
            let value = channel / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(rgb.red), g = linear(rgb.green), b = linear(rgb.blue)
        // Linear sRGB to XYZ (D65), then Bradford-adapted to D50.
        let x65 = 0.41239079926595950 * r + 0.35758433938387796 * g + 0.18048078840183430 * b
        let y65 = 0.21263900587151036 * r + 0.71516867876775590 * g + 0.07219231536073371 * b
        let z65 = 0.01933081871559185 * r + 0.11919477979462599 * g + 0.95053215224966060 * b
        let x = 1.0479298208405488 * x65 + 0.022946793341019088 * y65 - 0.05019222954313557 * z65
        let y = 0.029627815688159344 * x65 + 0.990434484573249 * y65 - 0.01707382502938514 * z65
        let z = -0.009243058152591178 * x65 + 0.015055144896577895 * y65 + 0.7518742899580008 * z65
        let white = (x: 0.3457 / 0.3585, y: 1.0, z: (1 - 0.3457 - 0.3585) / 0.3585)
        let epsilon = 216.0 / 24389.0, kappa = 24389.0 / 27.0
        func f(_ value: Double) -> Double {
            value > epsilon ? cbrt(value) : (kappa * value + 16) / 116
        }
        let fx = f(x / white.x), fy = f(y / white.y), fz = f(z / white.z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
