"""Minimal RFC 6455 framing for relaying one WebSocket to another.

The companion's HTTP server is the standard library's, which has no WebSocket
support. The simulator stream needs exactly two roles: accepting an upgraded
connection from a native client, and dialing SimPortal's viewer socket with the
service credential in a header. Both are blocking and thread-per-direction;
message size is bounded on every read, and a lock serializes writes so control
replies never interleave with relayed frames.
"""
from __future__ import annotations

import base64
import hashlib
import os
import socket
import ssl
import struct
import threading
import urllib.parse
from typing import Any, BinaryIO, Mapping

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
OP_CONTINUATION, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA
MAX_HANDSHAKE_BYTES = 16 * 1024
MAX_FRAGMENTS = 1024


class WebSocketClosed(Exception):
    """The peer closed the connection or the socket ended."""


class WebSocketProtocolError(Exception):
    """The peer sent something this relay will not accept."""


def accept_value(key: str) -> str:
    return base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")


def upgrade_key(headers: Mapping[str, str] | Any) -> str | None:
    """The client's Sec-WebSocket-Key when the request is a valid upgrade."""

    def header(name: str) -> str:
        value = headers.get(name) if hasattr(headers, "get") else None
        return str(value or "")

    if "websocket" not in header("Upgrade").lower():
        return None
    if "upgrade" not in [part.strip().lower() for part in header("Connection").split(",")]:
        return None
    if header("Sec-WebSocket-Version").strip() != "13":
        return None
    key = header("Sec-WebSocket-Key").strip()
    try:
        if len(base64.b64decode(key, validate=True)) != 16:
            return None
    except (ValueError, TypeError):
        return None
    return key


def valid_close_code(code: int) -> bool:
    """Codes an endpoint may send (RFC 6455 section 7.4)."""

    return 1000 <= code <= 1003 or 1007 <= code <= 1011 or 3000 <= code <= 4999


