"""Skim v1: segmentation, prompt assembly, markup parsing, and normalization.

A skim is a short, casual rewrite of a finished agent reply in which linked
phrases open the exact original text. This module is a port of the Skim lab's
reference implementation (`lib/segment.js`, `lib/inline.js`, `lib/skim.js`)
and must reproduce its conformance vectors exactly: see docs/first-mate/skim.md
and tests/fixtures/first_mate_skim/.

Everything here is deterministic; only the model call is not. The JavaScript
semantics are kept deliberately: `\\s` means ECMAScript whitespace, `.` stops at
line terminators, `Math.round` rounds halves up, and segment offsets count
UTF-16 code units, so native clients can slice the canonical reply with
NSString ranges and never need a segmenter of their own.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from importlib import resources
import json
import math
import re
from typing import Any, Iterable, Mapping

SEGMENTER_VERSION = 1
SKIM_VERSION = 1
PROMPT_VERSION = "skim-v6"
DEFAULT_FORMAT = "breath_balanced"

# ECMAScript `\s`: WhiteSpace plus LineTerminator. Python's `\s` differs (it
# includes U+001C–U+001F and U+0085 and omits U+FEFF), so spell it out.
_WS = "\t\n\u000b\u000c\r    -     　﻿"
_S = f"[{_WS}]"
_NS = f"[^{_WS}]"
# ECMAScript `.` without the s flag.
_DOT = "[^\n\r  ]"
_JS_WHITESPACE = frozenset(
    "\t\n\u000b\u000c\r       　﻿"
    + "".join(chr(code) for code in range(0x2000, 0x200B))
)


class SkimRejected(ValueError):
    """The model output cannot become a skim; the original reply stands."""


def js_trim(value: str) -> str:
    start, end = 0, len(value)
    while start < end and value[start] in _JS_WHITESPACE:
        start += 1
    while end > start and value[end - 1] in _JS_WHITESPACE:
        end -= 1
    return value[start:end]


def js_round(value: float) -> int:
    """ECMAScript Math.round: halves round toward positive infinity."""
    floor = math.floor(value)
    return int(floor + 1 if value - floor >= 0.5 else floor)


def utf16_length(value: str) -> int:
    return len(value) + sum(1 for character in value if ord(character) > 0xFFFF)


def _utf16_prefix(value: str, units: int) -> str:
    """The longest prefix within `units` UTF-16 code units, never splitting a pair."""
    count = 0
    for index, character in enumerate(value):
        count += 2 if ord(character) > 0xFFFF else 1
        if count > units:
            return value[:index]
    return value


def _js_string(value: Any) -> str:
    """ECMAScript String(value) for JSON-shaped values."""
    if value is None:
        return "null"
    if value is _UNDEFINED:
        return "undefined"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return value
    if isinstance(value, float):
        if value.is_integer() and abs(value) < 1e21:
            return str(int(value))
        return repr(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return ",".join("" if item is None else _js_string(item) for item in value)
    return "[object Object]"


def _js_json(value: Any) -> str:
    """ECMAScript JSON.stringify for the values warnings quote."""
    if value is _UNDEFINED:
        return "undefined"
    if isinstance(value, float) and value.is_integer() and abs(value) < 1e21:
        return str(int(value))
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


class _Undefined:
    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "undefined"


_UNDEFINED = _Undefined()


def _get(value: Any, key: str) -> Any:
    """Property access that tells a missing key (undefined) from null."""
    if isinstance(value, dict):
        return value.get(key, _UNDEFINED)
    return _UNDEFINED


def _nullish(value: Any) -> bool:
    return value is None or value is _UNDEFINED


def _truthy(value: Any) -> bool:
    if _nullish(value) or value is False:
        return False
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value != 0 and not (isinstance(value, float) and math.isnan(value))
    if isinstance(value, str):
        return value != ""
    return True


# ---------------------------------------------------------------- segmentation

_FENCE_OPEN = re.compile(rf"^( {{0,3}})(`{{3,}}|~{{3,}})({_DOT}*)\Z")
_FENCE_CLOSE = re.compile(rf"^ {{0,3}}(`{{3,}}|~{{3,}}){_S}*\Z")
_HEADING = re.compile(rf"^ {{0,3}}(#{{1,6}})(?:{_S}+({_DOT}*?))?{_S}*#*{_S}*\Z")
_RULE = re.compile(r"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*\Z")
_QUOTE = re.compile(r"^ {0,3}>")
_LIST_ITEM = re.compile(r"^( {0,3})([-*+]|[0-9]{1,9}[.)])([ \t]+|\Z)")
_TABLE_SEP = re.compile(rf"^{_S}*\|?{_S}*:?-{{1,}}:?{_S}*(\|{_S}*:?-{{1,}}:?{_S}*)*\|?{_S}*\Z")
_PSEUDO_HEADING = re.compile(rf"^{_S}*(\*\*|__)([^*_\n]{{1,80}}?)\1:?{_S}*\Z")
_BLANK = re.compile(rf"^{_S}*\Z")
_WORD = re.compile(f"{_NS}+")
_SPLIT_WS = re.compile(f"{_S}+")

CONTENT_KINDS = frozenset({"paragraph", "item", "code", "table", "quote"})


def canonicalize(source: Any) -> str:
    """Canonical source: LF line endings. All offsets and line numbers refer to it."""
    return re.sub(r"\r\n?", "\n", "" if source is None else str(source))


def words(text: Any) -> int:
    return len(_WORD.findall(_js_string(text)))


def _is_blank(line: str) -> bool:
    return _BLANK.match(line) is not None


def _indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _is_table_start(lines: list[str], index: int) -> bool:
    return (index + 1 < len(lines) and "|" in lines[index]
            and _TABLE_SEP.match(lines[index + 1]) is not None and "-" in lines[index + 1])


def _is_block_start(lines: list[str], index: int) -> bool:
    line = lines[index]
    return bool(_FENCE_OPEN.match(line) or _HEADING.match(line) or _RULE.match(line)
                or _QUOTE.match(line) or _LIST_ITEM.match(line) or _is_table_start(lines, index))


def _close_fence(lines: list[str], start: int, marker: str) -> int:
    for index in range(start + 1, len(lines)):
        match = _FENCE_CLOSE.match(lines[index])
        if match and match.group(1)[0] == marker[0] and len(match.group(1)) >= len(marker):
            return index
    return len(lines) - 1  # An unterminated fence runs to the end of the reply.


def _end_of_list_item(lines: list[str], start: int, indent: int) -> int:
    index, last = start + 1, start
    while index < len(lines):
        line = lines[index]
        if _is_blank(line):
            ahead = index + 1
            while ahead < len(lines) and _is_blank(lines[ahead]):
                ahead += 1
            if ahead < len(lines) and _indent_of(lines[ahead]) > indent:
                index = ahead
                continue
            break
        if _indent_of(line) > indent:
            # Nested content, including fences whose inner lines may be unindented.
            fence = _FENCE_OPEN.match(line)
            if fence:
                close = _close_fence(lines, index, fence.group(2))
                last, index = close, close + 1
                continue
            last, index = index, index + 1
            continue
        if not _is_block_start(lines, index):
            last, index = index, index + 1  # Lazy paragraph continuation.
            continue
        break
    return last


@dataclass(frozen=True)
class ReplyDocument:
    version: int
    text: str
    lines: list[str]
    segments: list[dict]


def segment(source: Any) -> ReplyDocument:
    """Split a reply into addressable blocks (segmenter version 1)."""
    text = canonicalize(source)
    lines = text.split("\n")
    line_start: list[int] = []
    offset = 0
    for line in lines:
        line_start.append(offset)
        offset += utf16_length(line) + 1

    segments: list[dict] = []
    section: str | None = None

    def push(kind: str, first: int, last: int, **extra: Any) -> None:
        nonlocal section
        number = len(segments) + 1
        body = "\n".join(lines[first:last + 1])
        seg = {
            "id": f"s{number}", "n": number, "kind": kind,
            "startLine": first + 1, "endLine": last + 1,
            "start": line_start[first], "end": line_start[last] + utf16_length(lines[last]),
            "text": body, "words": words(body), "section": section, **extra,
        }
        if kind == "heading":
            seg["section"] = seg["id"]
            section = seg["id"]
        segments.append(seg)

    index = 0
    while index < len(lines):
        line = lines[index]
        if _is_blank(line):
            index += 1
            continue
        fence = _FENCE_OPEN.match(line)
        if fence:
            close = _close_fence(lines, index, fence.group(2))
            parts = _SPLIT_WS.split(js_trim(fence.group(3)))
            push("code", index, close, lang=parts[0] if parts else "", codeLines=max(0, close - index - 1))
            index = close + 1
            continue
        heading = _HEADING.match(line)
        if heading:
            push("heading", index, index, level=len(heading.group(1)), title=js_trim(heading.group(2) or ""))
            index += 1
            continue
        if _RULE.match(line):
            push("rule", index, index)
            index += 1
            continue
        if _is_table_start(lines, index):
            ahead = index + 2
            while ahead < len(lines) and not _is_blank(lines[ahead]) and "|" in lines[ahead]:
                ahead += 1
            push("table", index, ahead - 1, rows=ahead - index - 2)
            index = ahead
            continue
        if _QUOTE.match(line):
            ahead = index + 1
            while (ahead < len(lines) and not _is_blank(lines[ahead])
                   and (_QUOTE.match(lines[ahead]) or not _is_block_start(lines, ahead))):
                ahead += 1
            push("quote", index, ahead - 1)
            index = ahead
            continue
        item = _LIST_ITEM.match(line)
        if item:
            end = _end_of_list_item(lines, index, len(item.group(1)))
            push("item", index, end, ordered=re.search("[0-9]", item.group(2)) is not None)
            index = end + 1
            continue
        # A lone bold line ("**Next steps**") acts as a heading, even when the
        # paragraph it introduces starts on the very next line.
        pseudo = _PSEUDO_HEADING.match(line)
        if pseudo:
            push("heading", index, index, level=4, title=js_trim(pseudo.group(2)), pseudo=True)
            index += 1
            continue
        ahead = index + 1
        while ahead < len(lines) and not _is_blank(lines[ahead]) and not _is_block_start(lines, ahead):
            ahead += 1
        push("paragraph", index, ahead - 1)
        index = ahead

    return ReplyDocument(SEGMENTER_VERSION, text, lines, segments)


def prompt_view(segments: Iterable[dict], *, max_code_lines: int = 14, keep_code_lines: int = 10,
                max_table_rows: int = 12, keep_table_rows: int = 8) -> str:
    """The block listing shown to the model. Long code and tables are clipped here only."""
    out: list[str] = []
    for seg in segments:
        if seg["kind"] == "rule":
            continue
        tag = "para" if seg["kind"] == "paragraph" else seg["kind"]
        body = seg["text"]
        if seg["kind"] == "code":
            tag = f"code{' ' + seg['lang'] if seg['lang'] else ''}, {seg['codeLines']} lines"
            lines = body.split("\n")
            inner = lines[1:-1]
            if len(inner) > max_code_lines:
                body = "\n".join([lines[0], *inner[:keep_code_lines],
                                  f"… ({len(inner) - keep_code_lines} more lines)", lines[-1]])
        elif seg["kind"] == "table":
            tag = f"table, {seg['rows']} rows"
            lines = body.split("\n")
            if seg["rows"] > max_table_rows:
                body = "\n".join([*lines[:2 + keep_table_rows], f"… ({seg['rows'] - keep_table_rows} more rows)"])
        out.append(f"[{seg['id']} {tag}]\n{body}")
    return "\n\n".join(out)


def slice_runs(document: ReplyDocument, ids: Iterable[str]) -> list[dict]:
    """Exact original text for segment ids; runs separated only by rules join verbatim."""
    by_id = {seg["id"]: seg for seg in document.segments}
    chosen = sorted({by_id[i]["n"]: by_id[i] for i in ids if i in by_id}.values(), key=lambda seg: seg["n"])
    runs: list[list[dict]] = []
    for seg in chosen:
        previous = runs[-1][-1] if runs else None
        between = document.segments[previous["n"]:seg["n"] - 1] if previous else []
        if runs and all(item["kind"] == "rule" for item in between):
            runs[-1].append(seg)
        else:
            runs.append([seg])
    encoded = document.text.encode("utf-16-le")
    result = []
    for run in runs:
        first, last = run[0], run[-1]
        result.append({
            "ids": [seg["id"] for seg in run],
            "startLine": first["startLine"], "endLine": last["endLine"],
            "text": encoded[first["start"] * 2:last["end"] * 2].decode("utf-16-le"),
        })
    return result


def segment_table(document: ReplyDocument) -> list[dict]:
    """What clients need to slice excerpts: never the text itself."""
    table = []
    for seg in document.segments:
        row = {key: seg[key] for key in ("id", "n", "kind", "startLine", "endLine", "start", "end", "words", "section")}
        for key in ("lang", "codeLines", "rows", "ordered", "level", "pseudo"):
            if key in seg:
                row[key] = seg[key]
        table.append(row)
    return table


# ---------------------------------------------------------------- inline text

_REF = rf"#?[sS]([0-9]+)(?:{_S}*[-–]{_S}*#?[sS]?([0-9]+))?"
_ANCHOR = re.compile(rf"\[([^\[\]\n]+)\]\({_S}*({_REF}(?:{_S}*,{_S}*{_REF})*){_S}*\)")
_REF_GLOBAL = re.compile(_REF)
_BARE_REF = re.compile(rf"{_S}*[\[(]{_S}*{_REF}(?:{_S}*,{_S}*{_REF})*{_S}*[\])]")
_BOLD = re.compile(rf"(\*\*|__)({_DOT}+?)\1")
_ITALIC = re.compile(rf"(^|[{_WS}(])\*({_NS}[^*\n]*?)\*(?=[{_WS}).,;:!?]|\Z)")


def parse_refs(refs: Any) -> list[list[int]]:
    """Parse a refs list like "s4-s6, s9" into [[4, 6], [9, 9]]."""
    out = []
    for match in _REF_GLOBAL.finditer(_js_string(refs)):
        first = int(match.group(1))
        second = int(match.group(2)) if match.group(2) else first
        out.append([first, second] if first <= second else [second, first])
    return out


def _strip_emphasis(text: str, notes: list[str]) -> str:
    cleaned = _ITALIC.sub(r"\1\2", _BOLD.sub(r"\2", text))
    if cleaned != text:
        notes.append("emphasis_stripped")
    return cleaned


def _push_text(tokens: list[dict], value: str) -> None:
    if not value:
        return
    if tokens and tokens[-1]["t"] == "text":
        tokens[-1]["v"] += value
    else:
        tokens.append({"t": "text", "v": value})


def _parse_code_and_text(source: str, tokens: list[dict]) -> None:
    index = 0
    while index < len(source):
        tick = source.find("`", index)
        if tick == -1:
            _push_text(tokens, source[index:])
            break
        close = source.find("`", tick + 1)
        inner = "" if close == -1 else source[tick + 1:close]
        if close == -1 or not inner or "\n" in inner:
            _push_text(tokens, source[index:tick + 1])
            index = tick + 1
            continue
        _push_text(tokens, source[index:tick])
        tokens.append({"t": "code", "v": inner})
        index = close + 1


def parse_inline(value: Any) -> tuple[list[dict], list[str]]:
    """Tokenize skim text; anchors carry raw numeric ranges until normalize()."""
    notes: list[str] = []
    source = _strip_emphasis("" if _nullish(value) else _js_string(value), notes)
    tokens: list[dict] = []
    index = plain_start = 0
    while index < len(source):
        if source[index] == "[":
            match = _ANCHOR.match(source, index)
            if match:
                _parse_code_and_text(source[plain_start:index], tokens)
                label: list[dict] = []
                _parse_code_and_text(js_trim(match.group(1)), label)
                tokens.append({"t": "anchor", "label": label, "ranges": parse_refs(match.group(2))})
                index = plain_start = match.end()
                continue
        index += 1
    _parse_code_and_text(source[plain_start:], tokens)

    # Block ids written outside a link are noise to the reader; drop them.
    for token in tokens:
        if token["t"] != "text":
            continue
        cleaned = _BARE_REF.sub("", token["v"])
        if cleaned != token["v"]:
            notes.append("bare_ref")
            token["v"] = cleaned
    for position in range(1, len(tokens) - 1):
        if (tokens[position]["t"] == "anchor" and tokens[position - 1].get("v", "").endswith("(")
                and tokens[position + 1].get("v", "").startswith(")")):
            notes.append("tacked_link")
    return [token for token in tokens if token["t"] != "text" or token["v"]], notes


def plain(tokens: Iterable[dict]) -> str:
    """Plain-text form of tokens (word counts, accessibility labels, and copy)."""
    return "".join(plain(token["label"]) if token["t"] == "anchor" else token["v"] for token in tokens)


# ---------------------------------------------------------------- the skim

STATUSES = {
    "done": "Done",
    "partial": "Partly done",
    "blocked": "Blocked",
    "answer": "Answer",
    "plan": "Plan, needs your go-ahead",
}
BLOCK_KINDS = ("say", "list", "ask", "heads_up", "what", "why", "next", "reply")
DRAWER_KINDS = ("code", "table", "log", "steps", "files", "detail")
_BLOCK_ALIASES = {
    "say": "say", "text": "say", "p": "say", "paragraph": "say", "note": "say",
    "list": "list", "bullets": "list", "points": "list", "items": "list",
    "ask": "ask", "question": "ask", "decision": "ask",
    "heads_up": "heads_up", "headsup": "heads_up", "caveat": "heads_up", "warning": "heads_up", "risk": "heads_up",
    "what": "what", "why": "why", "next": "next",
    "reply": "reply", "suggestion": "reply",
}
FORMATS = {
    "notes": {"cap": math.inf, "floor": 0},
    "chat": {"cap": math.inf, "floor": 0},
    "card": {"cap": math.inf, "floor": 0},
    "breath": {"cap": 45, "floor": 16},
    "breath_next": {"cap": 45, "floor": 16},
    "breath_reply": {"cap": 45, "floor": 16},
    "breath_tight": {"cap": 35, "floor": 12},
    "breath_balanced": {"cap": 42, "floor": 36},
}
VOICES = {
    "buddy": {
        "prompt": "Sound like a friendly teammate giving you the quick version over chat: relaxed and warm, but still specific.",
        "ratio": 0.18, "floor": 30, "cap": 90,
    },
    "crisp": {
        "prompt": "Sound like a sharp senior engineer on your team: casual and direct, zero fluff, every sentence carries information.",
        "ratio": 0.14, "floor": 24, "cap": 70,
    },
    "terse": {
        "prompt": "Be extremely brief: a headline and at most two short blocks. Put everything else behind links and drawers.",
        "ratio": 0.08, "floor": 14, "cap": 35,
    },
}


def budget(source_words: int, voice: str = "buddy", format: str = "notes") -> dict:
    """Word budget for the headline and blocks. Short replies never get longer."""
    if format == "breath_balanced":
        original = budget(source_words, voice, "breath_tight")
        return {key: js_round(value * 1.2) for key, value in original.items()}
    tone = VOICES.get(voice, VOICES["buddy"])
    shape_limits = FORMATS.get(format, FORMATS["notes"])
    floor = min(tone["floor"], shape_limits["cap"])
    scaled = min(min(tone["cap"], shape_limits["cap"]), max(floor, js_round(source_words * tone["ratio"])))
    maximum = min(scaled, max(floor, js_round(source_words * 0.8)))
    return {"max": maximum, "target": max(floor, js_round(maximum * 0.7))}


def shape(limits: dict, format: str = "notes") -> str:
    """Structural length guidance: models follow sentence counts far better than word counts."""
    sentences = max(1, js_round(limits["max"] / 16))
    cap = f"Stay under {limits['max']} words in total, drawers excluded."
    if format == "chat":
        if limits["max"] <= 30:
            return f"Write one short paragraph of one or two sentences. {cap}"
        return f"Write 2 or 3 short paragraphs, about {sentences} sentences in total. {cap}"
    if format == "card":
        return f"Each slot gets one short sentence, two at most. {cap}"
    if format == "breath_tight":
        return f"Write exactly one sentence of at most 25 words, include an optional next-step line only when the reply explicitly contains that question or suggestion. {cap}"
    if format == "breath_balanced":
        return f"Write one or two sentences of at most 30 words combined, then an optional next-step line. {cap} Reply options are excluded from this budget."
    if format.startswith("breath"):
        return f"Write one or two sentences, include an optional next-step line only when the reply explicitly contains that question or suggestion. {cap}"
    if limits["max"] <= 30:
        return f"Write the headline plus at most one more short line. {cap}"
    if limits["max"] <= 60:
        return f"Write the headline plus at most 2 more lines, about {sentences} sentences in total. {cap}"
    return f"Write the headline plus at most 4 more lines (a list counts as one), about {sentences} sentences in total. {cap}"


@dataclass(frozen=True)
class SkimPrompt:
    system: str
    user: str
    budget: dict
    source_words: int


def build_prompt(*, template: str, format_template: str = "", question: str | None,
                 reply: str | ReplyDocument, voice: str = "buddy", format: str = "notes") -> SkimPrompt:
    """Fill the shared template ({{FORMAT}} takes the format section) and build the user message."""
    document = segment(reply) if isinstance(reply, str) else reply
    source_words = words(document.text)
    limits = budget(source_words, voice, format)
    system = (template
              .replace("{{FORMAT}}", js_trim(format_template))
              .replace("{{VOICE}}", VOICES.get(voice, VOICES["buddy"])["prompt"])
              .replace("{{SHAPE}}", shape(limits, format))
              .replace("{{TARGET_WORDS}}", str(limits["target"]))
              .replace("{{MAX_WORDS}}", str(limits["max"])))
    listed = sum(1 for seg in document.segments if seg["kind"] != "rule")
    user = "\n".join([
        "QUESTION (what the user asked the agent):",
        js_trim(question or "") or "(not provided)",
        "",
        f"REPLY (the agent's full reply: {listed} blocks, {source_words} words):",
        prompt_view(document.segments),
    ])
    return SkimPrompt(system, user, limits, source_words)


_MARKUP_LINE = re.compile(
    rf"^{_S}*(status|headline|say|what|why|next|reply|ask|heads[_ -]?up|caveat|drawer|action){_S}*:{_S}?({_DOT}*)\Z",
    re.IGNORECASE | re.ASCII,
)
_MARKUP_ITEM = re.compile(rf"^{_S}*(?:[-*•]|[0-9]{{1,2}}[.)]){_S}+({_DOT}*)\Z")
_MARKUP_FENCE = re.compile(r"```[A-Za-z0-9_-]*\n([\s\S]*?)(?:\n```|\Z)")
_LEADING_FENCE = re.compile(r"^```[A-Za-z0-9_-]*\n")
_JSON_FENCE = re.compile(rf"```(?:json)?{_S}*\n([\s\S]*?)\n```")


def parse_markup(raw: Any, *, final: bool = True) -> tuple[dict, list[str]]:
    """Parse Skim markup into the object normalize() accepts.

    Lenient in one way only: an unprefixed line continues the previous line,
    and that repair is reported.
    """
    text = canonicalize("" if _nullish(raw) else _js_string(raw))
    fence = _MARKUP_FENCE.search(text)
    if fence:
        text = fence.group(1)
    lines = text.split("\n")
    if not final:
        lines = lines[:-1]  # Streaming: the last line may be incomplete.
    parsed: dict = {"skim": 1, "status": None, "headline": "", "blocks": [], "drawers": []}
    notes: list[str] = []
    last: dict | None = None  # {"obj", "key", "list"} for continuation lines
    for line in lines:
        if not js_trim(line):
            last = None
            continue
        match = _MARKUP_LINE.match(line)
        if match:
            key = re.sub(f"[{_WS}-]", "_", match.group(1).lower()).replace("headsup", "heads_up", 1).replace("caveat", "heads_up", 1)
            value = js_trim(match.group(2))
            if key == "status":
                parsed["status"] = value.lower()
                last = None
            elif key == "headline":
                parsed["headline"] = value
                last = {"obj": parsed, "key": "headline"}
            elif key == "action":
                fields = [js_trim(part) for part in value.split("|")]
                if len(fields) == 3:
                    parsed.setdefault("actions", []).append(dict(zip(("label", "explanation", "refs"), fields)))
                else:
                    notes.append("action_shape")
                last = None
            elif key == "drawer":
                fields = [js_trim(part) for part in value.split("|")]
                title, kind, refs = (fields + ["", "", ""])[:3]
                parsed["drawers"].append({"title": title, "kind": kind, "refs": refs, "peek": " | ".join(fields[3:])})
                last = None
            else:
                block = {key: value}
                parsed["blocks"].append(block)
                last = {"obj": block, "key": key}
            continue
        item = _MARKUP_ITEM.match(line)
        if item:
            previous = parsed["blocks"][-1] if parsed["blocks"] else None
            if previous is not None and isinstance(previous.get("list"), list) and last and last.get("list"):
                previous["list"].append(js_trim(item.group(1)))
            else:
                parsed["blocks"].append({"list": [js_trim(item.group(1))]})
            items = parsed["blocks"][-1]["list"]
            last = {"obj": items, "key": len(items) - 1, "list": True}
            continue
        if last:
            last["obj"][last["key"]] = js_trim(f"{last['obj'][last['key']]} {js_trim(line)}")
            notes.append("continuation")
        elif not parsed["headline"] and not parsed["blocks"]:
            parsed["headline"] = js_trim(line)
            last = {"obj": parsed, "key": "headline"}
            notes.append("unlabeled_headline")
        else:
            parsed["blocks"].append({"say": js_trim(line)})
            last = {"obj": parsed["blocks"][-1], "key": "say"}
            notes.append("unlabeled_line")
    return parsed, notes


def _reject_constant(name: str) -> Any:
    raise ValueError(f"Invalid JSON constant {name}")


def extract_json(raw: Any) -> Any:
    """Pull the JSON value out of legacy model output (tolerates fences and chatter)."""
    text = js_trim("" if _nullish(raw) else _js_string(raw))
    fence = _JSON_FENCE.search(text)
    if fence:
        text = fence.group(1)
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        raise SkimRejected("The model output has no JSON object.")
    try:
        return json.loads(text[start:end + 1], parse_constant=_reject_constant)
    except ValueError as exc:
        raise SkimRejected("The model output has unparsable JSON.") from exc


def read_model_output(raw: Any) -> tuple[Any, str, list[str]]:
    """Read model output in either syntax: Skim markup (preferred) or legacy JSON."""
    text = js_trim("" if _nullish(raw) else _js_string(raw))
    body = _LEADING_FENCE.sub("", text, count=1)
    if body.startswith("{"):
        return extract_json(text), "json", []
    parsed, notes = parse_markup(text)
    if not parsed["headline"] and not parsed["blocks"]:
        raise SkimRejected("The model output has no skim lines.")
    return parsed, "markup", notes


def _read_block(raw: Any) -> dict | None:
    if isinstance(raw, str):
        return {"kind": "say", "value": raw}
    if not isinstance(raw, dict):
        return None
    if _truthy(raw.get("kind")) or _truthy(raw.get("type")):
        kind = _BLOCK_ALIASES.get(_js_string(raw["kind"] if _truthy(raw.get("kind")) else raw["type"]).lower())
        if not kind:
            return None
        value = _UNDEFINED
        for key in ("items", "text", "value"):
            value = _get(raw, key)
            if not _nullish(value):
                break
        return {"kind": kind, "value": value}
    if len(raw) != 1:
        return None
    (key, value), = raw.items()
    kind = _BLOCK_ALIASES.get(key.lower())
    return {"kind": kind, "value": value} if kind else None


def _refs_text(value: Any) -> str:
    if isinstance(value, list):
        return ",".join("" if _nullish(item) else _js_string(item) for item in value)
    return "" if _nullish(value) else _js_string(value)


def _kind_of(refs: list[str], segments: list[dict]) -> str:
    kinds = {segments[int(ref[1:]) - 1]["kind"] for ref in refs}
    if "code" in kinds:
        return "code"
    if "table" in kinds:
        return "table"
    return "text"


def normalize(parsed: Any, reply: ReplyDocument, *, voice: str = "buddy",
              notes: Iterable[str] = (), format: str = "notes") -> dict:
    """Validate and repair parsed model output against the segmented reply.

    Content problems become warnings. Only an unusable shape or a runaway skim
    raises SkimRejected; the original reply is then shown unchanged.
    """
    if format not in FORMATS:
        format = "notes"
    notes = list(notes)
    warnings: list[dict] = []

    def warn(code: str, message: str, level: str = "warn") -> None:
        warnings.append({"level": level, "code": code, "message": message})

    for code in ACTION_REPAIR_WARNINGS:
        if code in notes:
            _warn_action(warnings, code)
    if "continuation" in notes:
        warn("continuation", "Joined a wrapped line onto the line before it.", "info")
    if "unlabeled_line" in notes or "unlabeled_headline" in notes:
        warn("unlabeled_line", "Treated an unlabeled line as prose.")
    segments = reply.segments
    count = len(segments)

    if not isinstance(parsed, dict):
        raise SkimRejected("The model output is not a JSON object.")
    version = _get(parsed, "skim")
    if not (isinstance(version, (int, float)) and not isinstance(version, bool) and version == SKIM_VERSION):
        warn("version", f'Expected "skim": 1, got {_js_json(version)}.', "info")
    extra = [key for key in parsed if key not in {"skim", "status", "headline", "blocks", "drawers", "actions"}]
    if extra:
        warn("unknown_keys", f"Ignored keys: {', '.join(extra)}.", "info")

    anchors: list[dict] = []

    def resolve_ranges(ranges: list[list[int]], where: str) -> list[str]:
        ids: dict[str, None] = {}
        dropped = 0
        for first, last in ranges:
            if first < 1 or first > count:
                dropped += 1
                continue
            if last > count:
                dropped += 1
            for number in range(first, min(last, count) + 1):
                if segments[number - 1]["kind"] != "rule":
                    ids[f"s{number}"] = None
        if dropped:
            warn("bad_ref", f"{where}: dropped {dropped} reference(s) outside s1–s{count}.")
        return sorted(ids, key=lambda ref: int(ref[1:]))

    def inline(value: Any, where: str) -> list[dict]:
        tokens, inline_notes = parse_inline(value)
        if "emphasis_stripped" in inline_notes:
            warn("emphasis", f"{where}: removed bold/italic markers.", "info")
        if "bare_ref" in inline_notes:
            warn("bare_ref", f"{where}: removed block ids written outside a link.")
        if "tacked_link" in inline_notes:
            warn("tacked_link", f"{where}: a link label was tacked on in parentheses instead of linking the sentence.", "info")
        out: list[dict] = []
        for token in tokens:
            if token["t"] != "anchor":
                out.append(token)
                continue
            refs = resolve_ranges(token["ranges"], f'Link "{plain(token["label"])}"')
            if not refs:
                warn("dead_link", f'Link "{plain(token["label"])}" had no valid blocks and became plain text.')
                out.extend(token["label"])
                continue
            anchor = {"id": f"a{len(anchors) + 1}", "label": plain(token["label"]), "refs": refs, "where": where}
            anchor["kind"] = _kind_of(refs, segments)
            anchors.append(anchor)
            out.append({"t": "anchor", "id": anchor["id"], "label": token["label"], "refs": refs})
        return out

    raw_status = _get(parsed, "status")
    status = re.sub(f"[{_WS}-]", "_", ("" if _nullish(raw_status) else _js_string(raw_status)).lower())
    if status not in STATUSES:
        warn("status", f'Unknown status {_js_json(raw_status)}; showing "Answer".', "info")
        status = "answer"

    raw_headline = _get(parsed, "headline")
    headline_text = js_trim("" if _nullish(raw_headline) else _js_string(raw_headline))
    if not headline_text and format in {"notes", "card"}:
        warn("headline", "Missing headline.")
    if words(headline_text) > 18:
        warn("headline_long", f"Headline is {words(headline_text)} words (aim for 14 or fewer).", "info")
    headline = inline(headline_text, "headline")

    blocks: list[dict] = []
    raw_blocks: list[Any] = []
    raw_list = _get(parsed, "blocks")
    if not isinstance(raw_list, list):
        warn("blocks", "Missing blocks array.")
    for raw in raw_list if isinstance(raw_list, list) else []:
        keys = list(raw) if isinstance(raw, dict) and not _truthy(raw.get("kind")) and not _truthy(raw.get("type")) else []
        if len(keys) > 1 and all(key.lower() in _BLOCK_ALIASES for key in keys):
            warn("block_split", f"Split a block with {len(keys)} keys ({', '.join(keys)}) into separate blocks.", "info")
            raw_blocks.extend({key: raw[key]} for key in keys)
        else:
            raw_blocks.append(raw)
    for index, raw in enumerate(raw_blocks):
        block = _read_block(raw)
        where = f"block {index + 1}"
        if block is None:
            warn("block_shape", f"Skipped {where}: unrecognized shape.")
            continue
        value = block["value"]
        if block["kind"] == "list":
            candidates = value if isinstance(value, list) else [value]
            items = [item for item in candidates if isinstance(item, str) and js_trim(item)]
            if not items:
                warn("block_empty", f"Skipped empty list in {where}.")
                continue
            if len(items) > 6:
                warn("list_long", f"{where} has {len(items)} items (aim for 2–4).", "info")
            blocks.append({"kind": "list", "items": [inline(item, f"{where} item {position + 1}")
                                                     for position, item in enumerate(items)]})
        elif block["kind"] == "reply":
            # Suggested replies are button labels: plain text, never links.
            tokens, _ = parse_inline("" if _nullish(value) else _js_string(value))
            if any(token["t"] == "anchor" for token in tokens):
                warn("reply_link", f"{where}: removed a link from a suggested reply.", "info")
            label = js_trim(plain(tokens))
            if not label:
                warn("block_empty", f"Skipped empty reply in {where}.")
                continue
            if words(label) > 8:
                warn("reply_long", f'Suggested reply "{label}" is {words(label)} words (aim for 2 to 6).', "info")
            blocks.append({"kind": "reply", "tokens": [{"t": "text", "v": label}]})
        else:
            if isinstance(value, list):
                text = " ".join("" if _nullish(item) else _js_string(item) for item in value)
            else:
                text = "" if _nullish(value) else _js_string(value)
            if not js_trim(text):
                warn("block_empty", f"Skipped empty {block['kind']} in {where}.")
                continue
            blocks.append({"kind": block["kind"], "tokens": inline(js_trim(text), where)})
    if len(blocks) > 6:
        warn("blocks_many", f"{len(blocks)} blocks (aim for 1–5).", "info")
    if format == "card":
        missing = [kind for kind in ("what", "why", "next") if not any(block["kind"] == kind for block in blocks)]
        if missing:
            warn("card_slot", f"The card is missing {', '.join(missing)}.", "info")

    drawers: list[dict] = []
    raw_drawers = _get(parsed, "drawers")
    for index, raw in enumerate(raw_drawers if isinstance(raw_drawers, list) else []):
        if not isinstance(raw, (dict, list)):
            continue
        where = f"drawer {index + 1}"
        raw_title = _get(raw, "title")
        refs = resolve_ranges(parse_refs(_refs_text(_get(raw, "refs"))),
                              f'Drawer "{index + 1 if _nullish(raw_title) else _js_string(raw_title)}"')
        if not refs:
            warn("drawer_empty", f"Skipped {where}: no valid blocks.")
            continue
        raw_kind = _get(raw, "kind")
        kind = ("detail" if _nullish(raw_kind) else _js_string(raw_kind)).lower()
        if kind not in DRAWER_KINDS:
            kind = "detail" if _kind_of(refs, segments) == "text" else _kind_of(refs, segments)
        title_tokens, _ = parse_inline("Details" if _nullish(raw_title) else _js_string(raw_title))
        title = _utf16_prefix(js_trim(plain(title_tokens)), 48) or "Details"
        raw_peek = _get(raw, "peek")
        peek_tokens, _ = parse_inline("" if _nullish(raw_peek) else _js_string(raw_peek))
        peek = js_trim(plain(peek_tokens))
        if words(peek) > 16:
            warn("peek_long", f"{where} peek is {words(peek)} words (aim for 12 or fewer).", "info")
        drawers.append({"id": f"d{len(drawers) + 1}", "title": title, "kind": kind, "peek": peek, "refs": refs})
    if len(drawers) > 5:
        warn("drawers_many", f"{len(drawers)} drawers (aim for 0–4).", "info")

    # Coverage: every content block must stay reachable.
    covered = {ref for anchor in anchors for ref in anchor["refs"]} | {ref for drawer in drawers for ref in drawer["refs"]}
    content = [seg for seg in segments if seg["kind"] in CONTENT_KINDS]
    uncovered = [seg["id"] for seg in content if seg["id"] not in covered]
    total_words = sum(seg["words"] for seg in content)
    covered_words = sum(seg["words"] for seg in content if seg["id"] in covered)

    skim_words = words(plain(headline)) + sum(
        words(" ".join(plain(item) for item in block["items"]) if block["kind"] == "list" else plain(block["tokens"]))
        for block in blocks
    )
    source_words = words(reply.text)
    limits = budget(source_words, voice, format)
    if skim_words > limits["max"] * 3 + 30:
        raise SkimRejected(
            f"The skim ran away: {skim_words} words against a budget of {limits['max']}. "
            "Rejected; the original reply is unchanged."
        )
    if skim_words > js_round(limits["max"] * 1.25):
        warn("over_budget", f"Skim is {skim_words} words; budget was {limits['max']}.")
    if not anchors and source_words > 150:
        warn("no_links", "No inline links; the reader can only reach detail through drawers.")
    if not any(block["kind"] in {"ask", "next", "reply"} for block in blocks):
        question = next((seg for seg in content if seg["kind"] not in {"code", "table"}
                         and re.search(rf"\?(?:{_S}|\Z)", seg["text"])), None)
        if question:
            warn("missed_question", f"The reply asks something in {question['id']}, but the skim has no ask block.", "info")

    return {
        "version": SKIM_VERSION,
        "format": format,
        "status": status,
        "statusLabel": STATUSES[status],
        "headline": headline,
        "blocks": blocks,
        "drawers": drawers,
        "rest": {"refs": uncovered},
        "anchors": anchors,
        **({"actions": normalize_actions(parsed.get("actions"), reply, blocks, warnings=warnings)}
           if isinstance(parsed, dict) and "actions" in parsed else {}),
        "stats": {
            "sourceWords": source_words,
            "skimWords": skim_words,
            "budget": limits,
            "links": len(anchors),
            "coveredWords": covered_words,
            "totalWords": total_words,
            "coverage": covered_words / total_words if total_words else 1,
        },
        "warnings": warnings,
    }


def _followup_sentences(text: str) -> list[str]:
    cleaned = " ".join(re.sub(r"[`*_]", "", text).split())
    return [re.sub(r"^(?:[-+>] |\d+[.)] )", "", sentence)
            for sentence in re.split(r"(?<=[.!?])\s+", cleaned)]


def _is_followup_sentence(sentence: str) -> bool:
    # The exact source sentence is checked separately. Accept ordinary offers,
    # including declarative ones, without requiring a scripted reply phrase.
    text = sentence.replace("’", "'").strip()
    if re.match(r"(?i)^(?:do not|don't|never|I (?:cannot|can't|won't|will not|am not)|you (?:cannot|can't|should not|shouldn't))\b", text):
        return False
    if re.match(
        r"(?i)^(?:(?:suggested |recommended |the )?next step(?: is(?: to)?| would be(?: to)?|:)) "
        r"(?:not|never|already|blocked|complete|completed|underway)\b", text
    ):
        return False
    if text.endswith("?"):
        return True
    if re.match(
        r"(?i)^(?:(?:suggested |recommended |the )?next step(?: is(?: to)?| would be(?: to)?|:)|"
        r"I(?:'d| would)? (?:suggest|recommend)\b|you (?:can|could|should)\b|"
        r"(?:reply|respond) with |please |let me know (?:which|whether|when|what)|"
        r"(?:choose|pick|select) (?:between |one |either |the )|let's )", text
    ):
        return True
    offer = re.sub(r"(?i)^(?:if (?:you(?:'d| would)? like|you want|helpful|useful),?\s+|next,\s+)", "", text)
    return bool(re.match(
        r"(?i)^(?:I (?:can|could)|I(?:'m| am) happy to|I(?:'d| would) be happy to) "
        r"(?!(?:not|never|already|confirm|see|tell)\b)\S", offer))


# Fixed codes carry no model output or source text into diagnostics.
_ACTION_WARNINGS = {
    "action_shape": "Omitted a reply option with an invalid shape.",
    "action_label": "Omitted a reply option with an invalid label.",
    "action_explanation": "Omitted a reply option with an invalid explanation.",
    "action_refs": "Omitted a reply option without valid offer references.",
}
ACTION_REPAIR_WARNINGS = frozenset(_ACTION_WARNINGS)


def _warn_action(warnings: list[dict] | None, code: str) -> None:
    if warnings is not None and not any(warning["code"] == code for warning in warnings):
        warnings.append({"level": "info", "code": code, "message": _ACTION_WARNINGS[code]})


def normalize_actions(raw: Any, reply: ReplyDocument, blocks: list[dict], *,
                      warnings: list[dict] | None = None) -> list[dict]:
    """Drop malformed options while retaining the useful skim and fixed diagnostics."""
    if not any(block["kind"] in {"ask", "next"} for block in blocks):
        return []
    if not isinstance(raw, list):
        # Null/empty optional fields do not establish that an option was generated.
        if raw:
            _warn_action(warnings, "action_shape")
        return []
    ids = {segment["id"] for segment in reply.segments
           if segment["kind"] not in {"code", "table", "rule", "quote"}
           and any(_is_followup_sentence(sentence) for sentence in _followup_sentences(segment["text"]))}
    result: list[dict] = []
    labels: set[str] = set()
    for entry in raw[:12]:
        if not isinstance(entry, dict):
            _warn_action(warnings, "action_shape")
            continue
        label, explanation = entry.get("label"), entry.get("explanation")
        if not isinstance(label, str):
            _warn_action(warnings, "action_label")
            continue
        label = label.strip()
        if (not 1 <= words(label) <= 5 or len(label) > 64
                or any(ord(c) < 32 for c in label)
                or any(c in label for c in "[]`*<>|")):
            _warn_action(warnings, "action_label")
            continue
        if (not isinstance(explanation, str) or not explanation.strip() or len(explanation.strip()) > 240
                or any(ord(c) < 32 for c in explanation.strip())):
            _warn_action(warnings, "action_explanation")
            continue
        if label.casefold() in labels:
            continue
        refs = []
        for start, end in parse_refs(_refs_text(entry.get("refs"))):
            if end - start > 32:
                continue
            refs.extend(f"s{n}" for n in range(start, end + 1))
        if not refs or not all(ref in ids for ref in refs):
            _warn_action(warnings, "action_refs")
            continue
        labels.add(label.casefold())
        result.append({"id": f"r{len(result) + 1}", "label": label, "explanation": explanation.strip(),
                       "refs": list(dict.fromkeys(refs))})
        if len(result) == 3:
            break
    return result


def _followup_text(text: str) -> str:
    return " ".join(re.sub(r"[`*_]", "", text).split())


def action_repair_asks(document: dict, reply: ReplyDocument) -> list[dict]:
    """Only rejected candidates paired with a retained source ask warrant repair.

    A valid empty result, a useful surviving option, and an unsupported follow-up
    never request another inference. Quoted examples cannot authorize options.
    """
    if document.get("actions") or not any(
            warning.get("code") in ACTION_REPAIR_WARNINGS for warning in document.get("warnings", [])):
        return []
    asks = []
    for block in document.get("blocks", []):
        if block.get("kind") not in {"ask", "next"}:
            continue
        text = _followup_text(plain(block.get("tokens", [])))
        refs = [source["id"] for source in reply.segments
                if source["kind"] not in {"code", "table", "rule", "quote"}
                and any(text == sentence and _is_followup_sentence(sentence)
                        for sentence in _followup_sentences(source["text"]))]
        if refs and not any(ask["text"] == text for ask in asks):
            asks.append({"text": text, "refs": refs})
    return asks


def repaired_actions(output: str, reply: ReplyDocument, original: dict) -> list[dict]:
    """Accept only options for one unchanged original ask, using the same validators."""
    asks = action_repair_asks(original, reply)
    if not asks:
        return []
    _, repaired, _ = skim_from_output(reply=reply.text, output=output, format=original["format"])
    if (not repaired or repaired["headline"] or repaired["drawers"]
            or len(repaired["blocks"]) != 1 or repaired["blocks"][0]["kind"] not in {"ask", "next"}):
        return []
    text = _followup_text(plain(repaired["blocks"][0]["tokens"]))
    allowed = next((set(ask["refs"]) for ask in asks if ask["text"] == text), set())
    result = [action for action in repaired.get("actions", []) if set(action["refs"]) <= allowed]
    return [{**action, "id": f"r{index + 1}"} for index, action in enumerate(result)]


def skim_from_output(*, reply: str, output: str, voice: str = "buddy", format: str = DEFAULT_FORMAT) -> tuple[ReplyDocument, dict, str]:
    """Segment a reply and normalize one model output against it."""
    document = segment(reply)
    parsed, syntax, notes = read_model_output(output)
    normalized = normalize(parsed, document, voice=voice, notes=notes, format=format)
    return document, ground_followups(normalized, reply), syntax


def ground_followups(document: Any, reply: str) -> Any:
    """Malformed saved skims degrade to the original response, not a failed read."""
    try:
        return _ground_followups(document, reply)
    except (TypeError, KeyError, AttributeError, ValueError):
        return None


def _ground_followups(document: Any, reply: str) -> Any:
    """An optional next action must quote a real ask or suggestion in the reply.

    Never change the original or generate a replacement action. Rebuild anchor
    and rest bookkeeping when removing an unsupported optional block.
    """
    if not isinstance(document, dict):
        return document
    original_blocks = document.get("blocks", [])
    if not any(b.get("kind") in {"ask", "next", "reply"} for b in original_blocks):
        return document
    segments = segment(reply).segments
    def clean(text):
        return " ".join(re.sub(r"[`*_]", "", text).split())
    def supported(block):
        text = clean(plain(block.get("tokens", [])))
        if not text:
            return False
        for source in segments:
            if source["kind"] in {"code", "table", "rule"}:
                continue
            # Match a complete offered sentence, never an action extracted
            # from a statement or negation.
            if any(text == sentence and _is_followup_sentence(sentence)
                   for sentence in _followup_sentences(source["text"])):
                return True
        return False
    original_blocks = document.get("blocks", [])
    blocks = [b for b in original_blocks if b.get("kind") not in {"ask", "next", "reply"} or supported(b)]
    if blocks == original_blocks:
        return document
    import copy
    result = copy.deepcopy(document)
    result["blocks"] = blocks
    if "actions" in result and not any(b.get("kind") in {"ask", "next"} for b in blocks):
        result["actions"] = []
    ids = set()
    def collect(value):
        if isinstance(value, dict):
            if value.get("t") == "anchor": ids.add(value.get("id"))
            for child in value.values(): collect(child)
        elif isinstance(value, list):
            for child in value: collect(child)
    collect([result.get("headline", []), blocks])
    result["anchors"] = [a for a in result.get("anchors", []) if a["id"] in ids]
    covered = {ref for a in result["anchors"] for ref in a["refs"]}
    covered.update(ref for drawer in result.get("drawers", []) for ref in drawer.get("refs", []))
    result["rest"] = {"refs": [s["id"] for s in segments if s["kind"] != "rule" and s["id"] not in covered]}
    stats = result.get("stats", {})
    stats["skimWords"] = words(plain(result.get("headline", []))) + sum(
        sum(words(plain(item)) for item in b.get("items", [])) if b.get("kind") == "list"
        else words(plain(b.get("tokens", []))) for b in blocks)
    stats["links"] = len(result["anchors"])
    stats["coveredWords"] = sum(words(s["text"]) for s in segments if s["id"] in covered)
    stats["coverage"] = stats["coveredWords"] / stats["totalWords"] if stats.get("totalWords") else 1
    result["stats"] = stats
    result.setdefault("warnings", []).append({"level": "info", "code": "unsupported_followup", "message": "Omitted a follow-up not stated in the reply."})
    return result


# ---------------------------------------------------------------- serving

# A pending skim older than this lost its job; clients read it as failed.
STALE_PENDING_SECONDS = 300
_SENTENCE_BLOCKS = frozenset({"say", "list", "what", "why"})
_NEXT_STEP_BLOCKS = frozenset({"ask", "next"})


def has_content(document: Mapping[str, Any]) -> bool:
    """Whether a normalized skim has a sentence or a next step to show.

    One that doesn't would hide the whole reply behind Rest of the original,
    so the companion rejects it and readers keep the full reply.
    """
    blocks = document.get("blocks") or []
    return bool(document.get("headline")) or any(
        block.get("kind") in _SENTENCE_BLOCKS | _NEXT_STEP_BLOCKS for block in blocks if isinstance(block, Mapping))


def _age_seconds(value: Any, now: datetime) -> float:
    try:
        stamp = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return 0.0
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return (now - stamp).total_seconds()


def served(state: Mapping[str, Any], *, now: datetime | None = None) -> dict:
    """What clients read for a skim, for First Mate messages and HUD turns alike.

    Only a ready skim carries its document, segment table, and reply hash.
    """
    status = state.get("status")
    if status == "pending" and _age_seconds(state.get("updated_at"), now or datetime.now(timezone.utc)) > STALE_PENDING_SECONDS:
        status = "failed"  # Never leave a reader on "Skimming" after a lost job.
    result = {"status": status, **{key: state.get(key) for key in ("format", "prompt_version", "segmenter_version", "skim_version")}}
    if status == "ready":
        result.update(document=state.get("document"), segments=state.get("segments"),
                      reply_sha256=state.get("reply_sha256"))
    return result


# ---------------------------------------------------------------- packaged prompt

def prompt_template(version: str = PROMPT_VERSION) -> str:
    return resources.files("herdr_harness").joinpath("skim_prompts", f"{version}.md").read_text(encoding="utf-8")


def format_template(format: str = DEFAULT_FORMAT, *, version: str = PROMPT_VERSION) -> str:
    directory = resources.files("herdr_harness").joinpath("skim_prompts", "formats")
    revision = directory.joinpath(f"{format}-{version}.md")
    # A revised prompt must not change the instructions of a saved older job.
    template = revision if revision.is_file() else directory.joinpath(f"{format}.md")
    return template.read_text(encoding="utf-8")


def prompt_for(question: str | None, reply: str, *, format: str = DEFAULT_FORMAT,
               version: str = PROMPT_VERSION, voice: str = "buddy") -> SkimPrompt:
    """The packaged system prompt and user message for one reply."""
    return build_prompt(template=prompt_template(version), format_template=format_template(format, version=version),
                        question=question, reply=reply, voice=voice, format=format)
