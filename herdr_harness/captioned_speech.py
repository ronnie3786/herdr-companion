"""Captioned Kokoro recordings and exact-media drawing cues for native PR review.

The existing private TTS configuration owns the provider. Neither endpoints nor
provider errors containing request text enter the public client contract.
"""
from __future__ import annotations

import base64
import hashlib
import io
import json
import math
import re
import threading
import time
import urllib.request
import wave
from collections import OrderedDict
from typing import Any

from .response_audio import MAX_AUDIO_BYTES, MAX_CHUNK_CHARACTERS, ResponseAudioError, ResponseAudioService

COMPILER_VERSION = 1
MAX_CUES = 24
MAX_CACHE_BYTES = 24 * 1024 * 1024


def _tokens(text: str) -> list[str]:
    # English is the validated provider alignment scope, matching the prototype.
    return re.findall(r"[a-z0-9]+", text.lower())


def _finite(value: Any) -> bool:
    return type(value) in (int, float) and math.isfinite(value)


def _invalid(message: str) -> ResponseAudioError:
    return ResponseAudioError(message, code="invalid_captioned_speech", status=400)


def validate_cues(cues: Any) -> list[dict[str, Any]]:
    if not isinstance(cues, list) or len(cues) > MAX_CUES:
        raise _invalid("Narration needs at most 24 drawing cues")
    ids: set[str] = set()
    for cue in cues:
        if not isinstance(cue, dict):
            raise _invalid("Drawing cue must be an object")
        identifier = cue.get("id")
        if not isinstance(identifier, str) or not identifier.strip() or len(identifier) > 200 or identifier in ids:
            raise _invalid("Drawing cue IDs must be nonempty and unique")
        ids.add(identifier)
        if cue.get("shape") not in {"circle", "underline", "arrow", "highlight"}:
            raise _invalid("Unsupported drawing shape")
        targets = cue.get("targets")
        if not isinstance(targets, list) or len(targets) != (2 if cue["shape"] == "arrow" else 1):
            raise _invalid("Invalid drawing target count")
        for target in targets:
            if not isinstance(target, dict):
                raise _invalid("Drawing target must be an object")
            path = target.get("path")
            if (not isinstance(path, str) or not path or len(path) > 4096 or path.startswith("/")
                    or ".." in path.split("/") or "\\" in path or any(ord(c) < 32 for c in path)):
                raise _invalid("Drawing target needs a repository-relative path")
            if target.get("side") not in {"before", "after"}:
                raise _invalid("Drawing target needs a before or after side")
            start, end = target.get("startLine"), target.get("endLine")
            if type(start) is not int or type(end) is not int or not 1 <= start <= end <= 10_000_000:
                raise _invalid("Drawing target needs a valid line range")
        if len({target["path"] for target in targets}) != 1:
            raise _invalid("An arrow must remain in one file")
        phrase = cue.get("onPhrase")
        if not isinstance(phrase, str) or not _tokens(phrase) or len(phrase) > 500:
            raise _invalid("Drawing cue needs a spoken phrase")
        for key, phrase_key in (("occurrence", "onPhrase"), ("untilOccurrence", "untilPhrase")):
            value = cue.get(key)
            if value is not None and (type(value) is not int or value < 1 or not cue.get(phrase_key)):
                raise _invalid("Phrase occurrence must be a positive integer")
        if cue.get("untilPhrase") is not None and (
            not isinstance(cue["untilPhrase"], str) or not _tokens(cue["untilPhrase"]) or len(cue["untilPhrase"]) > 500
        ):
            raise _invalid("Drawing expiry needs a spoken phrase")
        if cue.get("drawSeconds") is not None and (not _finite(cue["drawSeconds"]) or not 0 < cue["drawSeconds"] <= 5):
            raise _invalid("Drawing duration must be between zero and five seconds")
        if cue.get("label") is not None and (not isinstance(cue["label"], str) or len(cue["label"]) > 500):
            raise _invalid("Invalid drawing label")
    return cues


def _phrase_matches(tokens: list[str], wanted: list[str]) -> list[int]:
    return [i for i in range(len(tokens) - len(wanted) + 1) if tokens[i:i + len(wanted)] == wanted]


def locate_phrase(words: list[dict[str, Any]], script: str, phrase: str, occurrence: int | None = None) -> float:
    wanted = _tokens(phrase)
    flattened = [(token, word["start"]) for word in words for token in _tokens(word["word"])]
    source_matches = _phrase_matches(_tokens(script), wanted)
    matches = _phrase_matches([token for token, _ in flattened], wanted)
    if not wanted or not matches or len(matches) != len(source_matches):
        raise ValueError("Phrase does not align with the recording")
    if occurrence is None and len(matches) != 1:
        raise ValueError("Repeated phrase needs an occurrence")
    index = (occurrence or 1) - 1
    if not 0 <= index < len(matches):
        raise ValueError("Phrase occurrence is missing")
    return flattened[matches[index]][1]


