"""Bounded JSON projection for oversized Pi usage records.

Validate the entire record, including discarded content, but retain only the
fields the accountant reads. Never search text for apparent usage payloads.
"""
from __future__ import annotations

import codecs
import hashlib
import json
import re
from collections.abc import Callable, Iterable

_STRING_SPECIAL = re.compile(rb'["\\\x00-\x1f]')
_NUMBER = re.compile(rb'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\Z')
_SCALAR = {}
_MODEL = {key: _SCALAR for key in ("id", "provider", "modelId")}
_USAGE = {key: _SCALAR for key in (
    "input", "output", "cacheRead", "cacheWrite", "totalTokens", "provider", "model", "modelId")}
_USAGE["cost"] = {"total": _SCALAR}
_FIELDS = {key: _SCALAR for key in (
    "type", "id", "role", "provider", "modelId", "thinkingLevel", "thinking_level", "level")}
_FIELDS.update(model=_MODEL, usage=_USAGE)
_RECORD = {**_FIELDS, "message": _FIELDS}


def usage_fingerprint(value) -> bytes:
    """Order-independent object identity, shared by normal and streamed records."""
    if isinstance(value, dict):
        fields = {usage_fingerprint(key): usage_fingerprint(item) for key, item in value.items()}
        return hashlib.sha256(b"o" + b"".join(key + fields[key] for key in sorted(fields))).digest()
    if isinstance(value, list):
        return hashlib.sha256(b"a" + b"".join(usage_fingerprint(item) for item in value)).digest()
    if isinstance(value, str):
        return hashlib.sha256(b"s" + value.encode("utf-8", errors="surrogatepass")).digest()
    return hashlib.sha256(b"v" + json.dumps(value).encode()).digest()


