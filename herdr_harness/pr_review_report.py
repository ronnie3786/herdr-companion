"""Readable standalone reports from escaped Markdown and ledger-owned links."""
from __future__ import annotations

import html
import re


def _inline(text: str) -> str:
    """A small formatting subset, deliberately without HTML or authored links."""
    parts, cursor = [], 0
    for match in re.finditer(r"`[^`\n]+`|\*\*[^*\n]+\*\*", text):
        parts.append(html.escape(text[cursor:match.start()]))
        token = match[0]
        if token.startswith("`"):
            parts.append("<code>" + html.escape(token[1:-1]) + "</code>")
        else:
            parts.append("<strong>" + html.escape(token[2:-2]) + "</strong>")
        cursor = match.end()
    parts.append(html.escape(text[cursor:]))
    return "".join(parts)


def markdown_html(markdown: str) -> str:
    """Render paragraphs, headings, lists, quotations, and fenced code safely."""
    lines, output, paragraph = markdown.splitlines(), [], []
    index, list_kind = 0, None

    def flush():
        if paragraph:
            output.append("<p>" + _inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    def close_list():
        nonlocal list_kind
        if list_kind:
            output.append("</" + list_kind + ">")
            list_kind = None

    while index < len(lines):
        line = lines[index]
        index += 1
        if line.lstrip().startswith("```"):
            flush()
            close_list()
            code = []
            while index < len(lines) and not lines[index].lstrip().startswith("```"):
                code.append(lines[index])
                index += 1
            if index < len(lines):
                index += 1
            output.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
            continue
        heading = re.fullmatch(r"(#{1,6})\s+(.+)", line)
        bullet = re.match(r"\s*(?:([-*+])|(\d+)[.)])\s+(.+)", line)
        if heading:
            flush()
            close_list()
            # The page owns h1. Review section headings start at h2.
            level = min(6, len(heading[1]) + 1)
            output.append(f"<h{level}>" + _inline(heading[2]) + f"</h{level}>")
        elif bullet:
            flush()
            kind = "ul" if bullet[1] else "ol"
            if list_kind != kind:
                close_list()
                output.append("<" + kind + ">")
                list_kind = kind
            output.append("<li>" + _inline(bullet[3]) + "</li>")
        elif line.startswith(">"):
            flush()
            close_list()
            output.append("<blockquote>" + _inline(line[1:].lstrip()) + "</blockquote>")
        elif not line.strip():
            flush()
            close_list()
        elif re.fullmatch(r"\s*(?:-\s*){3,}|\s*(?:\*\s*){3,}|\s*(?:_\s*){3,}", line):
            flush()
            close_list()
            output.append("<hr>")
        else:
            close_list()
            paragraph.append(line)
    flush()
    close_list()
    return "\n".join(output)


def render_report(markdown: str, scope: dict, reviewers: list[dict]) -> str:
    incomplete = [reviewer for reviewer in reviewers if not reviewer["complete"]]
    if incomplete:
        heading = "Incomplete review coverage"
        detail = "Some selected reviewers did not return a complete report for this revision. This report is not an all-clear."
        coverage = "<ul>" + "".join("<li><strong>" + html.escape(item["name"]) + "</strong>: " +
            html.escape(item.get("reason") or item["state"]) + "</li>" for item in incomplete) + "</ul>"
    else:
        heading = "All selected reviewer reports collected"
        detail = "Every selected reviewer returned a report for this revision. Findings remain subject to your review."
        coverage = ""
    raw_links = []
    for reviewer in reviewers:
        links = []
        for document in reviewer.get("documents", []):
            if re.fullmatch(r"prdoc_[a-f0-9]{12}", str(document.get("id") or "")):
                links.append('<li><a href="herdr-pr-review-document:' + document["id"] + '">' + html.escape(document["title"]) + "</a></li>")
        raw_links.append("<li><strong>" + html.escape(reviewer["name"]) + "</strong>" +
                         ("<ul>" + "".join(links) + "</ul>" if links else "<p>No report was collected.</p>") + "</li>")
    revision = html.escape(str(scope.get("base_sha") or "")) + " → " + html.escape(str(scope.get("head_sha") or ""))
    return ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'\">"
        "<title>Consolidated review</title><style>"
        ":root{color-scheme:dark;--ink:#eee8fa;--muted:#c0b2d4;--line:#b29ac62c;--accent:#ceadff}"
        "*{box-sizing:border-box}body{margin:0;background:radial-gradient(ellipse at 10% 0%,#4b316b66,transparent 60%),#17141e;"
        "color:var(--ink);font:16px/1.65 system-ui,-apple-system,sans-serif}main{max-width:980px;margin:0 auto;padding:48px 24px 72px}"
        "header{margin-bottom:28px}.eyebrow{color:var(--accent);font-size:13px;letter-spacing:.12em;text-transform:uppercase}"
        "h1{font-size:clamp(30px,5vw,44px);line-height:1.15;letter-spacing:-.03em;margin:12px 0}h2,h3,h4{line-height:1.3;margin-top:1.6em}"
        "h2{font-size:23px}h3{font-size:19px}p{margin:.8em 0}a{color:var(--accent);text-underline-offset:3px}a:focus-visible{outline:2px solid var(--accent);outline-offset:4px}"
        ".glass{background:linear-gradient(130deg,#72578d22,#29233280);border:1px solid var(--line);border-radius:18px;padding:26px;box-shadow:0 20px 60px #0002;backdrop-filter:blur(18px)}"
        ".coverage{margin:0 0 24px;border-left:4px solid #9b7cc2}.coverage.incomplete{border-left-color:#ddb676}.coverage h2{font-size:18px;margin:0}"
        ".coverage p{color:var(--muted);margin-bottom:0}.revision{color:var(--muted);overflow-wrap:anywhere;font-size:12px}"
        "code{font: .88em ui-monospace,SFMono-Regular,monospace;background:#9d7ab21c;padding:2px 5px;border-radius:4px;overflow-wrap:anywhere}"
        "pre{overflow:auto;background:#110e18b3;border:1px solid var(--line);border-radius:10px;padding:18px;line-height:1.5}pre code{background:none;padding:0;white-space:pre}"
        "blockquote{border-left:3px solid #9575b1;padding-left:18px;margin-left:0;color:var(--muted)}li{margin:.4em 0}hr{border:0;border-top:1px solid var(--line);margin:28px 0}"
        "section.raw{margin-top:24px}section.raw h2{margin-top:0}section.raw>ul{padding-left:20px}@media(max-width:600px){main{padding:24px 14px}.glass{padding:18px}}"
        "</style></head><body><main><header><div class=\"eyebrow\">PR Review</div><h1>Consolidated review</h1><p class=\"revision\">" + revision +
        "</p></header><section class=\"glass coverage" + (" incomplete" if incomplete else "") + "\"><h2>" + heading + "</h2><p>" + detail + "</p>" + coverage +
        "</section><article class=\"glass\">" + markdown_html(markdown) + "</article><section class=\"glass raw\"><h2>Raw reviewer reports</h2><ul>" +
        "".join(raw_links) + "</ul></section></main></body></html>")
