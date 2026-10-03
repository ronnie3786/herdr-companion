"""Select the settled Main Chat answer from a durable Pi checkpoint."""
from __future__ import annotations


def settled_reply(snapshot: dict) -> tuple[str | None, list[str]] | None:
    """Match the client's final-answer text parts and question for cache reuse.

    Pi checkpoints after agent_settled, when the reply is persisted and idle.
    Intermediate turn checkpoints can contain a successful stop while the agent
    still has work queued, so a message's stop reason alone is not sufficient.
    """
    state = snapshot.get("state")
    if not isinstance(state, dict) or state.get("idle") is not True:
        return None
    if any(state.get(key) for key in ("working", "isStreaming", "isCompacting", "pendingMessages")):
        return None
    entries = snapshot.get("entries")
    if not isinstance(entries, list):
        return None

    # Only the latest turn is proactively skimmed. Reading an older answer can
    # still populate the bounded cache, without re-enqueueing whole histories
    # at every checkpoint or continually regenerating evicted cache entries.
    answer = None
    question = None
    trailing_notice = False
    for entry in reversed(entries):
        if not isinstance(entry, dict):
            continue
        if entry.get("type") != "message":
            if answer is None and entry.get("type") in {
                "compaction", "branch_summary", "model_change", "custom_message",
            }:
                trailing_notice = True
            continue
        message = entry.get("message")
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        if answer is None:
            if role not in {"assistant", "user", "toolResult", "tool_result"}:
                continue
            if role != "assistant":
                return None
            answer = message
        elif role == "user":
            question = _user_text(message.get("content"))
            break
    if answer is None:
        return None
    reason = answer.get("stopReason", answer.get("stop_reason"))
    if reason is not None and (not isinstance(reason, str) or reason.lower() != "stop"):
        return None
    # The native reader accepts a legacy missing reason only with literal
    # concluding output; an explicit stop can precede informational notices.
    if trailing_notice and reason is None:
        return None
    content = answer.get("content")
    if not isinstance(content, list) or any(
        isinstance(part, dict) and part.get("type") in {"toolCall", "tool_call"}
        for part in content
    ):
        return None
    replies = [part["text"] for part in content if isinstance(part, dict)
               and part.get("type") == "text" and isinstance(part.get("text"), str)
               and part["text"].strip()]
    return (question, replies) if replies else None


def _user_text(content: object) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    # PiConversationReducer uses this same image placeholder. No image data or
    # attachment metadata enters the skim prompt or content-addressed identity.
    parts = []
    for part in content:
        if not isinstance(part, dict):
            continue
        if part.get("type") == "text" and isinstance(part.get("text"), str):
            parts.append(part["text"])
        elif part.get("type") == "image":
            parts.append("[Image]")
    return "\n".join(parts)
