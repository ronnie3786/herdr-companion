"""Public, text-only projection of saved Pi messages for the agent viewer."""
from __future__ import annotations


def session_messages(rows: list[dict]) -> list[dict]:
    messages = []
    for row in rows:
        message = row.get("message")
        if not isinstance(message, dict) or message.get("role") not in {"user", "assistant", "toolResult"}:
            continue
        content = message.get("content", "")
        parts = content if isinstance(content, list) else []
        text = content if isinstance(content, str) else "\n".join(
            part["text"] for part in parts
            if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str))
        value = {"role": message["role"], "text": text,
                 "created_at": row.get("timestamp"), "index": len(messages)}
        if isinstance(row.get("id"), str):
            value["id"] = row["id"]
        if message["role"] == "assistant":
            value["tool_calls"] = [{"id": part.get("id", ""), "name": part.get("name", "tool"),
                                     "arguments": part.get("arguments", {})}
                                    for part in parts if isinstance(part, dict) and part.get("type") == "toolCall"]
            value["thinking"] = "\n".join(part["thinking"] for part in parts
                if isinstance(part, dict) and part.get("type") == "thinking" and isinstance(part.get("thinking"), str))
            value["stop_reason"] = message.get("stopReason")
        elif message["role"] == "toolResult":
            value["tool_call_id"] = message.get("toolCallId")
            value["tool_name"] = message.get("toolName")
            value["is_error"] = message.get("isError") is True
        messages.append(value)
    return messages


def session_page(path, native_session_id: str, *, before: int | None, limit: int, opener) -> dict:
    """Scan one retained transcript with page-sized memory and a fixed EOF.

    Counts and integer cursors keep their existing meaning. A growing file cannot
    extend this read indefinitely, and large tool payloads are not retained for
    every historical message merely to display one page.
    """
    from collections import deque
    import json
    import os
    import stat

    maximum = 4 * 1024 * 1024
    page = deque(maxlen=limit)
    total = 0
    boundary = None if before is None else max(0, int(before))
    with opener(path) as handle:
        metadata = os.fstat(handle.fileno())
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError('Saved First Mate session is not a regular file')
        remaining = metadata.st_size
        header = handle.readline(min(maximum + 1, remaining))
        remaining -= len(header)
        try:
            value = json.loads(header)
        except (ValueError, UnicodeError):
            value = None
        if (len(header) > maximum or not header.endswith(b'\n') or not isinstance(value, dict)
                or value.get('type') != 'session' or value.get('id') != native_session_id):
            raise ValueError('Saved session identity does not match the retained assignment')
        while remaining > 0:
            line = handle.readline(min(maximum + 1, remaining))
            if not line:
                break
            remaining -= len(line)
            if len(line) > maximum:
                while line and not line.endswith(b'\n') and remaining > 0:
                    line = handle.readline(min(maximum + 1, remaining))
                    remaining -= len(line)
                continue
            if not line.endswith(b'\n'):
                break
            try:
                row = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if not isinstance(row, dict):
                continue
            messages = session_messages([row])
            if messages:
                message = messages[0]
                message['index'] = total
                if boundary is None or total < boundary:
                    page.append(message)
                total += 1
        # Reject replacement, shrink or a changed header rather than attaching
        # messages to a different session after an in-place rewrite. Appends may
        # continue; the page above is bounded to the original observed EOF.
        after = os.fstat(handle.fileno())
        handle.seek(0)
        current_header = handle.readline(maximum + 1)
        current = path.stat()
        if (current_header != header or after.st_size < metadata.st_size
                or (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino)
                or (after.st_size == metadata.st_size and
                    (after.st_mtime_ns, after.st_ctime_ns) != (metadata.st_mtime_ns, metadata.st_ctime_ns))):
            raise ValueError('Saved First Mate session changed while being read; retry the request')
    end = total if boundary is None else min(total, boundary)
    start = max(0, end - limit)
    return {'messages': list(page), 'total_messages': total, 'next_before': start or None}
