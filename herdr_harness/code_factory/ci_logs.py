"""Bounded CI diagnostics that retain failures before a long test-suite tail."""

from __future__ import annotations

import re

MAX_LOG_CHARS = 16_000
# Avoid generic macOS runtime "error:" noise. Prefer test failures and compiler
# locations, which identify something the revision session can actually fix.
_DIAGNOSTIC = re.compile(
    r"recorded an issue|expectation failed|assertion failed|assertionerror:"
    r"|^(?-i:FAIL|ERROR):\s|^(?-i:FAILED)\s+\S+"
    r"|Test Case [\'\"].+[\'\"] failed|\.(?:swift|[cmh]|cpp|m[m]?):\d+(?::\d+)?: (?:fatal )?error:"
    r"|Traceback \(most recent call last\):",
    re.IGNORECASE,
)


def failed_log_excerpt(text: str) -> str:
    """Keep diagnostic context across jobs, plus a tail, within the prompt budget.

    Repeated diagnostics do not monopolize the budget. Round-robin selection by
    GitHub job name ensures that a noisy Mac job cannot hide a portable failure.
    Logs without recognized diagnostics retain the existing tail fallback.
    """
    if len(text) <= MAX_LOG_CHARS:
        return text
    lines = text.splitlines()
    groups: dict[str, list[str]] = {}
    seen: set[tuple[str, str]] = set()
    for index, line in enumerate(lines):
        # gh prefixes each payload with job, step and an ISO timestamp.
        payload = line.split("\t", 2)[-1]
        payload = re.sub(r"^\d{4}-\d{2}-\d{2}T\S+\s+", "", payload)
        match = _DIAGNOSTIC.search(payload)
        if match is None:
            continue
        job = line.split("\t", 1)[0] if "\t" in line else "log"
        key = (job, payload[match.start():])
        if key in seen:
            continue
        seen.add(key)
        # Keep the diagnostic first even if the preceding line is enormous.
        context = "\n".join(lines[index + 1:index + 5])
        block = f"[log line {index + 1}] {line[:1600]}\n{context[:1000]}\n"
        groups.setdefault(job, []).append(block)
    if not groups:
        return text[-MAX_LOG_CHARS:]
    tail = "\n[Log tail]\n" + text[-2000:]
    result = "[Selected failure diagnostics; other log lines omitted]\n"
    budget = MAX_LOG_CHARS - len(tail)
    queues = list(groups.values())
    offset = 0
    while any(offset < len(queue) for queue in queues) and len(result) < budget:
        for queue in queues:
            if offset < len(queue):
                result += queue[offset][:budget - len(result)]
        offset += 1
    return result + tail
