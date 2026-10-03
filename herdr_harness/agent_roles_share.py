"""Portable Agent Roles files: export roles with the skill copies they run, import them with a reviewed plan.

A shared file is untrusted input on the importing computer. Import never changes an existing role unless the
person confirmed that replacement, never reuses a skill ID for different content, and applies everything in one
transaction after a dry run whose digest the commit must repeat.
"""
from __future__ import annotations

import base64
import copy
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import unicodedata

from .agent_roles import (AgentRoleError, BUILTIN_IDS, MAX_ROLES, MAX_SKILLS, MAX_TEAMS, ROLE_AVATARS, _metadata,
                          _role_id, _seed_roles, skill_catalog)
from .agent_role_skills import MAX_BUNDLE_BYTES, MAX_BUNDLE_FILES, install_bundle, validate_bundles

FORMAT = "herdr-agent-roles"
VERSION = 1
MAX_DOCUMENT_BYTES = 15 * 1024 * 1024
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_SKILL_TEXT = 64 * 1024
# A stored copy passed the save limits; this only bounds reading a damaged or altered folder.
_MAX_PACKAGE_READ = 8 * 1024 * 1024
LOCKED_ROLE = "recovery_advisor"
ROLE_FIELDS = ("id", "builtin", "name", "purpose", "whenToUse", "systemPrompt", "modelProfile", "allowDelegation",
               "skillIds", "reviewPrompt", "group", "avatar")
_PROMPT_FIELDS = (("name", "name"), ("whenToUse", "when-to-use text"), ("systemPrompt", "system prompt"),
                  ("reviewPrompt", "review prompt"))
# Fields a person edits. Seeds equal on all of them mean there is nothing to share.
_EDITABLE = ("name", "whenToUse", "systemPrompt", "modelProfile", "allowDelegation", "skillIds", "reviewPrompt",
             "group", "avatar")
_CHANGE_LABELS = (("name", "Name"), ("whenToUse", "When to use"), ("systemPrompt", "System prompt"),
                  ("reviewPrompt", "Review prompt"), ("modelProfile", "Model profile"), ("group", "Team"),
                  ("avatar", "Avatar"), ("allowDelegation", "Delegation"), ("skillIds", "Skills"))
_PRIVATE_KEY = re.compile(rb"-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----|PuTTY-User-Key-File-[0-9]+:")
# Bidirectional overrides and tag characters can hide instructions from a reviewer.
_HIDDEN_TEXT = re.compile("[\u202a-\u202e\u2066-\u2069\U000e0000-\U000e007f]")
_SKILL_ID = re.compile(r"skill[_-][0-9a-f]{64}")
_HASH = re.compile(r"[0-9a-f]{64}")


def content_hash(files):
    """Identity of a package's files, independent of its catalog location and labels."""
    digest = hashlib.sha256()
    for path, data, executable in sorted(files):
        digest.update(json.dumps([path, executable, len(data)]).encode())
        digest.update(data)
    return digest.hexdigest()


def derived_skill_id(sid, digest):
    """A deterministic ID for an imported copy that differs from what this computer calls `sid`."""
    return "skill-" + hashlib.sha256(f"herdr-import\0{sid}\0{digest}".encode()).hexdigest()


def _unsafe_label(text):
    """Invisible formatting in a name can disguise it. Emoji joiners and subdivision flags stay allowed."""
    for index, char in enumerate(text):
        if unicodedata.category(char) != "Cf" or char == "\u200d":
            continue
        if "\U000e0020" <= char <= "\U000e007f":
            start = index
            while start > 0 and "\U000e0020" <= text[start - 1] <= "\U000e007e":
                start -= 1
            if start > 0 and text[start - 1] == "\U0001f3f4":
                continue
        return True
    return False


def _hidden_text(files):
    """True when any text file carries bidirectional overrides or tag characters a reviewer can't see."""
    for _, data, _ in files:
        try:
            if _HIDDEN_TEXT.search(data.decode("utf-8")):
                return True
        except UnicodeDecodeError:
            continue
    return False


def _manifest_aliases(prepared):
    """Hashes a Mac may report for this copy: the companion inserts a missing frontmatter name when it stores
    a skill, so the Mac's own file can lack that one line and still be the same skill."""
    aliases = {prepared["contentHash"]}
    files = prepared["files"]
    manifest = next(data for path, data, _ in files if path == "SKILL.md")
    lines = manifest.decode("utf-8").splitlines(keepends=True)
    inserted = "name: " + json.dumps(prepared["name"], ensure_ascii=False) + "\n"
    if len(lines) > 1 and lines[0].strip() == "---" and lines[1] == inserted:
        original = "".join(lines[:1] + lines[2:]).encode("utf-8")
        aliases.add(content_hash([(path, original if path == "SKILL.md" else data, executable)
                                  for path, data, executable in files]))
    return aliases


