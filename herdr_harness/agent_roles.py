"""Private First Mate roles and a bounded catalog of this machine's skills."""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import stat
import threading
import tempfile
from typing import Mapping
import uuid

from .first_mate_routing import DELEGATION_PROFILES
from .agent_role_skills import install_bundle, validate_bundles

CAPABILITY = "agent-roles-v1"
PR_REVIEW_CAPABILITY = "pr-review-agents-v1"
PR_REVIEW_TEAMS_CAPABILITY = "pr-review-teams-v1"
PR_REVIEW_BUILTIN_ID = "pr-review-comprehensive"
PR_REVIEW_PROMPT = ("Perform an adversarial code review of this pull request. Focus on actionable correctness, regression, "
                    "and missing-test issues. Verify each finding against the code and explain its impact.\n\nPull request: {url}")
ROLE_AVATARS = frozenset({"review", "code", "architecture", "quality", "design", "security", "data", "concurrency"})
MAX_SKILLS = 2000
MAX_SCAN_ENTRIES = 10000
MAX_SCAN_DEPTH = 8
MAX_ROLES = 128
MAX_TEAMS = 64
# Stable IDs for teams migrated from the names earlier companions stored on each role.
_TEAM_NAMESPACE = uuid.UUID("5b0e7c1e-3f4a-4d55-9a27-6f1f1c2b8d40")
MAX_PROMPT_BYTES = 32 * 1024
SOURCE_ENV = "HERDR_FIRST_MATE_SKILL_SOURCES"

# These seed editable private configuration once. Routing uses IDs, never labels.
_BUILTINS = (
    ("first_mate", "First Mate", "Lead work across features and coordinate their next steps.", "planning"),
    ("second_mate", "Second Mate", "Coordinate one feature and delegate its work.", "planning"),
    ("worker", "Worker", "Implement a focused assignment and verify the result.", "execution"),
    ("planner", "Planner", "Investigate requirements and prepare an implementation plan.", "planning"),
    ("architect", "Architect", "Review architecture and provide an implementation second opinion.", "architect"),
    ("research_scout", "Research Scout", "Research a focused question and return evidence.", "research_scout"),
    ("recovery_advisor", "Recovery Advisor", "Advise on recovery with restricted tools and no skills.", "execution"),
)
BUILTIN_IDS = frozenset(item[0] for item in _BUILTINS) | {PR_REVIEW_BUILTIN_ID}


class AgentRoleError(ValueError):
    def __init__(self, message, *, code="invalid_agent_role", status=400):
        super().__init__(message)
        self.code, self.status = code, status


def _text(value, field, maximum):
    try:
        valid = (isinstance(value, str) and len(value.encode("utf-8")) <= maximum
                 and not any(ord(char) < 32 and char not in "\n\r\t" for char in value))
    except UnicodeError:
        valid = False
    if not valid:
        raise AgentRoleError(f"{field} must be text of at most {maximum} UTF-8 bytes")
    return value


def _role_id(value):
    if isinstance(value, str) and value in BUILTIN_IDS:
        return value
    try:
        parsed = str(uuid.UUID(value))
        if parsed == value:
            return parsed
    except (ValueError, TypeError, AttributeError):
        pass
    raise AgentRoleError("Role ID must be a built-in identity or a canonical UUID")


def _team_id(value):
    try:
        parsed = str(uuid.UUID(value))
        if parsed == value:
            return parsed
    except (ValueError, TypeError, AttributeError):
        pass
    raise AgentRoleError("Team ID must be a canonical UUID")


def _team_name(value):
    name = _text(value, "name", 120).strip()
    if not name or any(char in name for char in "\n\r\t"):
        raise AgentRoleError("Team name must be one nonempty line")
    return name


def _seed_roles():
    roles = {rid: {"id": rid, "name": name, "builtin": True,
                  "locked": rid == "recovery_advisor", "whenToUse": description,
                  "systemPrompt": "", "modelProfile": profile,
                  "allowDelegation": rid != "recovery_advisor",
                  "skillIds": [] if rid == "recovery_advisor" else None,
                  "purpose": "worker", "reviewPrompt": "", "group": "", "teamId": "", "avatar": "review"}
            for rid, name, description, profile in _BUILTINS}
    roles[PR_REVIEW_BUILTIN_ID] = {"id": PR_REVIEW_BUILTIN_ID, "name": "Comprehensive", "builtin": True,
        "locked": False, "whenToUse": "", "systemPrompt": "", "modelProfile": "default", "allowDelegation": False,
        "skillIds": [], "purpose": "pr_review", "reviewPrompt": "", "group": "", "teamId": "", "avatar": "review"}
    return roles