class UsageJSON:
    """Parse one chunked JSON value with fixed depth and retained-text limits."""

    def __init__(self, chunks: Iterable[bytes], *, limit: int = 64 * 1024,
                 check_cancelled: Callable[[], None] | None = None):
        self.chunks = iter(chunks)
        self.buffer = b""
        self.offset = 0
        self.budget = limit
        self.fingerprint = b""
        self.check_cancelled = check_cancelled
        self.values = 0

    def peek(self) -> bytes:
        while self.offset == len(self.buffer):
            self.buffer = next(self.chunks, b"")
            self.offset = 0
            if not self.buffer:
                return b""
        return self.buffer[self.offset:self.offset + 1]

    def take(self) -> bytes:
        value = self.peek()
        self.offset += bool(value)
        return value

    def whitespace(self) -> None:
        while self.peek() in (b" ", b"\r", b"\n", b"\t"):
            self.offset += 1

    def retain(self, size: int) -> None:
        self.budget -= size
        if self.budget < 0:
            raise ValueError("usage projection exceeds its memory limit")

    def string(self, keep: bool, *, key: bool = False) -> tuple[str | None, bytes]:
        if self.take() != b'"':
            raise ValueError("expected JSON string")
        parts = bytearray(b'"')
        decoder = codecs.getincrementaldecoder("utf-8")()
        digest = hashlib.sha256(b"s")
        surrogate = ""
        # Unknown keys can themselves be huge. Validate, then forget them.
        key_limit = 256

        def hash_text(text: str, *, final: bool = False) -> None:
            nonlocal surrogate
            text = surrogate + text
            surrogate = ""
            if len(text) >= 2 and 0xD800 <= ord(text[0]) <= 0xDBFF and 0xDC00 <= ord(text[1]) <= 0xDFFF:
                text = chr(0x10000 + ((ord(text[0]) - 0xD800) << 10) + ord(text[1]) - 0xDC00) + text[2:]
            if text and not final and 0xD800 <= ord(text[-1]) <= 0xDBFF:
                surrogate, text = text[-1], text[:-1]
            digest.update(text.encode("utf-8", errors="surrogatepass"))

        def append(value: bytes) -> None:
            nonlocal keep
            if key and len(parts) + len(value) > key_limit:
                keep = False
                parts.clear()
            if keep:
                if not key:
                    self.retain(len(value))
                parts.extend(value)

        while self.peek():
            match = _STRING_SPECIAL.search(self.buffer, self.offset)
            end = match.start() if match else len(self.buffer)
            plain = self.buffer[self.offset:end]
            hash_text(decoder.decode(plain))
            append(plain)
            self.offset = end
            if not match:
                continue
            special = self.take()
            decoder.decode(b"", final=True)
            decoder.reset()
            if special == b'"':
                append(special)
                hash_text("", final=True)
                return (json.loads(parts) if keep else None), digest.digest()
            if special != b"\\":
                raise ValueError("control character in JSON string")
            escaped = self.take()
            if escaped == b"u":
                digits = b"".join(self.take() for _ in range(4))
                if len(digits) != 4 or any(c not in b"0123456789abcdefABCDEF" for c in digits):
                    raise ValueError("invalid unicode escape")
                append(special + escaped + digits)
                hash_text(chr(int(digits, 16)))
            elif escaped in (b'"', b"\\", b"/", b"b", b"f", b"n", b"r", b"t"):
                append(special + escaped)
                hash_text(json.loads(b'"' + special + escaped + b'"'))
            else:
                raise ValueError("invalid JSON escape")
        raise ValueError("unterminated JSON string")

    def value(self, fields: dict | None, depth: int = 0):
        self.values += 1
        if self.check_cancelled is not None and self.values % 1024 == 0:
            self.check_cancelled()
        if depth > 64:
            raise ValueError("JSON nesting exceeds its limit")
        self.whitespace()
        token = self.peek()
        if token == b'"':
            return self.string(fields is not None)
        if token in (b"{", b"["):
            self.take()
            is_object = token == b"{"
            closing = b"}" if is_object else b"]"
            # Arrays are not usage metadata; retain their type, never their items.
            result = {} if is_object else []
            fingerprints = {}
            array_digest = hashlib.sha256(b"a")
            retained = 0

            def finish():
                self.budget += retained
                digest = (hashlib.sha256(b"o" + b"".join(key + fingerprints[key] for key in sorted(fingerprints)))
                          if is_object else array_digest)
                return (result if fields is not None else None), digest.digest()

            self.whitespace()
            if self.peek() == closing:
                self.take()
                return finish()
            while True:
                self.whitespace()
                key, key_digest = self.string(fields is not None, key=True) if is_object else (None, None)
                if is_object:
                    self.whitespace()
                    if self.take() != b":":
                        raise ValueError("expected JSON colon")
                child = fields.get(key) if fields is not None and is_object else None
                value, digest = self.value(child, depth + 1)
                if is_object:
                    if key_digest not in fingerprints:
                        self.retain(64)
                        retained += 64
                    fingerprints[key_digest] = digest
                else:
                    array_digest.update(digest)
                if child is not None:
                    self.retain(1)
                    result[key] = value
                self.whitespace()
                separator = self.take()
                if separator == closing:
                    return finish()
                if separator != b",":
                    raise ValueError("expected JSON separator")
        raw = bytearray()
        while self.peek() and self.peek() not in (b" ", b"\r", b"\n", b"\t", b",", b"]", b"}"):
            raw.extend(self.take())
            if len(raw) > 1024:
                raise ValueError("JSON scalar exceeds its limit")
        if raw not in (b"null", b"true", b"false") and not _NUMBER.fullmatch(raw):
            raise ValueError("invalid JSON scalar")
        value = json.loads(raw)
        return (value if fields is not None else None), usage_fingerprint(value)

    def record(self) -> dict:
        result, self.fingerprint = self.value(_RECORD)
        self.whitespace()
        if self.peek() or not isinstance(result, dict):
            raise ValueError("expected one JSON object")
        return result