def _untouched_builtin(role):
    seed = _seed_roles().get(role["id"])
    return seed is not None and all(role.get(key) == seed.get(key) for key in _EDITABLE)


def _shareable(role):
    if role["id"] == LOCKED_ROLE or role.get("locked"):
        return False, "Managed by each computer"
    if _untouched_builtin(role):
        return False, "Default — nothing to share"
    return True, ""


def _read_package(directory: Path):
    """Read a package this companion installed. Anything other than plain files and folders makes it unusable."""
    files, total = [], 0
    root = directory.resolve(strict=True)
    stack = [root]
    while stack:
        current = stack.pop()
        with os.scandir(current) as entries:
            for entry in sorted(entries, key=lambda item: item.name, reverse=True):
                meta = entry.stat(follow_symlinks=False)
                path = Path(entry.path)
                if stat.S_ISDIR(meta.st_mode):
                    stack.append(path)
                    continue
                if not stat.S_ISREG(meta.st_mode):
                    raise OSError("Stored skill packages contain only regular files")
                total += meta.st_size
                if len(files) >= 1000 or meta.st_size > MAX_FILE_BYTES or total > _MAX_PACKAGE_READ:
                    raise OSError("Stored skill package exceeds the sharing limits")
                with open(path, "rb") as stream:
                    data = stream.read(MAX_FILE_BYTES + 1)
                files.append((path.relative_to(root).as_posix(), data, bool(meta.st_mode & 0o100)))
    if "SKILL.md" not in {item[0] for item in files}:
        raise OSError("Stored skill package is missing SKILL.md")
    return sorted(files)


def _package_stats(directory: Path):
    files = size = executable = 0
    unsafe = False
    for current, folders, names in os.walk(directory, followlinks=False):
        folders.sort()
        unsafe = unsafe or any(_unsafe_label(name) for name in folders + names)
        for name in names:
            meta = os.lstat(os.path.join(current, name))
            files += 1
            size += meta.st_size
            executable += bool(meta.st_mode & 0o100)
    return files, size, executable, unsafe


_UNSAFE_NOTE = "Its name, team or skills have invisible formatting characters. Rename them to share it."


def _unsafe_role(role):
    return _unsafe_label(role["name"]) or _unsafe_label(role.get("group", ""))


def _skill_metadata(sid, state, catalog_rows):
    row = state.get("packages", {}).get(sid) or catalog_rows.get(sid)
    if row:
        return {"name": row["name"], "description": row["description"], "source": row["source"]}
    return {"name": "Unavailable skill", "description": "", "source": ""}


def _role_skill_dirs(roles_store, state, role):
    """Mirror AgentRoles.snapshot: only a role's own stored binding is exportable content."""
    bindings = state.get("rolePackages", {}).get(role["id"], {})
    result = {}
    for sid in role["skillIds"] or []:
        digest = bindings.get(sid)
        directory = roles_store._package_root / digest if digest else None
        result[sid] = directory if directory and (directory / "SKILL.md").is_file() else None
    return result


def _state(roles_store):
    with roles_store._lock:
        return roles_store._state()


# MARK: Export

def export_preview(roles_store):
    state = _state(roles_store)
    catalog_rows = {row["id"]: row for row in skill_catalog(roles_store.sources)["skills"]}
    rows = []
    for role in state["roles"].values():
        if role["id"] == LOCKED_ROLE:
            continue
        shareable, note = _shareable(role)
        skills, unsafe = [], _unsafe_role(role)
        for sid, directory in _role_skill_dirs(roles_store, state, role).items():
            metadata = _skill_metadata(sid, state, catalog_rows)
            files = size = executable = 0
            if directory is not None:
                try:
                    files, size, executable, unsafe_path = _package_stats(directory)
                    unsafe = unsafe or unsafe_path or _unsafe_label(metadata["name"])
                except OSError:
                    directory = None
            skills.append({"id": sid, "name": metadata["name"], "included": directory is not None,
                           "files": files, "bytes": size, "executable": executable})
        if shareable and unsafe:
            shareable, note = False, _UNSAFE_NOTE
        rows.append({"id": role["id"], "name": role["name"], "purpose": role["purpose"], "builtin": role["builtin"],
                     "group": role.get("group", ""), "avatar": role["avatar"],
                     "allowDelegation": role["allowDelegation"], "shareable": shareable, "note": note,
                     "automaticSkills": role["skillIds"] is None, "skills": skills})
    return {"ok": True, "machineId": roles_store.machine_id, "revision": state["revision"], "roles": rows,
            "warnings": []}


def _blocked(role, where):
    return AgentRoleError(f"‘{role['name']}’ {where} contains a private key. Remove it or leave this role out.",
                          code="agent_roles_export_blocked", status=400)


def _too_large(sizes):
    largest = ", ".join(name for name, _ in sorted(sizes.items(), key=lambda item: -item[1])[:3])
    return AgentRoleError(f"The selected roles' skills exceed 8 MB or 1,000 files (largest: {largest}). "
                          "Export fewer roles.", code="agent_roles_export_too_large", status=413)


