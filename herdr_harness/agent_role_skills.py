"""Validate and install private, immutable skill packages copied from the app."""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import unicodedata
import uuid

MAX_BUNDLE_BYTES = 8 * 1024 * 1024
MAX_BUNDLE_FILES = 1000


def _valid_text(value, maximum):
    try:
        return isinstance(value, str) and len(value.encode("utf-8")) <= maximum and "\x00" not in value
    except UnicodeError:
        return False


def validate_bundles(values, *, error, parse_metadata):
    if not isinstance(values, list) or len(values) > MAX_BUNDLE_FILES:
        raise error("skillBundles must be a list of at most 1000 packages")
    prepared, total_bytes, total_files = {}, 0, 0
    for bundle in values:
        if not isinstance(bundle, dict) or set(bundle) - {"id", "name", "description", "source", "files"}:
            raise error("Invalid skill package")
        sid = bundle.get("id")
        if not isinstance(sid, str) or len(sid) != 70 or sid[:6] not in {"skill_", "skill-"} or any(c not in "0123456789abcdef" for c in sid[6:]):
            raise error("Skill package ID must come from the skill catalog")
        if sid in prepared:
            raise error("Duplicate skill package ID")
        metadata = {}
        for key, limit in (("name", 200), ("description", 4000), ("source", 120)):
            value = bundle.get(key)
            if not _valid_text(value, limit):
                raise error("Invalid skill package metadata")
            metadata[key] = value
        files = bundle.get("files")
        if not isinstance(files, list) or not files:
            raise error("A skill package must include SKILL.md")
        total_files += len(files)
        if total_files > MAX_BUNDLE_FILES:
            raise error("Skill packages exceed the 1000-file limit")
        contents, seen = [], set()
        for value in files:
            if not isinstance(value, dict) or set(value) - {"path", "content", "executable"}:
                raise error("Invalid skill package file")
            path = value.get("path")
            if (not _valid_text(path, 512) or not path
                    or "\\" in path or any(ord(c) < 32 for c in path)):
                raise error("Invalid skill package file path")
            parts = path.split("/")
            if len(parts) > 16 or any(not part or part.startswith(".") for part in parts) or PurePosixPath(path).is_absolute():
                raise error("Skill package files must stay inside their package")
            normalized = unicodedata.normalize("NFC", path).casefold()
            if normalized in seen:
                raise error("Duplicate skill package file path")
            seen.add(normalized)
            encoded, executable = value.get("content"), value.get("executable", False)
            if not isinstance(encoded, str) or len(encoded) > 3 * 1024 * 1024 or type(executable) is not bool:
                raise error("Invalid skill package file contents")
            try:
                data = base64.b64decode(encoded, validate=True)
            except (ValueError, binascii.Error) as exc:
                raise error("Skill package contents must be base64") from exc
            total_bytes += len(data)
            if len(data) > 2 * 1024 * 1024 or total_bytes > MAX_BUNDLE_BYTES:
                raise error("Skill packages exceed the 2 MiB per-file or 8 MiB total limit")
            contents.append((path, data, executable))
        paths = {item[0] for item in contents}
        normalized_paths = {unicodedata.normalize("NFC", path).casefold() for path in paths}
        if "SKILL.md" not in paths:
            raise error("A skill package must include SKILL.md at its root")
        if any(parent.as_posix() in normalized_paths for path in normalized_paths for parent in PurePosixPath(path).parents if parent.as_posix() != "."):
            raise error("Skill package files overlap directory paths")
        try:
            manifest = next(data for path, data, _ in contents if path == "SKILL.md").decode("utf-8")
        except UnicodeError as exc:
            raise error("SKILL.md must contain UTF-8 text") from exc
        name, description = parse_metadata(manifest, metadata["name"])
        if not description:
            raise error("SKILL.md must have a nonempty description in its frontmatter")
        metadata.update(name=name[:200], description=description[:4000])
        if not parse_metadata(manifest, "")[0]:
            # Pi falls back to the original folder name. An immutable hash folder
            # must not silently change that identity after transfer.
            lines = manifest.splitlines(keepends=True)
            end = next(index for index, line in enumerate(lines[1:], 1) if line.strip() == "---")
            name_index = next((index for index in range(1, end) if re.match(r"^name\s*:", lines[index])), None)
            explicit = "name: " + json.dumps(metadata["name"], ensure_ascii=False) + "\n"
            if name_index is None:
                lines.insert(1, explicit)
            else:
                lines[name_index] = explicit
            normalized = "".join(lines).encode("utf-8")
            original_size = next(len(data) for path, data, _ in contents if path == "SKILL.md")
            total_bytes += len(normalized) - original_size
            if len(normalized) > 2 * 1024 * 1024 or total_bytes > MAX_BUNDLE_BYTES:
                raise error("Skill packages exceed the 2 MiB per-file or 8 MiB total limit")
            contents = [(path, normalized if path == "SKILL.md" else data, executable)
                        for path, data, executable in contents]
        digest = hashlib.sha256(json.dumps(metadata, sort_keys=True).encode())
        for path, data, executable in sorted(contents):
            digest.update(json.dumps([path, executable, len(data)]).encode())
            digest.update(data)
        prepared[sid] = {**metadata, "digest": digest.hexdigest(), "files": contents}
    return prepared


def install_bundle(root: Path, bundle, *, error):
    """Only validated relative files enter a fresh directory before atomic rename."""
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink() or not root.is_dir() or root.stat().st_uid != os.getuid():
        raise error("Unsafe skill package directory", status=500)
    root.chmod(0o700)
    destination = root / bundle["digest"]
    if destination.exists():
        if destination.is_symlink() or not destination.is_dir():
            raise error("Invalid stored skill package", status=500)
        if _package_matches(destination, bundle):
            return destination
        # Keep every pinned path intact, including a damaged old copy. A fresh
        # version repairs new launches without changing another role's snapshot.
        destination = root / (bundle["digest"] + "-" + uuid.uuid4().hex)
    temporary = Path(tempfile.mkdtemp(prefix=".import-", dir=root))
    try:
        for relative, data, executable in bundle["files"]:
            path = temporary / relative
            parent = temporary
            for part in PurePosixPath(relative).parts[:-1]:
                parent /= part
                parent.mkdir(exist_ok=True, mode=0o700)
            with path.open("xb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            path.chmod(0o700 if executable else 0o600)
        try:
            temporary.rename(destination)
        except FileExistsError:
            if not destination.is_dir() or destination.is_symlink():
                raise
        return destination
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def _package_matches(directory: Path, bundle) -> bool:
    try:
        for relative, data, executable in bundle["files"]:
            path = directory / relative
            if (path.is_symlink() or not path.resolve().is_relative_to(directory.resolve())
                    or not path.is_file() or path.stat().st_size != len(data)
                    or bool(path.stat().st_mode & 0o100) != executable):
                return False
            with path.open("rb") as stream:
                if stream.read(len(data) + 1) != data:
                    return False
        return True
    except OSError:
        return False