def _metadata(raw, fallback):
    """Read the manifest scalars displayed by Pi without executing YAML."""
    lines = raw.splitlines()
    if not lines or lines[0].strip() != "---":
        return fallback, ""
    end = next((index for index, line in enumerate(lines[1:], 1) if line.strip() == "---"), None)
    if end is None:
        return fallback, ""
    values, index = {}, 1
    while index < end:
        line = lines[index]
        index += 1
        match = re.match(r"^(name|description)\s*:\s*(.*)$", line)
        if not match:
            continue
        key, value = match.groups()
        if not value or value.startswith((">", "|")):
            block, separator = [], "\n" if value.startswith("|") else " "
            while index < end and (not lines[index].strip() or lines[index][0].isspace()):
                block.append(lines[index].strip())
                index += 1
            value = separator.join(block)
        else:
            while index < end and lines[index] and lines[index][0].isspace():
                value += " " + lines[index].strip()
                index += 1
            if value.startswith('"') and value.endswith('"'):
                try:
                    value = json.loads(value)
                except (ValueError, TypeError):
                    value = value[1:-1]
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1].replace("''", "'")
            else:
                value = value.split(" #", 1)[0]
        values[key] = value.strip()
    return values.get("name") or fallback, values.get("description", "")


def configured_sources(environ):
    """Explicit empty sources disable catalog scanning; test environments stay isolated."""
    if SOURCE_ENV in environ:
        try:
            sources = json.loads(environ[SOURCE_ENV])
        except (ValueError, TypeError) as exc:
            raise AgentRoleError("first_mate.skill_sources must be a mapping of names to folders") from exc
        if (not isinstance(sources, dict) or len(sources) > 32
                or any(not isinstance(name, str) or not name.strip() or len(name) > 120
                       or not isinstance(path, str) or not path.strip() or "\x00" in path
                       for name, path in sources.items())):
            raise AgentRoleError("first_mate.skill_sources must contain at most 32 named folders")
    elif environ.get("HOME"):
        home = Path(environ["HOME"])
        sources = {"Pi": str(home / ".pi/agent/skills"), "Agents": str(home / ".agents/skills")}
    else:
        sources = {}
    normalized = {}
    for name, raw in sources.items():
        if raw == "~" or raw.startswith("~/"):
            if not environ.get("HOME"):
                raise AgentRoleError("Skill source home paths require HOME")
            raw = str(Path(environ["HOME"])) + raw[1:]
        path = Path(raw)
        if not path.is_absolute():
            raise AgentRoleError("Skill source folders must be absolute paths")
        normalized[name] = path
    return normalized


def skill_catalog(sources):
    """Follow skill symlinks, deduplicate real files, and bound work and file reads."""
    skills, source_rows, warnings = [], [], []
    seen_directories, seen_files = set(), set()
    remaining = MAX_SCAN_ENTRIES
    truncated = False
    for name, root in sorted(sources.items(), key=lambda item: (item[0].casefold(), item[0])):
        source_id = "source-" + hashlib.sha256(name.encode()).hexdigest()[:24]
        available = root.is_dir()
        source_rows.append({"id": source_id, "name": name, "path": str(root), "available": available})
        if not available:
            warnings.append(f"Skill source {name} is unavailable on this machine.")
            continue
        stack = [(root, 0)]
        while stack:
            directory, depth = stack.pop()
            if remaining <= 0 or len(skills) >= MAX_SKILLS:
                truncated = True
                break
            try:
                meta = directory.stat()
                identity = (meta.st_dev, meta.st_ino)
                if identity in seen_directories:
                    continue
                seen_directories.add(identity)
                remaining -= 1
                # Directory iteration itself is bounded before sorting.
                entries = []
                with os.scandir(directory) as iterator:
                    for entry in iterator:
                        remaining -= 1
                        if remaining < 0:
                            truncated = True
                            break
                        entries.append(entry)
                children = []
                for entry in sorted(entries, key=lambda value: value.name):
                    path = directory / entry.name
                    if entry.name == "SKILL.md" and entry.is_file(follow_symlinks=True):
                        file_meta = path.stat()
                        file_identity = (file_meta.st_dev, file_meta.st_ino)
                        if not stat.S_ISREG(file_meta.st_mode) or file_identity in seen_files:
                            continue
                        resolved = path.resolve(strict=True)
                        with resolved.open("rb") as stream:
                            raw = stream.read(64 * 1024).decode("utf-8")
                        skill_name, description = _metadata(raw, directory.name)
                        if not description:
                            continue
                        # A manifest is display data. Cap it independently of the skill body.
                        skill_name, description = skill_name[:200], description[:4000]
                        relative = path.relative_to(root).as_posix()
                        sid = "skill-" + hashlib.sha256((source_id + "\0" + relative).encode()).hexdigest()
                        seen_files.add(file_identity)
                        skills.append({"id": sid, "name": skill_name, "description": description,
                                       "source": source_id, "path": str(resolved),
                                       "estimatedTokens": max(1, math.ceil(len((skill_name + description + str(resolved)).encode()) / 4))})
                    elif entry.name not in {".git", "node_modules", "__pycache__"} and entry.is_dir(follow_symlinks=True):
                        if depth < MAX_SCAN_DEPTH:
                            children.append((path, depth + 1))
                        else:
                            truncated = True
                stack.extend(reversed(children))
            except (OSError, UnicodeError, RuntimeError):
                warnings.append(f"Some skills in {name} could not be read.")
    if truncated:
        warnings.append("The skill catalog reached its scan limit. Configure narrower source folders to include remaining skills.")
    skills.sort(key=lambda item: (item["name"].casefold(), item["id"]))
    return {"skills": skills, "sources": source_rows, "warnings": list(dict.fromkeys(warnings))}