def export_document(roles_store, role_ids=None, *, now=None):
    state = _state(roles_store)
    catalog_rows = {row["id"]: row for row in skill_catalog(roles_store.sources)["skills"]}
    if role_ids is None:
        chosen = [role for role in state["roles"].values() if _shareable(role)[0]]
    else:
        if (not isinstance(role_ids, list) or not role_ids or len(role_ids) > MAX_ROLES
                or any(not isinstance(rid, str) for rid in role_ids) or len(set(role_ids)) != len(role_ids)):
            raise AgentRoleError("Choose between 1 and 128 roles to export")
        chosen = []
        for rid in role_ids:
            role = state["roles"].get(rid)
            if role is None:
                raise AgentRoleError("A selected role no longer exists on this computer. Reload and try again.")
            shareable, note = _shareable(role)
            if not shareable:
                raise AgentRoleError(f"{role['name']} can't be shared: {note.lower()}.")
            chosen.append(role)
        order = {rid: index for index, rid in enumerate(state["roles"])}
        chosen.sort(key=lambda role: order[role["id"]])
    if not chosen:
        raise AgentRoleError("There are no customized roles to share yet")
    roles, skills, references, warnings = [], {}, {}, []
    total_files = total_bytes = 0
    sizes, packages = {}, {}
    for role in chosen:
        if _unsafe_role(role):
            raise AgentRoleError(f"‘{role['name']}’ has invisible formatting characters in its name or team. "
                                 "Rename it to share it.", code="agent_roles_export_blocked", status=400)
        for field, label in _PROMPT_FIELDS:
            if _PRIVATE_KEY.search(role.get(field, "").encode("utf-8")):
                raise _blocked(role, label)
        exported = {field: copy.deepcopy(role.get(field)) for field in ROLE_FIELDS}
        exported["group"] = role.get("group", "")
        versions = {}
        for sid, directory in _role_skill_dirs(roles_store, state, role).items():
            metadata = _skill_metadata(sid, state, catalog_rows)
            if directory is not None and directory not in packages:
                try:
                    packages[directory] = _read_package(directory)
                except OSError:
                    packages[directory] = None
            files = packages.get(directory) if directory is not None else None
            if files is None:
                references.setdefault(sid, {"id": sid, **metadata})
                warnings.append(f"{role['name']}: the selected skill ‘{metadata['name']}’ isn't stored on this "
                                "computer, so only its name is shared.")
                continue
            for path, data, _ in files:
                if _PRIVATE_KEY.search(data):
                    raise _blocked(role, f"skill ‘{metadata['name']}’ file {path}")
                if _unsafe_label(path):
                    raise AgentRoleError(f"‘{role['name']}’ skill ‘{metadata['name']}’ has a file name with invisible "
                                         "formatting characters. Rename it to share this role.",
                                         code="agent_roles_export_blocked", status=400)
            if _unsafe_label(metadata["name"]):
                raise AgentRoleError(f"‘{role['name']}’ uses a skill whose name has invisible formatting characters. "
                                     "Rename it to share this role.", code="agent_roles_export_blocked", status=400)
            identity = content_hash(files)
            versions[sid] = identity
            if (sid, identity) in skills:
                continue
            size = sum(len(data) for _, data, _ in files)
            total_files += len(files)
            total_bytes += size
            sizes[metadata["name"]] = sizes.get(metadata["name"], 0) + size
            if total_files > MAX_BUNDLE_FILES or total_bytes > MAX_BUNDLE_BYTES:
                raise _too_large(sizes)
            skills[(sid, identity)] = {"id": sid, **metadata, "contentHash": identity,
                                       "files": [{"path": path, "content": base64.b64encode(data).decode("ascii"),
                                                  "executable": executable} for path, data, executable in files]}
        if role["skillIds"] is not None:
            # Present even when empty: a skill without a version here is a name-only reference.
            exported["skillContent"] = versions
        roles.append(exported)
    stamp = (now or datetime.now(timezone.utc)).astimezone(timezone.utc).replace(microsecond=0)
    document = {"format": FORMAT, "version": VERSION, "exportedAt": stamp.isoformat().replace("+00:00", "Z"),
                "roles": roles, "skills": list(skills.values()) + list(references.values())}
    if len(json.dumps(document, ensure_ascii=False).encode("utf-8")) > MAX_DOCUMENT_BYTES:
        raise AgentRoleError("The selected roles are larger than 15 MB. Export fewer roles.",
                             code="agent_roles_export_too_large", status=413)
    return {"ok": True, "document": document,
            "summary": {"roles": len(roles), "skills": len(skills), "files": total_files, "bytes": total_bytes},
            "warnings": list(dict.fromkeys(warnings))}


# MARK: Import

def _document_error(message):
    return AgentRoleError(message, code="invalid_agent_roles_document", status=400)


