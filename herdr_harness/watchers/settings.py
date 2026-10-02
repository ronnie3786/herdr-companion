"""Whether Watchers runs on this companion.

Configuration pins the value: HERDR_WATCHERS_ENABLED="1" or "0". Without it, a
person may turn Watchers on or off from a client, and the choice is kept in a
small private file under the companion's state directory.
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Mapping, Optional

ENVIRONMENT_KEY = "HERDR_WATCHERS_ENABLED"
PATH_KEY = "HERDR_HARNESS_WATCHERS_SETTINGS_PATH"
FILE_NAME = "watchers-settings.json"
MAXIMUM_BYTES = 4096
CHANGED_VIA_LIMIT = 40
LOCKED_MESSAGE = ("HERDR_WATCHERS_ENABLED is set in this companion's configuration. "
                  "Change it there and restart the companion.")
TURN_ON_HINT = ("A person can turn it on in the Mac app (Watchers → New watcher → Runs on) "
                "or with `herdr-watchers enable --i-confirm`.")


def configured(environ: Mapping[str, str]) -> Optional[bool]:
    """The configuration's pinned value, or None when the app may decide."""
    return {"1": True, "0": False}.get(environ.get(ENVIRONMENT_KEY))


def settings_path(environ: Mapping[str, str], *, home_default: bool) -> Optional[Path]:
    """Resolve the settings file like the Watchers store resolves its state.

    Without an explicit path or state directory, only a production service
    (home_default) falls back to the home state root. Test services built
    from a partial environment keep the setting in memory, so they never read
    or change a real machine's choice.
    """
    explicit = environ.get(PATH_KEY)
    if explicit:
        return Path(explicit).expanduser()
    state = environ.get("HERDR_STATE_DIR")
    if state:
        return Path(state).expanduser() / FILE_NAME
    if home_default:
        return Path(environ.get("HOME") or Path.home()) / ".local/share/herdr-companion" / FILE_NAME
    return None


def load(path: Optional[Path]) -> Optional[dict]:
    """Read a saved choice. A missing, oversized or malformed file is no choice."""
    if path is None:
        return None
    try:
        with open(path, "rb") as handle:
            raw = handle.read(MAXIMUM_BYTES + 1)
        if len(raw) > MAXIMUM_BYTES:
            return None
        value = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError, UnicodeError):
        return None
    if not isinstance(value, dict) or not isinstance(value.get("enabled"), bool):
        return None
    record = {"enabled": value["enabled"]}
    for key in ("changed_at", "changed_by", "changed_via"):
        if isinstance(value.get(key), str):
            record[key] = value[key]
    return record


def save(path: Path, record: dict) -> None:
    """Replace the file atomically with owner-only permissions."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".watchers-settings-", suffix=".tmp", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(record, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def remove(path: Optional[Path]) -> None:
    if path is not None:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def describe(environ: Mapping[str, str], record: Optional[dict]) -> dict:
    """The public `settings` object: effective value, where it comes from, and
    whether a client may change it."""
    pinned = configured(environ)
    if pinned is not None:
        return {"enabled": pinned, "source": "config", "changeable": False}
    if record is None:
        return {"enabled": False, "source": "default", "changeable": True}
    return {"enabled": record["enabled"], "source": "app", "changeable": True}


def disabled_message(settings: dict) -> str:
    if settings.get("source") == "config":
        return "Watchers is turned off on this companion. " + LOCKED_MESSAGE
    return "Watchers is off on this companion. " + TURN_ON_HINT