def compile_cues(cues: list[dict[str, Any]], words: list[dict[str, Any]], script: str, duration: float) -> tuple[list[dict[str, Any]], list[str]]:
    """A bad drawing must not discard an otherwise usable spoken explanation."""
    compiled, rejected = [], []
    for cue in validate_cues(cues):
        try:
            onset = locate_phrase(words, script, cue["onPhrase"], cue.get("occurrence"))
            draw = cue.get("drawSeconds") or 0.7
            until = (locate_phrase(words, script, cue["untilPhrase"], cue.get("untilOccurrence"))
                     if cue.get("untilPhrase") else None)
            if not 0 <= onset < duration or onset + draw > duration + 0.00001:
                raise ValueError("Drawing exceeds recording")
            if until is not None and not onset + draw <= until <= duration:
                raise ValueError("Drawing expiry precedes its completed stroke")
            compiled.append({"id": cue["id"], "shape": cue["shape"], "targets": cue["targets"],
                             "onset": onset, "drawSeconds": draw, "until": until, "label": cue.get("label")})
        except ValueError:
            rejected.append(cue["id"])
    return sorted(compiled, key=lambda cue: cue["onset"]), rejected


def normalize_wave(audio: bytes) -> tuple[bytes, float]:
    """Measure actual PCM samples, including Kokoro's unfinalized streaming WAVs."""
    try:
        with wave.open(io.BytesIO(audio), "rb") as source:
            channels, width, rate = source.getnchannels(), source.getsampwidth(), source.getframerate()
            if channels not in (1, 2) or width not in (1, 2, 3, 4) or not 8_000 <= rate <= 192_000:
                raise ValueError("Unsupported audio format")
            pcm = source.readframes(MAX_AUDIO_BYTES // (channels * width) + 1)
        if not pcm or len(pcm) % (channels * width) or len(pcm) > MAX_AUDIO_BYTES:
            raise ValueError("Invalid audio sample count")
        duration = len(pcm) / (channels * width * rate)
        if not 0 < duration <= 240:
            raise ValueError("Narration exceeds segment duration limit")
        output = io.BytesIO()
        with wave.open(output, "wb") as target:
            target.setnchannels(channels)
            target.setsampwidth(width)
            target.setframerate(rate)
            target.writeframes(pcm)
        return output.getvalue(), duration
    except (wave.Error, EOFError, OSError, ValueError) as exc:
        raise ResponseAudioError("Captioned speech returned an invalid WAV recording") from exc


def normalize_words(raw: Any, duration: float) -> list[dict[str, Any]]:
    if not isinstance(raw, list) or not raw or len(raw) > 10_000:
        raise ResponseAudioError("Captioned speech did not return word timings")
    words: list[dict[str, Any]] = []
    previous_start = 0.0
    for item in raw:
        if not isinstance(item, dict) or not isinstance(item.get("word"), str):
            raise ResponseAudioError("Captioned speech returned invalid word timings")
        if not _tokens(item["word"]):
            continue  # Punctuation-only provider pauses are not spoken anchors.
        start, end = item.get("start_time"), item.get("end_time")
        if not _finite(start) or not _finite(end) or not -0.1 <= start <= end <= duration + 0.1:
            raise ResponseAudioError("Captioned speech word timing exceeds the recording")
        start, end = max(0.0, start), min(duration, end)
        if start < previous_start or end < start:
            raise ResponseAudioError("Captioned speech word timings are not ordered")
        previous_start = start
        words.append({"word": item["word"], "start": start, "end": end})
    if not words:
        raise ResponseAudioError("Captioned speech did not return spoken word timings")
    return words


class CaptionedSpeechService:
    def __init__(self, response_audio: ResponseAudioService) -> None:
        self.audio = response_audio
        self.base = response_audio.tts_endpoint.removesuffix("/v1/audio/speech") if response_audio.tts_endpoint else None
        self._lock = threading.Lock()
        self._capabilities: dict[str, Any] | None = None
        self._expires = 0.0
        self._cache: OrderedDict[str, dict[str, Any]] = OrderedDict()
        self._cache_bytes = 0

    def _json(self, path: str, *, payload: dict[str, Any] | None = None, maximum: int = 4 * 1024 * 1024) -> dict[str, Any]:
        request = urllib.request.Request(
            self.base + path, data=json.dumps(payload).encode() if payload is not None else None,
            headers={"Accept": "application/json", "Content-Type": "application/json"},
            method="POST" if payload is not None else "GET",
        )
        raw = self.audio._open_bytes(request, timeout=120 if payload is not None else 3, maximum=maximum)
        try:
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise ValueError()
            return value
        except (ValueError, UnicodeError) as exc:
            raise ResponseAudioError("Captioned speech returned an invalid response") from exc

    def capabilities(self, *, force: bool = False) -> dict[str, Any]:
        with self._lock:
            if not force and self._capabilities is not None and time.monotonic() < self._expires:
                return dict(self._capabilities)
        voices: list[str] = []
        available = False
        if self.base and self.audio.enabled:
            try:
                schema = self._json("/openapi.json")
                available = "post" in schema.get("paths", {}).get("/dev/captioned_speech", {})
                raw_voices = self._json("/v1/audio/voices").get("voices", [])
                voices = [v if isinstance(v, str) else v.get("id", "") for v in raw_voices if isinstance(v, (str, dict))]
                voices = [v for v in voices if isinstance(v, str) and re.fullmatch(r"[ab][fm]_[a-z0-9_]+", v)]
                available = available and bool(voices)
            except (ResponseAudioError, TypeError, ValueError):
                available = False
        result = {"ok": True, "available": available, "voices": voices,
                  "default_voice": self.audio.voice if self.audio.voice in voices else (voices[0] if voices else ""),
                  "alignment": "kokoro-word-timestamps", "version": COMPILER_VERSION}
        if not available:
            result["reason"] = "Captioned narration is unavailable. You can keep reading the walkthrough."
        with self._lock:
            self._capabilities, self._expires = result, time.monotonic() + 30
        return dict(result)

    def synthesize(self, *, text: str, voice: str | None = None, cues: Any = None) -> dict[str, Any]:
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_CHUNK_CHARACTERS:
            raise _invalid("Narration text must contain 1 to 5000 characters")
        cues = validate_cues([] if cues is None else cues)
        capabilities = self.capabilities()
        if not capabilities["available"]:
            return {"ok": True, "available": False, "script": text, "voice": voice or self.audio.voice,
                    "cues": [], "words": [], "reason": capabilities["reason"]}
        voice = voice or capabilities["default_voice"]
        if not isinstance(voice, str) or voice not in capabilities["voices"]:
            raise _invalid("The selected narration voice is unavailable")
        key = hashlib.sha256(json.dumps([COMPILER_VERSION, text, voice, self.audio.speed], ensure_ascii=False).encode()).hexdigest()
        with self._lock:
            recording = self._cache.get(key)
            if recording is not None:
                self._cache.move_to_end(key)
        if recording is None:
            result = self._json("/dev/captioned_speech", payload={
                "model": "kokoro", "input": text, "voice": voice, "response_format": "wav",
                "speed": self.audio.speed, "stream": False, "return_timestamps": True, "return_download_link": False,
            }, maximum=MAX_AUDIO_BYTES * 2)
            try:
                raw_audio = base64.b64decode(result.get("audio", ""), validate=True)
            except (ValueError, TypeError) as exc:
                raise ResponseAudioError("Captioned speech returned invalid audio data") from exc
            if len(raw_audio) > MAX_AUDIO_BYTES:
                raise ResponseAudioError("Captioned speech recording is too large")
            audio, duration = normalize_wave(raw_audio)
            words = normalize_words(result.get("timestamps"), duration)
            recording = {"ok": True, "available": True, "version": COMPILER_VERSION,
                         "alignment": "kokoro-word-timestamps", "script": text, "voice": voice,
                         "script_sha256": hashlib.sha256(text.encode()).hexdigest(),
                         "audio_sha256": hashlib.sha256(audio).hexdigest(),
                         "audio_base64": base64.b64encode(audio).decode(), "content_type": "audio/wav",
                         "duration": duration, "words": words}
            size = len(recording["audio_base64"])
            with self._lock:
                if key not in self._cache:
                    self._cache[key] = recording
                    self._cache_bytes += size
                while self._cache and (self._cache_bytes > MAX_CACHE_BYTES or len(self._cache) > 8):
                    _, old = self._cache.popitem(last=False)
                    self._cache_bytes -= len(old["audio_base64"])
        compiled, rejected = compile_cues(cues, recording["words"], text, recording["duration"])
        return {**recording, "cues": compiled, "rejected_cues": rejected}
