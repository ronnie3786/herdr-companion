# First Mate overview Markdown

First Mate keeps generated prose readable as Markdown while leaving compact UI
identifiers as literal text. The Mac reuses its native Markdown parser and
SwiftUI renderer; these surfaces do not execute HTML or load remote content to
render prose.

## Audited Mac surfaces

| Surface | Content | Presentation |
| --- | --- | --- |
| First Mate → Overview | Complete feature goal | Compact block Markdown: headings, paragraphs, emphasis, links, lists, quotes, code, tables, and rules. Empty goals keep an explicit empty state. |
| First Mate → Overview | Latest journal summaries | Compact block Markdown. |
| First Mate → Documents | `text/markdown` document body | Already rendered with the full First Mate Markdown document view. A declared non-Markdown body remains literal text. Document titles, authors, visit names, media types, and provenance remain structural labels. |
| First Mate → Agents | Saved assistant-session prose | Already rendered with the shared full Markdown message view. Agent titles, roles, status, usage, and machine verdict identifiers remain structural labels. User prompts keep their existing inline presentation. |
| First Mate → Workflow | Worker progress summary, next action, evidence, and recovery event summaries | Compact block Markdown. Labels such as **Next** and **Worker-reported evidence** remain separate from the untrusted source. Visit names, revision/status labels, commit subjects, paths, hashes, and timestamps remain structural text. |
| First Mate chat and saved assistant replies | Assistant prose | Already rendered as Markdown. Chat-bubble feedback controls and standalone window/sidebar layout are outside this presentation change. |

Titles and machine-generated identifiers intentionally do not interpret Markdown.
Rendering punctuation in those fields would reduce scanability and could make a
literal identifier look like prose or a link.

## Shared links ornament

The prominent pull-request/shared-link section uses a neutral icon, quiet count,
and ordinary card separation. It has no accent-colored leading bar or decorative
purple ornament. Link destinations and Open/Copy validation are unchanged.

## Verification

Focused tests cover the retained Markdown block model and host the production
Overview goal and Workflow progress views in light and dark appearances at the
largest supported First Mate text scale. The existing Markdown parser, cache,
inline-code, streaming, and First Mate prose tests continue to cover the shared
renderer.