def _parse_document(document):
    """Check the envelope and every skill package before any role is planned."""
    if not isinstance(document, dict):
        raise _document_error("This isn't a Herdr roles file")
    try:
        size = len(json.dumps(document, ensure_ascii=False).encode("utf-8"))
    except (UnicodeEncodeError, ValueError, TypeError, RecursionError) as exc:
        raise _document_error("This roles file contains text that isn't valid Unicode") from exc
    if document.get("format") != FORMAT:
        raise _document_error("This isn't a Herdr roles file")
    version = document.get("version")
    if type(version) is not int or version < 1:
        raise _document_error("This roles file has an invalid version")
    if version > VERSION:
        raise _document_error("This roles file needs a newer Herdr companion")
    if size > MAX_DOCUMENT_BYTES:
        raise _document_error("Roles files are limited to 15 MB")
    warnings = []
    unknown = sorted(set(document) - {"format", "version", "exportedAt", "roles", "skills"})
    roles, skills = document.get("roles"), document.get("skills", [])
    if not isinstance(roles, list) or not roles or len(roles) > MAX_ROLES:
        raise _document_error("A roles file contains between 1 and 128 roles")
    if not isinstance(skills, list) or len(skills) > MAX_BUNDLE_FILES:
        raise _document_error("A roles file contains at most 1,000 skills")
    exported_at = document.get("exportedAt")
    if exported_at is not None and (not isinstance(exported_at, str) or len(exported_at) > 64):
        raise _document_error("exportedAt must be a short timestamp")
    included, references = {}, {}
    total_files = total_bytes = 0
    for entry in skills:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or not _SKILL_ID.fullmatch(entry["id"]):
            raise _document_error("Each skill needs an ID from a Herdr skill catalog")
        sid = entry["id"]
        for key, limit in (("name", 200), ("description", 4000), ("source", 120)):
            value = entry.get(key, "")
            if not isinstance(value, str) or len(value.encode("utf-8")) > limit:
                raise _document_error("A skill has invalid metadata")
            if key != "description" and _unsafe_label(value):
                raise _document_error("A skill name or label contains invisible formatting characters")
        unknown += [f"skills.{key}" for key in set(entry) - {"id", "name", "description", "source", "contentHash", "files"}]
        if "files" not in entry:
            if sid in references:
                raise _document_error("A skill appears twice in this file")
            references[sid] = {"id": sid, "name": entry.get("name", ""), "description": entry.get("description", ""),
                               "source": entry.get("source", "")}
            continue
        if not isinstance(entry["files"], list):
            raise _document_error("A skill's files must be a list")
        files = []
        for item in entry["files"]:
            if isinstance(item, dict):
                unknown += [f"skills.files.{key}" for key in set(item) - {"path", "content", "executable"}]
                item = {key: item[key] for key in ("path", "content", "executable") if key in item}
                if isinstance(item.get("path"), str) and _unsafe_label(item["path"]):
                    raise _document_error("A skill file path contains invisible formatting characters")
            files.append(item)
        total_files += len(files)
        if total_files > MAX_BUNDLE_FILES:
            raise _document_error("Skills in this file exceed 1,000 files")
        bundle = {"id": sid, "name": entry.get("name", ""), "description": entry.get("description", ""),
                  "source": entry.get("source", ""), "files": files}
        try:
            prepared = validate_bundles([bundle], error=AgentRoleError, parse_metadata=_metadata)[sid]
        except AgentRoleError as exc:
            raise _document_error(f"Skill ‘{entry.get('name') or sid}’: {exc}") from exc
        try:
            prepared["name"].encode("utf-8"), prepared["description"].encode("utf-8")
        except UnicodeEncodeError as exc:
            raise _document_error("A skill's SKILL.md contains text that isn't valid Unicode") from exc
        if _unsafe_label(prepared["name"]):
            raise _document_error("A skill name contains invisible formatting characters")
        total_bytes += sum(len(data) for _, data, _ in prepared["files"])
        if total_bytes > MAX_BUNDLE_BYTES:
            raise _document_error("Skills in this file exceed 8 MB")
        identity = content_hash(prepared["files"])
        declared = entry.get("contentHash")
        if declared is not None and (not isinstance(declared, str) or declared != identity):
            raise _document_error(f"Skill ‘{prepared['name']}’ doesn't match its checksum. Export the file again.")
        if (sid, identity) in included:
            raise _document_error("A skill appears twice in this file")
        entry = {**prepared, "id": sid, "contentHash": identity, "hiddenText": _hidden_text(prepared["files"])}
        entry["aliases"] = _manifest_aliases(entry)
        included[(sid, identity)] = entry
    by_id = {}
    for (sid, identity), entry in included.items():
        by_id.setdefault(sid, []).append(entry)
    seen_roles = set()
    for raw in roles:
        if not isinstance(raw, dict):
            raise _document_error("Each role must be an object")
        rid = raw.get("id")
        if isinstance(rid, str):
            if rid in seen_roles:
                raise _document_error("A role appears twice in this file")
            seen_roles.add(rid)
        unknown += [f"roles.{key}" for key in set(raw) - set(ROLE_FIELDS) - {"skillContent", "teamId", "locked"}]
    if unknown:
        warnings.append("Ignored fields this companion doesn't understand: " + ", ".join(sorted(set(unknown))) + ".")
    return {"roles": roles, "included": included, "byId": by_id, "references": references,
            "exportedAt": exported_at or "", "warnings": warnings}