class AgentRoles:
    """A per-machine revision, atomically updated with optimistic concurrency."""
    def __init__(self, path=":memory:", *, machine_id="", environ: Mapping[str, str] | None = None):
        self.machine_id = machine_id
        self.sources = configured_sources({} if environ is None else environ)
        self._lock = threading.RLock()
        self._temporary = tempfile.TemporaryDirectory(prefix="herdr-role-skills-") if str(path) == ":memory:" else None
        self._package_root = (Path(self._temporary.name) if self._temporary else Path(path).expanduser().absolute().parent) / "agent-role-skills"
        if str(path) != ":memory:":
            path = Path(path).expanduser().absolute()
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
            try:
                meta = os.fstat(fd)
                if not stat.S_ISREG(meta.st_mode) or meta.st_uid != os.getuid():
                    raise AgentRoleError("Unsafe agent roles database", status=500)
                os.fchmod(fd, 0o600)
            finally:
                os.close(fd)
        self._db = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=FULL")
        self._db.execute("CREATE TABLE IF NOT EXISTS agent_roles (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)")
        self._db.execute("INSERT OR IGNORE INTO agent_roles VALUES (1, ?)",
                         (json.dumps({"revision": 0, "roles": _seed_roles(), "teams": {}, "packages": {}, "rolePackages": {}}),))

    def close(self):
        with self._lock:
            self._db.close()
        if self._temporary:
            self._temporary.cleanup()

    def _state(self):
        state = json.loads(self._db.execute("SELECT payload FROM agent_roles WHERE id=1").fetchone()[0])
        # Additive migration: old clients keep their worker identities and their
        # revision. The first mutation persists these defaulted fields.
        state["roles"].setdefault(PR_REVIEW_BUILTIN_ID, _seed_roles()[PR_REVIEW_BUILTIN_ID])
        for role in state["roles"].values():
            for key, value in {"purpose": "worker", "reviewPrompt": "", "group": "", "avatar": "review"}.items():
                role.setdefault(key, value)
        if "teams" not in state:
            # Earlier companions stored a team name on each role. Name-derived IDs
            # stay stable across reads until the first mutation persists them.
            state["teams"] = {}
            for role in state["roles"].values():
                name = role["group"].strip()
                if name and not role.get("teamId"):
                    tid = str(uuid.uuid5(_TEAM_NAMESPACE, name.casefold()))
                    state["teams"].setdefault(tid, {"id": tid, "name": name})
                    role["teamId"] = tid
        # Membership is the team ID. The name is derived so older clients still read it.
        for role in state["roles"].values():
            team = state["teams"].get(role.get("teamId", ""))
            role["teamId"], role["group"] = (team["id"], team["name"]) if team else ("", "")
        return state

    def _catalog(self, state):
        catalog = skill_catalog(self.sources)
        imported = []
        for sid, package in state.get("packages", {}).items():
            path = self._package_root / package["digest"] / "SKILL.md"
            if path.is_file():
                imported.append({"id": sid, **{key: package[key] for key in ("name", "description", "source")},
                                 "path": str(path), "estimatedTokens": package["estimatedTokens"]})
        imported_ids = {item["id"] for item in imported}
        catalog["skills"] = sorted(imported + [item for item in catalog["skills"] if item["id"] not in imported_ids],
                                   key=lambda item: (item["name"].casefold(), item["id"]))
        source_ids = {item["id"] for item in catalog["sources"]}
        for item in imported:
            if item["source"] not in source_ids:
                catalog["sources"].append({"id": item["source"], "name": item["source"], "path": "", "available": True})
                source_ids.add(item["source"])
        available = {item["id"] for item in catalog["skills"]}
        catalog["missingRoleSkills"] = {}
        for role in state["roles"].values():
            bindings = state.get("rolePackages", {}).get(role["id"], {})
            missing_ids = [sid for sid in role["skillIds"] or []
                           if (not (self._package_root / bindings[sid] / "SKILL.md").is_file() if sid in bindings
                               else sid not in available)]
            if missing_ids:
                catalog["missingRoleSkills"][role["id"]] = missing_ids
                missing = len(missing_ids)
                noun = "skill is" if missing == 1 else "skills are"
                catalog["warnings"].append(f"{role['name']}: {missing} selected {noun} unavailable on this execution computer. "
                                           "Update Copies or remove unavailable selections.")
        return catalog

    def overview(self):
        with self._lock:
            state = self._state()
        return {"ok": True, "capability": CAPABILITY, "capabilities": [PR_REVIEW_CAPABILITY, PR_REVIEW_TEAMS_CAPABILITY],
                "machineId": self.machine_id, "revision": state["revision"], "roles": list(state["roles"].values()),
                "teams": sorted(state["teams"].values(), key=lambda team: (team["name"].casefold(), team["id"])),
                **self._catalog(state)}

    def snapshot(self, role_id):
        role_id = _role_id(role_id)
        with self._lock:
            state = self._state()
            role = state["roles"].get(role_id)
        if role is None:
            raise AgentRoleError("Agent role no longer exists on this machine", code="agent_role_not_found", status=404)
        if role["skillIds"] is None:
            paths, missing = None, []
        else:
            catalog = {skill["id"]: skill["path"] for skill in skill_catalog(self.sources)["skills"]}
            for sid, digest in state.get("rolePackages", {}).get(role_id, {}).items():
                path = self._package_root / digest / "SKILL.md"
                if path.is_file():
                    catalog[sid] = str(path)
                else:
                    catalog.pop(sid, None)
            paths = [catalog[sid] for sid in role["skillIds"] if sid in catalog]
            missing = [sid for sid in role["skillIds"] if sid not in catalog]
        return {**role, "revision": state["revision"], "skillPaths": paths, "missingSkillIds": missing}

    def delegation_catalog(self):
        with self._lock:
            roles = self._state()["roles"].values()
        return [{key: role[key] for key in ("id", "name", "whenToUse", "modelProfile")}
                for role in roles if role["purpose"] == "worker" and role["id"] not in {"first_mate", "second_mate", "recovery_advisor"}]

    def review_catalog(self):
        with self._lock:
            return [role for role in self._state()["roles"].values() if role["purpose"] == "pr_review"]

    def _validate_role(self, value, old, catalog, teams):
        if not isinstance(value, dict):
            raise AgentRoleError("role must be an object")
        fields = {"id", "name", "builtin", "locked", "whenToUse", "systemPrompt", "modelProfile", "allowDelegation", "skillIds",
                  "purpose", "reviewPrompt", "group", "teamId", "avatar"}
        if set(value) - fields:
            raise AgentRoleError("role contains unsupported fields")
        rid = _role_id(value.get("id"))
        builtin = rid in BUILTIN_IDS
        purpose = value.get("purpose", old.get("purpose", "worker") if old else "worker")
        if not isinstance(purpose, str) or purpose not in {"worker", "pr_review"} or (old and purpose != old["purpose"]):
            raise AgentRoleError("Role purpose must be worker or pr_review and cannot change after creation")
        if builtin and purpose != ("pr_review" if rid == PR_REVIEW_BUILTIN_ID else "worker"):
            raise AgentRoleError("Built-in roles retain their purpose")
        if old and old["locked"]:
            raise AgentRoleError("Recovery Advisor is managed by the system and cannot be edited", code="agent_role_locked", status=403)
        if (value.get("builtin", builtin) is not builtin or value.get("locked", False) is not False):
            raise AgentRoleError("Role identity and system restrictions cannot be changed")
        name = _text(value.get("name"), "name", 120).strip()
        if not name or any(char in name for char in "\n\r\t"):
            raise AgentRoleError("Role name must be one nonempty line")
        when = _text(value.get("whenToUse", ""), "whenToUse", 4096)
        prompt = _text(value.get("systemPrompt", ""), "systemPrompt", MAX_PROMPT_BYTES)
        profile = value.get("modelProfile")
        if purpose == "pr_review" and profile != "default":
            raise AgentRoleError("PR reviewers use the execution computer's default model")
        if purpose == "worker" and (not isinstance(profile, str) or profile not in DELEGATION_PROFILES):
            raise AgentRoleError("modelProfile must be planning, execution, architect, or research_scout")
        if builtin and purpose == "worker" and profile != next(item[3] for item in _BUILTINS if item[0] == rid):
            raise AgentRoleError("Built-in roles retain their configured model profile")
        delegation = value.get("allowDelegation", False if not old else old["allowDelegation"])
        if type(delegation) is not bool:
            raise AgentRoleError("allowDelegation must be a boolean")
        if purpose == "pr_review" and delegation:
            raise AgentRoleError("PR reviewers cannot delegate")
        review_prompt = _text(value.get("reviewPrompt", old.get("reviewPrompt", "") if old else ""), "reviewPrompt", MAX_PROMPT_BYTES)
        team_id = self._role_team(value, old, teams)
        avatar = value.get("avatar", old.get("avatar", "review") if old else "review")
        if not isinstance(avatar, str) or avatar not in ROLE_AVATARS:
            raise AgentRoleError("Unknown agent avatar")
        skills = value.get("skillIds", [] if not old else old["skillIds"])
        if purpose == "pr_review" and skills is None:
            raise AgentRoleError("PR reviewers require an explicit skill selection")
        if skills is not None:
            if (not isinstance(skills, list) or len(skills) > MAX_SKILLS
                    or any(not isinstance(sid, str) or not re.fullmatch(r"skill[_-][0-9a-f]{64}", sid) for sid in skills)):
                raise AgentRoleError("skillIds must be null or a list of catalog skill IDs")
            skills = list(dict.fromkeys(skills))
            retained = set(old.get("skillIds") or []) if old else set()
            if any(sid not in catalog and sid not in retained for sid in skills):
                raise AgentRoleError("A selected skill is unavailable. Refresh the catalog before adding it.")
        return {"id": rid, "name": name, "builtin": builtin, "locked": False, "whenToUse": when,
                "systemPrompt": prompt, "modelProfile": profile, "allowDelegation": delegation, "skillIds": skills,
                "purpose": purpose, "reviewPrompt": review_prompt, "group": teams[team_id]["name"] if team_id else "",
                "teamId": team_id, "avatar": avatar}

    @staticmethod
    def _role_team(value, old, teams):
        """Clients with saved teams send an ID. Older clients send only a name."""
        if "teamId" in value:
            team_id = value["teamId"]
            if not isinstance(team_id, str):
                raise AgentRoleError("teamId must be a saved team ID or empty")
            if team_id and team_id not in teams:
                raise AgentRoleError("The selected team no longer exists. Reload and choose another team.",
                                     code="agent_role_team_missing", status=409)
            return team_id
        if "group" not in value:
            return old.get("teamId", "") if old else ""
        name = _text(value["group"], "group", 120).strip()
        if any(char in name for char in "\n\r\t"):
            raise AgentRoleError("Group must be a single line")
        if not name:
            return ""
        if old and old.get("teamId") in teams and teams[old["teamId"]]["name"] == name:
            return old["teamId"]
        existing = next((tid for tid, team in teams.items() if team["name"].casefold() == name.casefold()), None)
        if existing:
            return existing
        if len(teams) >= MAX_TEAMS:
            raise AgentRoleError("The maximum number of teams has been reached")
        team_id = str(uuid.uuid4())
        teams[team_id] = {"id": team_id, "name": name}
        return team_id

    @staticmethod
    def _save_team(state, value):
        if not isinstance(value, dict) or set(value) - {"id", "name"}:
            raise AgentRoleError("team must be an object with an ID and a name")
        team_id, name = _team_id(value.get("id")), _team_name(value.get("name"))
        teams = state["teams"]
        if any(tid != team_id and team["name"].casefold() == name.casefold() for tid, team in teams.items()):
            raise AgentRoleError("A team with this name already exists")
        if team_id not in teams and len(teams) >= MAX_TEAMS:
            raise AgentRoleError("The maximum number of teams has been reached")
        teams[team_id] = {"id": team_id, "name": name}
        for role in state["roles"].values():
            if role.get("teamId") == team_id:
                role["group"] = name

    @staticmethod
    def _delete_team(state, value):
        team_id = _team_id(value)
        if state["teams"].pop(team_id, None) is None:
            raise AgentRoleError("Team no longer exists", code="agent_role_team_missing", status=404)
        for role in state["roles"].values():
            if role.get("teamId") == team_id:
                role["teamId"], role["group"] = "", ""

    def mutate(self, body):
        if not isinstance(body, dict):
            raise AgentRoleError("Agent role request must be an object")
        expected = body.get("expectedRevision")
        if type(expected) is not int or expected < 0:
            raise AgentRoleError("expectedRevision must be a nonnegative integer")
        action = body.get("action")
        if not isinstance(action, str) or action not in {"save", "delete", "saveTeam", "deleteTeam"}:
            raise AgentRoleError("action must be save, delete, saveTeam, or deleteTeam")
        bundles = validate_bundles(body.get("skillBundles", []), error=AgentRoleError, parse_metadata=_metadata)
        if action != "save" and bundles:
            raise AgentRoleError("Skill packages can only accompany a saved role")
        catalog_rows = {skill["id"]: skill for skill in skill_catalog(self.sources)["skills"]} if action == "save" else {}
        catalog = set(catalog_rows) | set(bundles)
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                state = self._state()
                if state["revision"] != expected:
                    raise AgentRoleError("Agent Roles changed. Reload and reconcile without overwriting your draft.",
                                         code="agent_role_conflict", status=409)
                if action == "save":
                    value = body.get("role")
                    rid = _role_id(value.get("id")) if isinstance(value, dict) else None
                    old = state["roles"].get(rid)
                    role = self._validate_role(value, old, catalog | set(state.get("packages", {})), state["teams"])
                    chosen_metadata = {**catalog_rows, **state.get("packages", {}), **bundles}
                    names = set()
                    for sid in role["skillIds"] or []:
                        if sid not in chosen_metadata:
                            continue
                        name = chosen_metadata[sid]["name"].casefold()
                        if name in names:
                            raise AgentRoleError("Selected skills have duplicate names. Choose only one skill with each name.")
                        names.add(name)
                    if bundles.keys() - set(role["skillIds"] or []):
                        raise AgentRoleError("Skill packages must be selected for the saved role")
                    if old is None and len(state["roles"]) >= MAX_ROLES:
                        raise AgentRoleError("The maximum number of agent roles has been reached")
                    packages = state.setdefault("packages", {})
                    bindings = state.setdefault("rolePackages", {})
                    existing = bindings.get(role["id"], {})
                    chosen = {sid: existing.get(sid, packages[sid]["digest"] if sid in packages else None)
                              for sid in role["skillIds"] or []}
                    for sid, bundle in bundles.items():
                        installed = install_bundle(self._package_root, bundle, error=AgentRoleError)
                        packages[sid] = {key: bundle[key] for key in ("name", "description", "source")}
                        packages[sid]["digest"] = installed.name
                        packages[sid]["estimatedTokens"] = max(1, math.ceil(len((bundle["name"] + bundle["description"] + str(installed / "SKILL.md")).encode()) / 4))
                        chosen[sid] = installed.name
                    bindings[role["id"]] = {sid: digest for sid, digest in chosen.items() if digest is not None}
                    state["roles"][role["id"]] = role
                elif action == "saveTeam":
                    self._save_team(state, body.get("team"))
                elif action == "deleteTeam":
                    self._delete_team(state, body.get("teamId"))
                else:
                    rid = _role_id(body.get("roleId"))
                    if rid in BUILTIN_IDS:
                        raise AgentRoleError("Built-in roles cannot be deleted", code="agent_role_locked", status=403)
                    if rid not in state["roles"]:
                        raise AgentRoleError("Agent role no longer exists", code="agent_role_not_found", status=404)
                    del state["roles"][rid]
                    state.setdefault("rolePackages", {}).pop(rid, None)
                state["revision"] += 1
                self._db.execute("UPDATE agent_roles SET payload=? WHERE id=1", (json.dumps(state, ensure_ascii=False),))
                self._db.execute("COMMIT")
            except Exception:
                if self._db.in_transaction:
                    self._db.execute("ROLLBACK")
                raise
        return self.overview()
