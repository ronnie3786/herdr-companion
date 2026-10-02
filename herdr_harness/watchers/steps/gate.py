"""Pure gates; proposed cursors are committed only by a successful run."""
from __future__ import annotations

import hashlib
import json

from ..errors import WatchersError

CURSOR_LIMIT = 5000


def evaluate(rule, content, cursor=None):
    """Return (passed, output bytes, proposed cursor), without writing state."""
    raw = content.encode() if isinstance(content, str) else content
    if rule['kind'] == 'changed':
        candidate = {'sha256': hashlib.sha256(raw).hexdigest()}
        return candidate != cursor, raw, candidate
    try:
        items = json.loads(raw)
    except (ValueError, UnicodeError) as exc:
        raise WatchersError('gate_input_invalid', 'The check needs JSON from its input step') from exc
    if isinstance(items, dict):
        items = items.get('items')
    if not isinstance(items, list):
        raise WatchersError('gate_input_invalid', 'The check needs a JSON array or an object with an items array')
    key_field, version_field = rule.get('key', 'id'), rule.get('version')
    previous = {entry['key']: entry.get('version') for entry in (cursor or {}).get('keys', [])}
    incoming = {}
    for item in items:
        if not isinstance(item, dict) or key_field not in item:
            raise WatchersError('gate_input_invalid', f"Every item needs the check key {key_field}")
        key = json.dumps(item[key_field], sort_keys=True, separators=(',', ':'), allow_nan=False)
        version = item.get(version_field) if version_field else None
        if version_field and version_field not in item:
            raise WatchersError('gate_input_invalid', f"Every item needs the check version {version_field}")
        incoming[key] = (item, version)
    new = [item for key, (item, version) in incoming.items() if key not in previous or previous[key] != version]
    for key, (_, version) in incoming.items():
        previous.pop(key, None)
        previous[key] = version
    candidate = {'keys': [{'key': key, 'version': version} for key, version in list(previous.items())[-CURSOR_LIMIT:]]}
    return bool(new), json.dumps(new, ensure_ascii=False, separators=(',', ':')).encode(), candidate
