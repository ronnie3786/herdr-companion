"""Recorded speech validation and direct, explicitly configured transcription."""

from __future__ import annotations

import struct

# The iOS recorder produces mono 16 kHz, 16-bit WAV. Ten minutes is about
# 19.2 MB, so this keeps the existing long-form recorder while putting a hard
# ceiling on every hop of the transcription pipeline.
MAX_VOICE_AUDIO_BYTES = 20 * 1024 * 1024
MAX_VOICE_JSON_BYTES = 29 * 1024 * 1024
MAX_TRANSCRIPT_CHARACTERS = 131_072
VOICE_SAMPLE_RATE = 16_000
VOICE_CHANNEL_COUNT = 1
VOICE_BITS_PER_SAMPLE = 16
MAX_VOICE_DURATION_SECONDS = 10 * 60


class VoiceError(ValueError):
    def __init__(
        self,
        message: str,
        *,
        code: str = "invalid_voice_recording",
        status: int = 400,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


def validate_voice_wav(data: bytes) -> None:
    """Validate the exact bounded PCM format emitted by the iOS recorder."""

    if not isinstance(data, bytes) or len(data) < 44:
        raise VoiceError("recording must be a valid WAV file")
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise VoiceError("recording must be a valid WAV file")
    declared_size = struct.unpack_from("<I", data, 4)[0] + 8
    if declared_size != len(data):
        raise VoiceError("recording WAV size is invalid")

    offset = 12
    format_values = None
    data_bytes = None
    while offset + 8 <= len(data):
        chunk_id = data[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", data, offset + 4)[0]
        payload_start = offset + 8
        payload_end = payload_start + chunk_size
        if payload_end > len(data):
            raise VoiceError("recording WAV chunks are invalid")
        if chunk_id == b"fmt " and format_values is None:
            if chunk_size < 16:
                raise VoiceError("recording WAV format is invalid")
            format_values = struct.unpack_from("<HHIIHH", data, payload_start)
        elif chunk_id == b"data" and data_bytes is None:
            data_bytes = chunk_size
        offset = payload_end + (chunk_size & 1)

    if offset != len(data) or format_values is None or not data_bytes:
        raise VoiceError("recording WAV chunks are invalid")

    audio_format, channels, sample_rate, byte_rate, block_align, bits = format_values
    expected_block_align = VOICE_CHANNEL_COUNT * (VOICE_BITS_PER_SAMPLE // 8)
    expected_byte_rate = VOICE_SAMPLE_RATE * expected_block_align
    if (
        audio_format != 1
        or channels != VOICE_CHANNEL_COUNT
        or sample_rate != VOICE_SAMPLE_RATE
        or byte_rate != expected_byte_rate
        or block_align != expected_block_align
        or bits != VOICE_BITS_PER_SAMPLE
        or data_bytes % block_align != 0
        or data_bytes / byte_rate > MAX_VOICE_DURATION_SECONDS
    ):
        raise VoiceError("recording must be mono 16 kHz, 16-bit PCM WAV")


MAX_TRANSCRIPTION_RESPONSE_BYTES = 512 * 1024


def transcribe(*, filename: str, mime_type: str, data: bytes, environ=None) -> dict:
    """Send audio directly to a configured Parakeet or OpenAI-compatible endpoint.

    No endpoint is contacted until explicitly configured. Never follow redirects
    or expose provider error bodies, which can contain credentials or recordings.
    """
    import http.client
    import json
    import os
    import re
    import socket
    import urllib.error
    import urllib.parse
    import urllib.request
    import uuid

    if not isinstance(data, bytes) or not data:
        raise VoiceError("recording is empty")
    if len(data) > MAX_VOICE_AUDIO_BYTES:
        raise VoiceError("recording exceeds the 20 MB limit", code="voice_recording_too_large", status=413)
    validate_voice_wav(data)
    if not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,119}\.wav", filename, re.IGNORECASE):
        raise VoiceError("recording filename is invalid")
    if not isinstance(mime_type, str) or mime_type.lower().split(";", 1)[0].strip() not in {"audio/wav", "audio/x-wav", "audio/wave"}:
        raise VoiceError("recording must use a WAV content type")
    env = os.environ if environ is None else environ
    endpoint = str(env.get("HERDR_HARNESS_TRANSCRIPTION_URL") or "").strip()
    if not endpoint:
        raise VoiceError("Configure a transcription provider in your Herdr local configuration", code="transcription_not_configured", status=503)
    try:
        parsed = urllib.parse.urlsplit(endpoint)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or any(ord(c) < 33 for c in endpoint):
            raise ValueError()
        if parsed.port is not None and not 1 <= parsed.port <= 65535:
            raise ValueError()
    except ValueError as exc:
        raise VoiceError("Transcription endpoint is invalid", code="transcription_configuration_invalid", status=503) from exc
    backend = str(env.get("HERDR_HARNESS_TRANSCRIPTION_BACKEND") or "openai").strip()
    if backend not in {"openai", "parakeet"}:
        raise VoiceError("Transcription backend must be openai or parakeet", code="transcription_configuration_invalid", status=503)
    model = str(env.get("HERDR_HARNESS_TRANSCRIPTION_MODEL") or "").strip()
    if backend == "openai" and not model:
        raise VoiceError("Configure a transcription model", code="transcription_configuration_invalid", status=503)
    token = str(env.get("HERDR_HARNESS_TRANSCRIPTION_TOKEN") or "").strip()
    if any(ord(c) < 32 for c in token) or len(token) > 8192 or len(model) > 256 or any(ord(c) < 32 for c in model):
        raise VoiceError("Transcription configuration is invalid", code="transcription_configuration_invalid", status=503)
    boundary = uuid.uuid4().hex
    field = "audio" if backend == "parakeet" else "file"
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; filename="{filename}"\r\nContent-Type: audio/wav\r\n\r\n'.encode() + data + b"\r\n")
    if model:
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n{model}\r\n'.encode()
    body += f"--{boundary}--\r\n".encode()
    headers = {"Content-Type": f"multipart/form-data; boundary={boundary}", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(endpoint, data=body, headers=headers, method="POST")

    class RejectRedirects(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, fp, code, msg, headers, newurl):
            return None

    try:
        with urllib.request.build_opener(RejectRedirects()).open(request, timeout=90) as response:
            length = response.headers.get("Content-Length")
            if length is not None:
                try:
                    size = int(length)
                except ValueError as exc:
                    raise VoiceError("Transcription returned an invalid response", code="transcription_invalid_response", status=502) from exc
                if size < 0 or size > MAX_TRANSCRIPTION_RESPONSE_BYTES:
                    raise VoiceError("Transcription response exceeds the size limit", code="transcription_response_too_large", status=502)
            encoded = response.read(MAX_TRANSCRIPTION_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        exc.close()
        raise VoiceError("Transcription provider rejected the request", code="transcription_provider_error", status=502) from exc
    except (socket.timeout, TimeoutError) as exc:
        raise VoiceError("Transcription timed out", code="transcription_timeout", status=504) from exc
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, (socket.timeout, TimeoutError)):
            raise VoiceError("Transcription timed out", code="transcription_timeout", status=504) from exc
        raise VoiceError("Transcription provider is unavailable", code="transcription_unavailable", status=503) from exc
    except (OSError, http.client.HTTPException) as exc:
        raise VoiceError("Transcription provider is unavailable", code="transcription_unavailable", status=503) from exc
    if len(encoded) > MAX_TRANSCRIPTION_RESPONSE_BYTES:
        raise VoiceError("Transcription response exceeds the size limit", code="transcription_response_too_large", status=502)
    try:
        payload = json.loads(encoded)
    except (ValueError, UnicodeError) as exc:
        raise VoiceError("Transcription returned invalid JSON", code="transcription_invalid_response", status=502) from exc
    text = payload.get("text") if isinstance(payload, dict) else None
    language = payload.get("language") if isinstance(payload, dict) else None
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TRANSCRIPT_CHARACTERS or (language is not None and (not isinstance(language, str) or len(language) > 64)):
        raise VoiceError("Transcription returned an invalid transcript", code="transcription_invalid_response", status=502)
    return {"ok": True, "text": text.strip(), "backend": backend, "language": language}
