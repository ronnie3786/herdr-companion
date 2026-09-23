import { useMemo, type CSSProperties } from "react";
import { registerCustomCSSVariableTheme } from "@pierre/diffs";
import { FileDiff as PierreFileDiff } from "@pierre/diffs/react";
import type { SelectedLineRange } from "@pierre/diffs";
import { parseDiffPresentation } from "./diffPresentation";

export type SharedDiffStyle = "unified" | "split";
export type SharedDiffOverflow = "scroll" | "wrap";

const HERDR_DIFF_THEME = "herdr-dark";

registerCustomCSSVariableTheme(HERDR_DIFF_THEME, {
  foreground: "#e8eaed",
  background: "#0b0e13",
  "token-comment": "#7d8590",
  "token-string": "#a5d6ff",
  "token-constant": "#79c0ff",
  "token-keyword": "#ff7b72",
  "token-parameter": "#e8eaed",
  "token-function": "#d2a8ff",
  "token-string-expression": "#7ee787",
  "token-punctuation": "#8b949e",
  "token-link": "#58a6ff",
  "ansi-black": "#484f58",
  "ansi-red": "#ff7b72",
  "ansi-green": "#7ee787",
  "ansi-yellow": "#e3b341",
  "ansi-blue": "#79c0ff",
  "ansi-magenta": "#d2a8ff",
  "ansi-cyan": "#56d4dd",
  "ansi-white": "#e8eaed",
});

/**
 * One renderer stylesheet for browser Git, First Mate Git, and the Mac PR
 * Review bridge. Hosts may supply only the public surface variables below;
 * syntax, spacing, change treatment, and interaction styling stay shared.
 */
export const HERDR_DIFF_THEME_OVERRIDES = `
  :host {
    --diffs-font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    --diffs-header-font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    --diffs-font-size: calc(12px * var(--herdr-diff-font-scale, 1));
    --diffs-line-height: 1.85;
    --diffs-bg: var(--herdr-diff-background, #0b0e13);
    --diffs-bg-context: var(--herdr-diff-background, #0b0e13);
    --diffs-bg-context-gutter: var(--herdr-diff-gutter-background, #0d1117);
    --diffs-fg: var(--herdr-diff-foreground, #e8eaed);
    --diffs-fg-number: var(--herdr-diff-muted, #7d8590);
    --diffs-bg-separator: var(--herdr-diff-separator, rgba(56, 139, 253, 0.15));
    --diffs-bg-addition-override: rgba(46, 160, 67, 0.30);
    --diffs-bg-addition-number-override: rgba(46, 160, 67, 0.42);
    --diffs-bg-addition-emphasis-override: rgba(46, 160, 67, 0.55);
    --diffs-bg-deletion-override: rgba(248, 81, 73, 0.30);
    --diffs-bg-deletion-number-override: rgba(248, 81, 73, 0.42);
    --diffs-bg-deletion-emphasis-override: rgba(248, 81, 73, 0.55);
    --diffs-bg-hover-override: var(--herdr-diff-hover, rgba(47, 129, 247, 0.09));
    --diffs-bg-selection-override: var(--herdr-diff-selection, rgba(47, 129, 247, 0.18));
    --diffs-bg-selection-number-override: var(--herdr-diff-selection-number, rgba(47, 129, 247, 0.28));
  }
`;

interface SharedDiffRendererProps {
  file: string;
  patch: string;
  diffStyle?: SharedDiffStyle;
  overflow?: SharedDiffOverflow;
  fontScale?: number;
  selectedLines?: SelectedLineRange | null;
  disableWorkerPool?: boolean;
  className?: string;
  onRendered?: (node: HTMLElement) => void;
}

export function SharedDiffRenderer({
  file,
  patch,
  diffStyle = "unified",
  overflow = "scroll",
  fontScale = 1,
  selectedLines = null,
  disableWorkerPool = false,
  className,
  onRendered,
}: SharedDiffRendererProps) {
  const parsed = useMemo(() => parseDiffPresentation(file, patch), [file, patch]);
  const style = { "--herdr-diff-font-scale": fontScale } as CSSProperties;

  if (parsed.fileDiff === null) {
    return (
      <div className={`hz-diff-plain-fallback${className ? ` ${className}` : ""}`} style={style}>
        <span>
          {parsed.fallbackReason === "metadata-only"
            ? "This change contains Git metadata rather than line-by-line text. Showing the raw patch."
            : "Syntax rendering was unavailable for this patch. Showing the raw diff."}
        </span>
        <pre>{patch}</pre>
      </div>
    );
  }

  return (
    <PierreFileDiff
      key={parsed.fileDiff.cacheKey}
      className={className}
      style={style}
      fileDiff={parsed.fileDiff}
      selectedLines={selectedLines}
      disableWorkerPool={disableWorkerPool}
      options={{
        themeType: "dark",
        theme: { dark: HERDR_DIFF_THEME, light: HERDR_DIFF_THEME },
        unsafeCSS: HERDR_DIFF_THEME_OVERRIDES,
        disableFileHeader: true,
        diffStyle,
        overflow,
        diffIndicators: "bars",
        lineDiffType: "word-alt",
        hunkSeparators: "line-info",
        lineHoverHighlight: "both",
        onPostRender: onRendered,
      }}
    />
  );
}