class FrameSocket:
    """Blocking message reader/writer over one connected stream."""

    def __init__(self, sock: socket.socket, reader: BinaryIO, *, client: bool, max_message: int) -> None:
        self.sock = sock
        self.reader = reader
        self.client = client
        self.max_message = max_message
        self._write_lock = threading.Lock()
        self._closed = False
        # The close code the peer sent, if any, so a relay can pass it on.
        self.peer_close_code: int | None = None

    def _read_exact(self, count: int) -> bytes:
        if count == 0:
            return b""
        try:
            data = self.reader.read(count)
        except (OSError, ValueError) as exc:
            raise WebSocketClosed("socket read failed") from exc
        if data is None or len(data) < count:
            raise WebSocketClosed("socket ended")
        return data

    def _read_frame(self) -> tuple[bool, int, bytes]:
        first, second = self._read_exact(2)
        if first & 0x70:
            raise WebSocketProtocolError("reserved bits are not supported")
        fin, opcode = bool(first & 0x80), first & 0x0F
        masked, length = bool(second & 0x80), second & 0x7F
        if length == 126:
            (length,) = struct.unpack("!H", self._read_exact(2))
        elif length == 127:
            (length,) = struct.unpack("!Q", self._read_exact(8))
        if opcode >= 0x8 and (length > 125 or not fin):
            raise WebSocketProtocolError("invalid control frame")
        if length > self.max_message:
            raise WebSocketProtocolError("message too big")
        # Clients must mask; servers must not. Accept only the side's rule.
        if masked == self.client:
            raise WebSocketProtocolError("unexpected masking")
        mask = self._read_exact(4) if masked else b""
        payload = self._read_exact(length)
        if masked:
            payload = _unmask(payload, mask)
        return fin, opcode, payload

    def receive(self) -> tuple[int, bytes]:
        """The next data message, answering pings; raises WebSocketClosed at close."""

        fragments: list[bytes] = []
        message_opcode = 0
        total = 0
        while True:
            fin, opcode, payload = self._read_frame()
            if opcode == OP_PING:
                self.send(OP_PONG, payload)
                continue
            if opcode == OP_PONG:
                continue
            if opcode == OP_CLOSE:
                code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None
                self.peer_close_code = code if code is not None and valid_close_code(code) else None
                self.close(code=self.peer_close_code or 1000)
                raise WebSocketClosed("peer closed")
            if opcode == OP_CONTINUATION:
                if not fragments:
                    raise WebSocketProtocolError("unexpected continuation")
            elif opcode in {OP_TEXT, OP_BINARY}:
                if fragments:
                    raise WebSocketProtocolError("interleaved message")
                message_opcode = opcode
            else:
                raise WebSocketProtocolError("unknown opcode")
            total += len(payload)
            if total > self.max_message:
                raise WebSocketProtocolError("message too big")
            if len(fragments) >= MAX_FRAGMENTS:
                raise WebSocketProtocolError("too many fragments")
            fragments.append(payload)
            if fin:
                return message_opcode, b"".join(fragments)

    def send(self, opcode: int, payload: bytes) -> None:
        header = bytearray([0x80 | opcode])
        mask_bit = 0x80 if self.client else 0
        length = len(payload)
        if length < 126:
            header.append(mask_bit | length)
        elif length < 65536:
            header.append(mask_bit | 126)
            header += struct.pack("!H", length)
        else:
            header.append(mask_bit | 127)
            header += struct.pack("!Q", length)
        if self.client:
            mask = os.urandom(4)
            header += mask
            payload = _unmask(payload, mask)
        with self._write_lock:
            if self._closed:
                raise WebSocketClosed("socket closed")
            try:
                if length < 65536:
                    self.sock.sendall(bytes(header) + payload)
                else:
                    self.sock.sendall(bytes(header))
                    self.sock.sendall(payload)
            except OSError as exc:
                self._closed = True
                raise WebSocketClosed("socket write failed") from exc

    def send_text(self, text: str) -> None:
        self.send(OP_TEXT, text.encode("utf-8"))

    def close(self, code: int = 1000, reason: str = "") -> None:
        with self._write_lock:
            if self._closed:
                return
            self._closed = True
        try:
            body = struct.pack("!H", code) + reason.encode("utf-8")[:120]
            frame = bytearray([0x80 | OP_CLOSE])
            if self.client:
                mask = os.urandom(4)
                frame += bytes([0x80 | len(body)]) + mask + _unmask(body, mask)
            else:
                frame += bytes([len(body)]) + body
            self.sock.sendall(bytes(frame))
        except OSError:
            pass

    def shutdown(self) -> None:
        """Unblocks a reader on another thread; the owner still closes the socket."""

        with self._write_lock:
            self._closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def _unmask(payload: bytes, mask: bytes) -> bytes:
    if not payload:
        return b""
    # XOR 8 bytes at a time: video keyframes can be several megabytes.
    repeated = (mask * ((len(payload) + 3) // 4))[: len(payload)]
    return (int.from_bytes(payload, "big") ^ int.from_bytes(repeated, "big")).to_bytes(len(payload), "big")


def dial(origin: str, path: str, *, headers: Mapping[str, str], timeout: float,
         max_message: int, ssl_context: ssl.SSLContext | None = None) -> FrameSocket:
    """Open a client WebSocket to ``origin`` + ``path`` (no redirects, no proxy)."""

    parsed = urllib.parse.urlsplit(origin)
    secure = parsed.scheme == "https"
    host = parsed.hostname or ""
    port = parsed.port or (443 if secure else 80)
    raw = socket.create_connection((host, port), timeout=timeout)
    try:
        sock: socket.socket = raw
        if secure:
            context = ssl_context or ssl.create_default_context()
            sock = context.wrap_socket(raw, server_hostname=host)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        host_header = parsed.netloc.rsplit("@", 1)[-1]
        lines = [f"GET {path} HTTP/1.1", f"Host: {host_header}", "Upgrade: websocket", "Connection: Upgrade",
                 f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"]
        lines += [f"{name}: {value}" for name, value in headers.items()]
        sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
        reader = sock.makefile("rb")
        status_line = reader.readline(MAX_HANDSHAKE_BYTES)
        parts = status_line.decode("latin-1").split(" ", 2)
        status = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0
        response_headers: dict[str, str] = {}
        consumed = len(status_line)
        while True:
            line = reader.readline(MAX_HANDSHAKE_BYTES)
            consumed += len(line)
            if consumed > MAX_HANDSHAKE_BYTES or not line:
                raise WebSocketProtocolError("handshake response is invalid")
            if line in {b"\r\n", b"\n"}:
                break
            name, _, value = line.decode("latin-1").partition(":")
            response_headers[name.strip().lower()] = value.strip()
        if status != 101:
            raise HandshakeRejected(status)
        if response_headers.get("sec-websocket-accept") != accept_value(key):
            raise WebSocketProtocolError("handshake accept value is invalid")
        return FrameSocket(sock, reader, client=True, max_message=max_message)
    except BaseException:
        try:
            raw.close()
        except OSError:
            pass
        raise


class HandshakeRejected(WebSocketProtocolError):
    def __init__(self, status: int) -> None:
        super().__init__(f"upgrade rejected with HTTP {status}")
        self.status = status