class _Planner:
    """Plans every document role against one consistent view of this computer.

    `local_skills` maps skill IDs in the file to the content hash of the copy at that location on the importing
    Mac. A Mac re-sends its own copy for every selected ID it has whenever a role is saved, so a shared copy that
    differs from it must live under a separate ID. `None` means the client didn't say; then Mac catalog IDs are
    kept separate unless this computer already holds identical files.
    """

    def __init__(self, roles_store, state, catalog_rows, parsed, local_skills):
        self.store, self.state, self.catalog_rows, self.parsed = roles_store, state, catalog_rows, parsed
        self.local_skills = local_skills
        self.root = roles_store._package_root
        self.team_names = {team["name"].casefold() for team in state["teams"].values()}
        self.hashes = {}
        self.skill_rows = {}
        self.new_packages = {}

    def _dir_hash(self, digest):
        if digest not in self.hashes:
            try:
                self.hashes[digest] = content_hash(_read_package(self.root / digest))
            except OSError:
                self.hashes[digest] = None
        return self.hashes[digest]

    def _candidates(self, sid, role_id):
        digests = []
        own = self.state.get("rolePackages", {}).get(role_id, {}).get(sid)
        if own:
            digests.append(own)
        package = self.state.get("packages", {}).get(sid)
        if package:
            digests.append(package["digest"])
        digests += [binding[sid] for binding in self.state.get("rolePackages", {}).values() if sid in binding]
        return list(dict.fromkeys(digests))

    def _known(self, sid):
        return sid in self.catalog_rows or sid in self.state.get("packages", {})

    def _resolve_included(self, sid, entry, role_id):
        """Return (final ID, outcome, digest, reason) without ever reusing an ID for different content."""
        identity = entry["contentHash"]
        local = (self.local_skills or {}).get(sid)
        mac_differs = local is not None and local not in entry["aliases"]
        mac_unknown = self.local_skills is None and sid.startswith("skill_")
        candidates = self._candidates(sid, role_id)
        if not mac_differs:
            for digest in candidates:
                if self._dir_hash(digest) == identity:
                    return sid, "present", digest, None
            planned = self.new_packages.get(sid)
            if planned is not None and planned["contentHash"] == identity:
                return sid, "included", planned["digest"], None
            if not candidates and sid not in self.catalog_rows and planned is None and not mac_unknown:
                self.new_packages[sid] = entry
                return sid, "included", entry["digest"], None
        derived = derived_skill_id(sid, identity)
        for digest in self._candidates(derived, role_id):
            if self._dir_hash(digest) == identity:
                return derived, "present", digest, None
        reason = ("mac" if mac_differs or mac_unknown else
                  "computer" if candidates or sid in self.catalog_rows else "file")
        self.new_packages.setdefault(derived, {**entry, "id": derived})
        return derived, "separate", entry["digest"], reason

    def _note_skill(self, final_id, source_id, outcome, entry, role_id, reason=None):
        row = self.skill_rows.get(final_id)
        if row is None:
            metadata = ({key: entry[key] for key in ("name", "description", "source")} if entry is not None
                        else _skill_metadata(final_id, self.state, self.catalog_rows))
            files = entry["files"] if entry is not None else []
            manifest = next((data for path, data, _ in files if path == "SKILL.md"), b"")
            row = {"id": final_id, "sourceId": source_id, "name": metadata["name"],
                   "description": metadata["description"], "outcome": outcome,
                   "files": [{"path": path, "bytes": len(data), "executable": executable}
                             for path, data, executable in files],
                   "bytes": sum(len(data) for _, data, _ in files),
                   "executableFiles": sum(1 for _, _, executable in files if executable),
                   # Cut on a character boundary; SKILL.md was validated as UTF-8.
                   "skillText": manifest[:MAX_SKILL_TEXT].decode("utf-8", errors="ignore"),
                   "skillTextTruncated": len(manifest) > MAX_SKILL_TEXT,
                   "hiddenText": bool(entry and entry.get("hiddenText")), "usedBy": []}
            if outcome == "separate":
                row["separateReason"] = reason or "computer"
            self.skill_rows[final_id] = row
        if role_id not in row["usedBy"]:
            row["usedBy"].append(role_id)

    def plan_role(self, raw):
        claims = (dict(self.new_packages), copy.deepcopy(self.skill_rows))
        row = self._plan_role(raw)
        if row["action"] in {"skip", "invalid"}:
            # A row that can't be imported must not shape how other rows store their skills.
            self.new_packages, self.skill_rows = claims
            row["skills"] = []
        return row

    def _plan_role(self, raw):
        rid = raw.get("id")
        name = raw.get("name") if isinstance(raw.get("name"), str) else ""
        purpose = raw.get("purpose", "worker")
        base = {"id": rid if isinstance(rid, str) else "", "name": name.strip() or "Unnamed role",
                "purpose": purpose if isinstance(purpose, str) and purpose in {"worker", "pr_review"} else "worker",
                "builtin": isinstance(rid, str) and rid in BUILTIN_IDS, "action": "invalid", "reason": "",
                "selectedByDefault": False, "role": None, "current": None, "changes": [], "team": None,
                "skills": [], "notes": [], "_bindings": {}, "_value": None}
        if rid == LOCKED_ROLE:
            return {**base, "action": "skip", "reason": "Recovery Advisor is managed by each computer."}
        try:
            rid = _role_id(rid)
        except AgentRoleError as exc:
            return {**base, "reason": str(exc)}
        existing = self.state["roles"].get(rid)
        seed = _seed_roles().get(rid)
        base["current"] = copy.deepcopy(existing)
        if seed:
            if purpose != seed["purpose"] and "purpose" in raw:
                return {**base, "reason": "A built-in role keeps its kind."}
            purpose = seed["purpose"]
        if not isinstance(purpose, str) or purpose not in {"worker", "pr_review"}:
            return {**base, "reason": "Role purpose must be worker or pr_review."}
        base["purpose"] = purpose
        if existing and existing["purpose"] != purpose:
            return {**base, "reason": "This computer already has a different kind of role with this ID."}
        for field in ("name", "group"):
            if isinstance(raw.get(field), str) and _unsafe_label(raw[field]):
                return {**base, "reason": "The role's name or team contains invisible formatting characters."}
        notes, hidden = [], False
        for field, _ in _PROMPT_FIELDS:
            if isinstance(raw.get(field), str) and _HIDDEN_TEXT.search(raw[field]):
                hidden = True
        if hidden:
            notes.append("Its prompts contain hidden formatting characters. Review them before importing.")
        avatar = raw.get("avatar", "review")
        if not isinstance(avatar, str) or avatar not in ROLE_AVATARS:
            notes.append("Uses the default avatar because this companion doesn't have the file's avatar.")
            avatar = "review"
        skill_ids = raw.get("skillIds")
        strict = "skillContent" in raw
        versions = raw.get("skillContent", {})
        if not isinstance(versions, dict) or any(not isinstance(value, str) or not _HASH.fullmatch(value)
                                                 for value in versions.values()):
            return {**base, "reason": "The role's skill versions are invalid."}
        final_ids, bindings, missing, separate, hidden_skills = None, {}, [], set(), []
        if skill_ids is not None:
            if (not isinstance(skill_ids, list) or len(skill_ids) > MAX_SKILLS
                    or any(not isinstance(sid, str) or not _SKILL_ID.fullmatch(sid) for sid in skill_ids)):
                return {**base, "reason": "skillIds must be null or a list of skill IDs."}
            final_ids = []
            for sid in dict.fromkeys(skill_ids):
                entries = self.parsed["byId"].get(sid, [])
                identity = versions.get(sid)
                if identity:
                    entry = next((item for item in entries if item["contentHash"] == identity), None)
                    if entry is None:
                        return {**base, "reason": "The role refers to a skill version that isn't in this file."}
                else:
                    entry = None if strict or len(entries) != 1 else entries[0]
                reason = None
                if entry is not None:
                    final, outcome, digest, reason = self._resolve_included(sid, entry, rid)
                    bindings[final] = digest
                    if reason:
                        separate.add(reason)
                elif self._known(sid) or sid in self.state.get("rolePackages", {}).get(rid, {}):
                    final, outcome = sid, "available"
                    own = self.state.get("rolePackages", {}).get(rid, {}).get(sid)
                    package = self.state.get("packages", {}).get(sid)
                    bindings[final] = own or (package["digest"] if package else None)
                else:
                    reference = self.parsed["references"].get(sid, {})
                    label = reference.get("name") or "Unnamed skill"
                    missing.append(label)
                    base["skills"].append({"id": sid, "sourceId": sid, "name": label, "outcome": "missing"})
                    continue
                if final not in final_ids:
                    final_ids.append(final)
                    self._note_skill(final, sid, outcome, entry, rid, reason)
                    if entry is not None and entry.get("hiddenText"):
                        hidden_skills.append(self.skill_rows[final]["name"])
                    base["skills"].append({"id": final, "sourceId": sid, "name": self.skill_rows[final]["name"],
                                           "outcome": outcome})
        value = {"id": rid, "name": raw.get("name"), "whenToUse": raw.get("whenToUse", ""),
                 "systemPrompt": raw.get("systemPrompt", ""),
                 "modelProfile": seed["modelProfile"] if seed else raw.get("modelProfile"),
                 "allowDelegation": raw.get("allowDelegation", False), "skillIds": final_ids, "purpose": purpose,
                 "reviewPrompt": raw.get("reviewPrompt", ""), "group": raw.get("group", ""), "avatar": avatar}
        known = (set(self.catalog_rows) | set(self.state.get("packages", {})) | set(self.new_packages)
                 | set(final_ids or []))
        try:
            # A fresh copy per row: only the commit creates teams, and an invalid row must not leave one behind.
            role = self.store._validate_role(value, existing, known, copy.deepcopy(self.state["teams"]))
        except AgentRoleError as exc:
            return {**base, "reason": str(exc), "notes": notes}
        if role["group"]:
            joins = role["group"].casefold() in self.team_names
            base["team"] = {"name": role["group"], "status": "joins" if joins else "creates"}
            if not joins:
                role["teamId"] = ""
        names = set()
        for final in role["skillIds"] or []:
            row = self.skill_rows.get(final)
            label = (row["name"] if row else _skill_metadata(final, self.state, self.catalog_rows)["name"]).casefold()
            if label in names:
                return {**base, "reason": "Two of this role's skills have the same name.", "notes": notes}
            names.add(label)
        if missing:
            notes.append("Imports without: " + ", ".join(missing) + ".")
        for label in hidden_skills:
            hidden = True
            notes.append(f"Skill ‘{label}’ contains hidden formatting characters. Review it before importing.")
        if separate & {"computer", "mac"}:
            notes.append("Some skills differ from copies with the same ID on this computer or your Mac, "
                         "so the shared copies are kept separate.")
        elif separate:
            notes.append("This file has more than one version of a skill, so this role's copy is kept separate.")
        if any(other["id"] != rid and other["purpose"] == purpose
               and other["name"].casefold() == role["name"].casefold() for other in self.state["roles"].values()):
            notes.append(f"You already have a different role named {role['name']}.")
        if existing is None:
            action, changes = "create", []
        else:
            changes = [label for field, label in _CHANGE_LABELS if role.get(field) != existing.get(field)]
            current = self.state.get("rolePackages", {}).get(rid, {})
            if "Skills" not in changes and any(bindings.get(sid) != current.get(sid) for sid in role["skillIds"] or []):
                changes.append("Skill files")
            action = "update" if changes else "unchanged"
        default = action == "create" or (action == "update" and _untouched_builtin(existing))
        return {**base, "action": action, "role": role, "changes": changes, "notes": notes,
                "selectedByDefault": default and not missing and not hidden, "_bindings": bindings, "_value": value}


