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
