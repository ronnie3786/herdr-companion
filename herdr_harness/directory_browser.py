"""Bounded, read-only directory discovery on the companion's own machine.

Paths are filesystem data, never shell commands. This API is for the fully
authenticated operator and exposes no file contents or recursive traversal.
"""
from __future__ import annotations

import base64
import errno
import hashlib
import json
import os
import stat
import time
from pathlib import Path


DIRECTORY_CAPABILITY = "directory-browser-v1"
PAGE_SIZE = 100
MAX_SCAN_ENTRIES = 20_000
MAX_SCAN_SECONDS = 3.0


class DirectoryBrowserError(RuntimeError):
    def __init__(self, message: str, *, code: str = "directory_invalid", status: int = 400):
        super().__init__(message)
        self.code, self.status = code, status


def _filesystem_error(error: OSError) -> DirectoryBrowserError:
    if error.errno in {errno.EACCES, errno.EPERM}:
        return DirectoryBrowserError("The companion does not have permission to open this folder.",
                                     code="directory_denied", status=403)
    if error.errno in {errno.ENOENT, errno.ENOTDIR}:
        return DirectoryBrowserError("This folder is no longer available. Choose another folder.",
                                     code="directory_missing", status=404)
    if error.errno in {errno.ELOOP, errno.ENAMETOOLONG, errno.EINVAL}:
        return DirectoryBrowserError("This folder path cannot be resolved.")
    return DirectoryBrowserError("The companion could not read this folder. Try again.",
                                 code="directory_unavailable", status=503)


def canonical_directory(value: object, *, home: Path | None = None) -> Path:
    """Validate read/traverse access and resolve aliases on this server only."""
    if not isinstance(value, str) or not value.strip() or len(value) > 4096 or "\x00" in value:
        raise DirectoryBrowserError("Choose an existing absolute folder path.")
    try:
        value.encode("utf-8")
    except UnicodeError:
        raise DirectoryBrowserError("The folder path must be valid Unicode text.") from None
    home = home or Path.home()
    if value == "~" or value.startswith("~/"):
        value = str(home) + value[1:]
    path = Path(value)
    if not path.is_absolute():
        raise DirectoryBrowserError("Choose an existing absolute folder path.")
    try:
        resolved = path.resolve(strict=True)
        if not stat.S_ISDIR(resolved.stat().st_mode):
            raise DirectoryBrowserError("The selected path is not a folder.")
        if not os.access(resolved, os.R_OK | os.X_OK):
            raise DirectoryBrowserError("The companion does not have permission to open this folder.",
                                         code="directory_denied", status=403)
        # Opening scandir verifies enumeration without reading children. In
        # particular, SSH access says nothing about this launcher's OS access.
        with os.scandir(resolved):
            pass
        return resolved
    except DirectoryBrowserError:
        raise
    except OSError as error:
        raise _filesystem_error(error) from None
    except RuntimeError:
        raise DirectoryBrowserError("This folder contains a symbolic-link loop.") from None


def _signature(path: Path) -> str:
    metadata = path.stat()
    raw = (str(path), metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns, metadata.st_ctime_ns)
    return hashlib.sha256(repr(raw).encode()).hexdigest()


def browse_directories(value: object = None, *, home: Path | None = None,
                       show_hidden: bool = False, cursor: str | None = None) -> dict:
    if type(show_hidden) is not bool:
        raise DirectoryBrowserError("show_hidden must be a boolean.")
    # The home shortcut is resolved on the companion, never on the client.
    home = (home or Path.home()).resolve()
    path = canonical_directory(str(home) if value is None else value, home=home)
    offset = 0
    previous_signature = None
    try:
        signature = _signature(path)
        if cursor is not None:
            try:
                if not isinstance(cursor, str) or not cursor or len(cursor) > 512:
                    raise ValueError()
                decoded = json.loads(base64.b64decode(cursor, altchars=b"-_", validate=True))
                if (not isinstance(decoded, dict) or set(decoded) != {"signature", "hidden", "offset"}
                        or type(decoded["hidden"]) is not bool
                        or type(decoded["offset"]) is not int
                        or not 0 < decoded["offset"] <= MAX_SCAN_ENTRIES):
                    raise ValueError()
            except (ValueError, TypeError, UnicodeError):
                raise DirectoryBrowserError("The folder page is invalid. Reload the folder.",
                                             code="directory_cursor_invalid") from None
            if decoded["hidden"] != show_hidden:
                raise DirectoryBrowserError("This folder changed. Reload it before continuing.",
                                             code="directory_stale", status=409)
            offset = decoded["offset"]
            previous_signature = decoded["signature"]
        entries = []
        started = time.monotonic()
        with os.scandir(path) as children:
            for count, child in enumerate(children, start=1):
                if count > MAX_SCAN_ENTRIES or time.monotonic() - started > MAX_SCAN_SECONDS:
                    raise DirectoryBrowserError(
                        "This folder is too large to browse. Enter a more specific folder path.",
                        code="directory_too_large", status=422)
                if not show_hidden and child.name.startswith("."):
                    continue
                try:
                    # POSIX can contain undecodable filenames. They cannot be
                    # represented faithfully by the native clients' JSON strings.
                    child.name.encode("utf-8")
                    if not child.is_dir(follow_symlinks=True):
                        continue
                    resolved = Path(child.path).resolve(strict=True)
                    str(resolved).encode("utf-8")
                    entries.append({"name": child.name, "path": child.path,
                                    "resolved_path": str(resolved), "is_symlink": child.is_symlink(),
                                    "can_open": os.access(resolved, os.R_OK | os.X_OK)})
                except (OSError, RuntimeError, UnicodeError):
                    # A disappearing/broken entry cannot be chosen. Errors on
                    # the requested directory itself are returned to the user.
                    continue
        if _signature(path) != signature:
            raise DirectoryBrowserError("This folder changed while loading. Reload it.",
                                         code="directory_stale", status=409)
        entries.sort(key=lambda item: (item["name"].casefold(), item["name"]))
        # A link target can disappear or change permissions without changing
        # this directory's timestamps. Bind pages to the visible entries too.
        signature = hashlib.sha256((signature + json.dumps(entries, sort_keys=True)).encode()).hexdigest()
        if (previous_signature is not None and previous_signature != signature) or offset > len(entries):
            raise DirectoryBrowserError("This folder changed. Reload it before continuing.",
                                         code="directory_stale", status=409)
        page = entries[offset:offset + PAGE_SIZE]
        following = offset + len(page)
        next_cursor = None
        if following < len(entries):
            next_cursor = base64.urlsafe_b64encode(json.dumps(
                {"signature": signature, "hidden": show_hidden, "offset": following},
                separators=(",", ":")).encode()).decode()
        return {"ok": True, "path": str(path), "parent_path": str(path.parent) if path.parent != path else None,
                "home_path": str(home), "entries": page, "next_cursor": next_cursor}
    except OSError as error:
        raise _filesystem_error(error) from None