def _plan(roles_store, state, catalog_rows, parsed, local_skills):
    planner = _Planner(roles_store, state, catalog_rows, parsed, local_skills)
    rows = [planner.plan_role(raw) for raw in parsed["roles"]]
    teams = {}
    for row in rows:
        if row["team"] is not None:
            teams.setdefault(row["team"]["name"].casefold(), row["team"])
    warnings = list(parsed["warnings"])
    creates = sum(1 for row in rows if row["action"] == "create")
    room = MAX_ROLES - len(state["roles"])
    if creates > room:
        warnings.append(f"This computer has room for {max(room, 0)} more roles.")
    new_teams = sum(1 for team in teams.values() if team["status"] == "creates")
    team_room = MAX_TEAMS - len(state["teams"])
    if new_teams > team_room:
        warnings.append(f"This computer has room for {max(team_room, 0)} more teams.")
    canonical = {"machineId": roles_store.machine_id, "revision": state["revision"],
                 "localSkills": dict(sorted((local_skills or {}).items())) if local_skills is not None else None,
                 "roles": [{"id": row["id"], "action": row["action"], "reason": row["reason"],
                            "role": {key: value for key, value in (row["role"] or {}).items() if key != "teamId"},
                            "skills": row["skills"], "bindings": row["_bindings"]} for row in rows]}
    digest = hashlib.sha256(json.dumps(canonical, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    return {"rows": rows, "planner": planner, "teams": list(teams.values()), "warnings": warnings, "digest": digest}


def _response(roles_store, state, parsed, plan, *, dry_run):
    return {"ok": True, "dryRun": dry_run, "machineId": roles_store.machine_id, "revision": state["revision"],
            "planDigest": plan["digest"], "exportedAt": parsed["exportedAt"],
            "roles": [{key: value for key, value in row.items() if not key.startswith("_")} for row in plan["rows"]],
            "skills": list(plan["planner"].skill_rows.values()), "teams": plan["teams"],
            "warnings": plan["warnings"]}


def _id_list(value, field):
    if (not isinstance(value, list) or len(value) > MAX_ROLES or any(not isinstance(item, str) for item in value)
            or len(set(value)) != len(value)):
        raise AgentRoleError(f"{field} must be a list of distinct role IDs")
    return value


def _local_skills(value):
    if value is None:
        return None
    if (not isinstance(value, dict) or len(value) > MAX_SKILLS
            or any(not _SKILL_ID.fullmatch(key) or not isinstance(item, str) or not _HASH.fullmatch(item)
                   for key, item in value.items())):
        raise AgentRoleError("localSkills must map skill IDs to content hashes")
    return value


def import_document(roles_store, body):
    """Plan an import (dryRun) or apply a reviewed plan atomically. Returns (response, changed)."""
    if not isinstance(body, dict):
        raise AgentRoleError("Import request must be an object")
    dry_run = body.get("dryRun", True)
    if type(dry_run) is not bool:
        raise AgentRoleError("dryRun must be a boolean")
    local_skills = _local_skills(body.get("localSkills"))
    parsed = _parse_document(body.get("document"))
    catalog_rows = {row["id"]: row for row in skill_catalog(roles_store.sources)["skills"]}
    if dry_run:
        state = _state(roles_store)
        plan = _plan(roles_store, state, catalog_rows, parsed, local_skills)
        return _response(roles_store, state, parsed, plan, dry_run=True), False
    expected, digest = body.get("expectedRevision"), body.get("planDigest")
    if type(expected) is not int or expected < 0:
        raise AgentRoleError("expectedRevision must be a nonnegative integer")
    if not isinstance(digest, str) or not _HASH.fullmatch(digest):
        raise AgentRoleError("planDigest must come from a dry run")
    selected = _id_list(body.get("roleIds", []), "roleIds")
    replacing = set(_id_list(body.get("replaceRoleIds", []), "replaceRoleIds"))
    with roles_store._lock:
        roles_store._db.execute("BEGIN IMMEDIATE")
        try:
            state = roles_store._state()
            if state["revision"] != expected:
                raise AgentRoleError("Agent Roles changed. Review the import again.", code="agent_role_conflict",
                                     status=409)
            plan = _plan(roles_store, state, catalog_rows, parsed, local_skills)
            if plan["digest"] != digest:
                raise AgentRoleError("This computer's roles or skills changed. Review the import again.",
                                     code="import_plan_changed", status=409)
            rows = {row["id"]: row for row in plan["rows"] if row["id"]}
            chosen = []
            for rid in selected:
                row = rows.get(rid)
                if row is None or row["action"] in {"skip", "invalid"}:
                    raise AgentRoleError(f"{row['name'] if row else 'A selected role'} can't be imported.")
                if row["action"] == "update" and rid not in replacing:
                    raise AgentRoleError(f"Confirm replacing your {row['current']['name']} before importing it.")
                if row["action"] != "unchanged":
                    chosen.append(row)
            if sum(1 for row in chosen if row["action"] == "create") > MAX_ROLES - len(state["roles"]):
                raise AgentRoleError("The maximum number of agent roles has been reached")
            counts = {"created": 0, "updated": 0,
                      "unchanged": sum(1 for rid in selected if rows[rid]["action"] == "unchanged")}
            if chosen:
                packages = state.setdefault("packages", {})
                all_bindings = state.setdefault("rolePackages", {})
                planner = plan["planner"]
                used = {final for row in chosen for final in row["role"]["skillIds"] or []}
                installed = {}
                for final, entry in planner.new_packages.items():
                    if final not in used:
                        continue
                    directory = install_bundle(roles_store._package_root, entry, error=AgentRoleError)
                    installed[final] = directory.name
                    packages[final] = {key: entry[key] for key in ("name", "description", "source")}
                    packages[final]["digest"] = directory.name
                    packages[final]["estimatedTokens"] = max(1, math.ceil(len(
                        (entry["name"] + entry["description"] + str(directory / "SKILL.md")).encode()) / 4))
                known = set(planner.catalog_rows) | set(packages)
                for row in chosen:
                    existing = state["roles"].get(row["id"])
                    # Validate against the real teams so new teams are created in this transaction.
                    role = roles_store._validate_role(row["_value"], existing, known | set(row["role"]["skillIds"] or []),
                                                      state["teams"])
                    bindings = {final: installed.get(final, digest) for final, digest in row["_bindings"].items()}
                    all_bindings[role["id"]] = {sid: bindings[sid] for sid in role["skillIds"] or []
                                                if bindings.get(sid) is not None}
                    state["roles"][role["id"]] = role
                    counts["created" if row["action"] == "create" else "updated"] += 1
                state["revision"] += 1
                roles_store._db.execute("UPDATE agent_roles SET payload=? WHERE id=1",
                                        (json.dumps(state, ensure_ascii=False),))
            roles_store._db.execute("COMMIT")
        except Exception:
            if roles_store._db.in_transaction:
                roles_store._db.execute("ROLLBACK")
            raise
    response = _response(roles_store, state, parsed, plan, dry_run=False)
    response["imported"] = counts
    response["overview"] = roles_store.overview()
    return response, bool(chosen)
