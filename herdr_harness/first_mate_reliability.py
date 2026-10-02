"""Persistent, bounded recovery within an already human-authorized First Mate stage.

Called only by the fenced scheduler. The independent guardian supervises that
scheduler; neither a wall-clock timer nor an advisor can authorize a new stage.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import time

from .first_mate_backup import BackupUnavailable, capture_backup, git_bytes
from .first_mate_runtime import _bounded, _locked, _read_json, _recent_records, _write_json, _ledger_event, TERMINAL
from .first_mate_store import FirstMateError

# What an interrupted or failed command may have done beyond this machine: a
# push, release, upload, deploy, remote API call, remote shell or message.
# Only those need a human before a successor continues. Everything else left
# its effects on this machine, where the successor inspects them first. The
# patterns match anywhere in the command, so a stray mention errs toward
# asking the human.
_PROGRAM_END = r"(?=$|[\s;&|(){}`\"'])"
_REMOTE_PROGRAM = re.compile(
    r"(?:^|[\s;&|(){}`$\"'=/])(?:ssh|scp|sftp|rsync|mosh|gh|hub|glab|aws|gcloud|gsutil|az|kubectl|helm|"
    r"terraform|tofu|pulumi|heroku|fly|flyctl|vercel|netlify|firebase|wrangler|fastlane|twine|sendmail|mailx?|"
    r"osascript|shortcuts|tailscale|ngrok|ncat|nc|telnet|l?ftp|rclone|s3cmd|doctl|message-me|pi|claude|codex|"
    r"herdr-[a-z-]+)" + _PROGRAM_END, re.I)
_REMOTE_SUBCOMMAND = re.compile(
    r"\bgit\b[^;&|\n]*?\s(?:push|send-email)\b"
    r"|\b(?:npm|pnpm|yarn|bun|cargo|poetry|flutter|dart|gem|pod|dotnet|swift|uv)\b[^;&|\n]*?\s"
    r"(?:publish|push|trunk|package-registry)\b"
    r"|\b(?:docker|podman|buildah)\b[^;&|\n]*?\s(?:push|login)\b"
    r"|\bxcrun\s+(?:altool|notarytool)\b", re.I)
_REMOTE_TRANSFER = re.compile(
    r"\b(?:curl|wget|xh|https?|httpie)\b[^;&|\n]*?(?:\s-(?:d|F|T)\b|\s--data|\s--form|\s--upload-file|\s--json\b"
    r"|\s-X\s*(?:POST|PUT|PATCH|DELETE)\b|\s--request[=\s]+(?:POST|PUT|PATCH|DELETE)\b|\s--post-|\s--method|\s--body-)",
    re.I)
# A program, script, target or path word naming a release step. Flags such as
# --release and capitalized build settings (-configuration Release) are not.
_REMOTE_WORD = re.compile(
    r"(?:^|[\s;&|(){}`'\"/=])(?!-)[\w.~-]*(?:deploy|publish|upload|notari[sz]e|distribute|submit|release|land-pr)"
    r"[\w.~-]*" + _PROGRAM_END)
_REMOTE_SCRIPT = re.compile(r"[\w./~-]*(?:push|land)[\w.-]*\.(?:sh|bash|zsh|py|rb|js|mjs|ts|pl|swift)\b")
# The ledger keeps a command's first 4000 characters; a longer one may hide
# its remote part.
_RETAINED_COMMAND = 4000


def remote_effect(row) -> bool:
    """Whether a failed or unfinished call may have changed something beyond
    this machine, so a human inspects it before any continuation."""
    tool = row.get('tool')
    if tool in ('edit', 'write'):
        return False  # A file on this machine.
    if tool != 'bash':
        return True  # An unknown tool may reach anywhere.
    command = row.get('command')
    if not isinstance(command, str) or not command.strip() or len(command) >= _RETAINED_COMMAND:
        return True
    return any(pattern.search(command) for pattern in
               (_REMOTE_PROGRAM, _REMOTE_SUBCOMMAND, _REMOTE_TRANSFER, _REMOTE_WORD, _REMOTE_SCRIPT))


def epoch(value, default: float) -> float:
    try:
        number = datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp() if isinstance(value, str) else float(value)
        return number if math.isfinite(number) else default
    except (TypeError, ValueError, OverflowError):
        return default


def iso(value: float) -> str:
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00', 'Z')


class FirstMateReliability:
    def __init__(self, runtime):
        self.runtime = runtime
        self.store = runtime.store
        self.root = runtime.root / 'reliability'
        self.enabled = runtime.environ.get('HERDR_FIRST_MATE_AUTO_RECOVERY', 'true').lower() not in {'0', 'false', 'no'}
        self.interval = _bounded(runtime.environ, 'HERDR_FIRST_MATE_SWEEP_SECONDS', 3600, 300, 86400)
        self.coordinator_interval = _bounded(runtime.environ, 'HERDR_FIRST_MATE_COORDINATOR_GAP_SECONDS', 60, 10, 300)
        self.grace = _bounded(runtime.environ, 'HERDR_FIRST_MATE_NUDGE_GRACE_SECONDS', 300, 60, 3600)
        saved = _read_json(self.root / 'sweep.json', {})
        self.next_sweep = min(epoch(saved.get('next_epoch'), 0), time.time() + self.interval)
        self.last_sweep_at = saved.get('last_sweep_at')
        self.next_coordinator_check = min(epoch(saved.get('next_coordinator_epoch'), 0), time.time() + self.coordinator_interval)
        self._last_tick = 0.0

    def health(self) -> dict:
        return {'automatic_recovery': self.enabled, 'sweep_interval_seconds': self.interval,
                'coordinator_gap_interval_seconds': self.coordinator_interval,
                'last_sweep_at': self.last_sweep_at,
                'next_sweep_at': iso(self.next_sweep) if self.next_sweep else None}

    def _path(self, assignment_id: str) -> Path:
        return self.root / (assignment_id + '.json')

    def _eligible(self, feature: dict) -> bool:
        if feature['status'] not in {'running', 'recovering'} or not feature.get('current_visit_id'):
            return False
        if any(m['role'] == 'user' for m in self.store.pending_messages(feature['id'])):
            return False
        snapshot = self.store.snapshot(feature['id'])
        return (any(v['id'] == feature['current_visit_id'] and v['status'] == 'running' for v in snapshot['visits'])
                and not any(a['metadata'].get('human_gate', {}).get('status') == 'pending' for a in snapshot['assignments']))

    def _event(self, job: dict, kind: str, summary: str, identity: str, payload=None):
        self.runtime._event(job['feature_id'], 'reliability.' + kind, summary,
                            {'assignment_id': job['claim']['id'], 'job_id': job['id'], **(payload or {})}, identity)

    def _position(self, assignment: dict, job: dict) -> str:
        progress = assignment.get('metadata', {}).get('progress', {})
        # Timestamps, token traffic, handoff documents and generation changes are
        # deliberately not progress. Equal self-reports do not reset this clock.
        data = {'progress': {k: progress.get(k) for k in ('summary', 'next_action', 'evidence')}}
        if job.get('workspace_mode') == 'isolated':
            try:
                data['head'] = git_bytes(job['cwd'], 'rev-parse', 'HEAD', limit=1024).decode().strip()
                data['diff'] = hashlib.sha256(git_bytes(job['cwd'], 'diff', '--no-ext-diff', '--no-textconv', 'HEAD', '--', limit=8 * 1024 * 1024)).hexdigest()
                # Status observes new/deleted paths; the worker's explicit evidence
                # handles detailed progress inside non-ignored untracked source.
                data['status'] = git_bytes(job['cwd'], 'status', '--porcelain', limit=1024 * 1024).decode(errors='replace')
            except (OSError, BackupUnavailable):
                data['workspace_evidence'] = 'unavailable or exceeds the bounded inspection limit'
        children = [a for a in self.store.list_assignments(feature_id=job['feature_id'])
                    if a.get('metadata', {}).get('parent_assignment_id') == assignment['id']]
        data['children'] = [(a['id'], a['status'], a['verdict']) for a in children]
        return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()

    def recovery_progress_key(self, assignment: dict, job: dict) -> str | None:
        """Independent facts for retry budgets, never reworded model progress.

        Missing/oversized evidence cannot refresh a budget. Hash untracked source
        as well as its names so a real edit is distinguished from a context loop.
        """
        data = {}
        if job.get('workspace_mode') == 'isolated':
            try:
                root = Path(job['cwd']).resolve()
                remaining, files_left, repositories_left = 8 * 1024 * 1024, 10000, 8
                deadline = time.monotonic() + 15

                def workspace(cwd):
                    nonlocal remaining, files_left, repositories_left
                    repositories_left -= 1
                    if repositories_left < 0:
                        raise BackupUnavailable('Nested workspace inspection limit reached')

                    def inspect(*args, limit):
                        if time.monotonic() >= deadline:
                            raise BackupUnavailable('Workspace progress inspection deadline reached')
                        return git_bytes(str(cwd), '--no-pager', '-c', 'core.fsmonitor=false', *args, limit=limit)

                    # Git lists an untracked nested repository as one directory,
                    # not its files. Inspect that exact root, never the parent
                    # repository again or a path inferred from an agent summary.
                    observed_root = Path(os.fsdecode(inspect('rev-parse', '--show-toplevel', limit=4096)).strip()).resolve()
                    if observed_root != cwd or not cwd.is_relative_to(root):
                        raise BackupUnavailable('Nested workspace escaped its isolated root')
                    result = {'head': inspect('rev-parse', 'HEAD', limit=1024).decode().strip()}
                    diff = inspect('diff', '--no-ext-diff', '--no-textconv', 'HEAD', '--', limit=remaining)
                    remaining -= len(diff)
                    result['diff'] = hashlib.sha256(diff).hexdigest()
                    names = sorted(filter(None, inspect('ls-files', '--others', '--exclude-standard', '-z', limit=1024 * 1024).split(b'\0')))
                    files_left -= len(names)
                    if files_left < 0:
                        raise BackupUnavailable('Workspace source count exceeds the inspection limit')
                    untracked = []
                    for name in names:
                        if time.monotonic() >= deadline:
                            raise BackupUnavailable('Workspace progress inspection deadline reached')
                        relative = Path(os.fsdecode(name))
                        path = cwd / relative
                        if relative.is_absolute() or '..' in relative.parts or not path.parent.resolve().is_relative_to(cwd):
                            raise BackupUnavailable('Source path escaped its workspace')
                        info = path.lstat()
                        if stat.S_ISLNK(info.st_mode):
                            untracked.append((os.fsdecode(name), 'symlink', os.readlink(path)))
                            continue
                        if stat.S_ISDIR(info.st_mode):
                            nested = path.resolve()
                            if nested == cwd or not nested.is_relative_to(cwd):
                                raise BackupUnavailable('Invalid nested workspace')
                            untracked.append((os.fsdecode(name), 'repository', workspace(nested)))
                            after = path.lstat()
                            if not stat.S_ISDIR(after.st_mode) or after.st_ino != info.st_ino:
                                raise BackupUnavailable('Nested workspace changed during inspection')
                            continue
                        if not stat.S_ISREG(info.st_mode) or info.st_size > remaining:
                            raise BackupUnavailable('Source exceeds the bounded inspection limit')
                        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                        with os.fdopen(descriptor, 'rb') as source:
                            actual = os.fstat(source.fileno())
                            if not stat.S_ISREG(actual.st_mode) or (actual.st_ino, actual.st_size, actual.st_mtime_ns) != (info.st_ino, info.st_size, info.st_mtime_ns):
                                raise BackupUnavailable('Source changed during inspection')
                            content = source.read(remaining + 1)
                            after = os.fstat(source.fileno())
                            if len(content) > remaining or (after.st_size, after.st_mtime_ns) != (actual.st_size, actual.st_mtime_ns):
                                raise BackupUnavailable('Source changed during inspection')
                        remaining -= len(content)
                        untracked.append((os.fsdecode(name), hashlib.sha256(content).hexdigest()))
                    result['untracked'] = untracked
                    return result

                data = workspace(root)
            except (OSError, ValueError, BackupUnavailable):
                return None
        children = [a for a in self.store.list_assignments(feature_id=job['feature_id'])
                    if a.get('metadata', {}).get('parent_assignment_id') == assignment['id'] and a['status'] == 'completed']
        data['completed_children'] = sorted((a['id'], a['verdict'], a.get('code_revision')) for a in children)
        return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest()

    def progress_lease_until(self, job: dict, assignment: dict) -> float:
        """A wait belongs to its live requesting execution, never its successor."""
        progress = assignment.get('metadata', {}).get('progress', {})
        directory = self.runtime._job_dir(job)
        if (assignment['generation'] != job['claim']['generation']
                or progress.get('generation') != job['claim']['generation']
                or progress.get('native_session_id') != job.get('native_session_id')
                or epoch(progress.get('recorded_epoch'), 0) < epoch(job['created_at'], float('inf'))
                or (directory / 'finalized.json').exists()
                or _read_json(directory / 'status.json', {}).get('ended')
                or not _locked(directory / 'writer.lock')):
            return 0
        return min(epoch(progress.get('wait_until_epoch'), 0), epoch(progress.get('recorded_epoch'), 0) + 3600)

    def owns(self, job: dict) -> bool:
        directory = self.runtime._job_dir(job)
        assignment = self.store.get_assignment(job['claim']['id'])
        if (assignment['generation'] != job['claim']['generation']
                or (directory / 'finalized.json').exists()
                or _read_json(directory / 'status.json', {}).get('ended')
                or not _locked(directory / 'writer.lock')):
            return False
        record = _read_json(self._path(job['claim']['id']), {})
        lease_until = (self.progress_lease_until(job, assignment) if record.get('lease_source') == 'progress'
                       else epoch(record.get('lease_until'), 0))
        return record.get('job_id') == job['id'] and (record.get('phase') in {'assessing', 'nudge_pending', 'nudged', 'stopping'} or lease_until > time.time())

    def tick(self, jobs: list[dict], *, now: float | None = None, excluded_feature_ids: set[str] | None = None):
        if not self.enabled or not self.runtime.capabilities()['available']:
            return
        if now is None:
            if time.monotonic() - self._last_tick < 10:
                return
            self._last_tick = time.monotonic()
            now = time.time()
        due = now >= self.next_sweep
        coordinator_due = now >= self.next_coordinator_check
        for feature in self.store.list_features('all'):
            # A feature whose reconciliation failed has uncertain current facts.
            # Defer it without suspending supervision of independent features.
            if feature['id'] in (excluded_feature_ids or ()) or not self._eligible(feature):
                continue
            assignments = [a for a in self.store.list_assignments(feature_id=feature['id'])
                           if self.store.assignment_is_in_current_visit(a['id'])]
            for assignment in assignments:
                if assignment['status'] in TERMINAL | {'queued', 'waiting_children'}:
                    continue
                candidates = [j for j in jobs if j['kind'] == 'worker' and j['claim']['id'] == assignment['id']
                              and j['claim']['generation'] == assignment['generation']]
                job = max(candidates, key=lambda j: j['created_at'], default=None)
                if not job:
                    if due:
                        self._block(feature, 'An active assignment has no retained execution. Automatic replay is unsafe.', 'missing-job:' + assignment['id'] + ':' + str(assignment['generation']))
                    continue
                if assignment['status'] == 'recovering':
                    self.recover(job, {'error': 'Supervisor receipt is missing'})
                    continue
                record = _read_json(self._path(assignment['id']), {})
                active = record.get('job_id') == job['id'] and record.get('phase') in {'assessing', 'nudge_pending', 'nudged', 'stopping'}
                if due or active:
                    self._inspect(feature, assignment, job, record, now)
            if coordinator_due:
                self._coordinator_gap(feature, assignments, jobs, now)
        if due:
            self.last_sweep_at = iso(now)
            self.next_sweep = now + self.interval
        if coordinator_due:
            self.next_coordinator_check = now + self.coordinator_interval
        if due or coordinator_due:
            _write_json(self.root / 'sweep.json', {'last_sweep_at': self.last_sweep_at, 'next_epoch': self.next_sweep,
                                                 'next_coordinator_epoch': self.next_coordinator_check})

    def _inspect(self, feature, assignment, job, record, now):
        directory = self.runtime._job_dir(job)
        if not self._eligible(self.store.get_feature(feature['id'])):
            return
        if not _locked(directory / 'writer.lock'):
            # Ordinary reconciliation repairs unstarted claims, final receipts,
            # child continuation and unknown launches before this sweep runs.
            return
        fingerprint = self._position(assignment, job)
        progress = assignment.get('metadata', {}).get('progress', {})
        wait_until = self.progress_lease_until(job, assignment)
        if record.get('lease_source') == 'progress' and wait_until <= now:
            record.pop('lease_until', None)
            record.pop('lease_source', None)
        if record.get('job_id') != job['id']:
            record = {'job_id': job['id'], 'assignment_id': assignment['id'], 'phase': 'observing',
                      'fingerprint': fingerprint, 'progress_epoch': max(epoch(job['created_at'], now), epoch(progress.get('recorded_epoch'), 0)), 'round': 0}
        elif record.get('fingerprint') != fingerprint:
            was_active = record.get('phase') in {'assessing', 'nudge_pending', 'nudged'}
            # Once an abort was requested, finish the stop/ownership transition.
            if record.get('phase') != 'stopping':
                record.update(phase='observing', fingerprint=fingerprint, progress_epoch=now)
                if was_active:
                    self._event(job, 'progress_restored', 'Observable progress resumed after the stability check.', f"progress-restored:{job['id']}:{record['round']}")
        if record['phase'] == 'stopping':
            if now >= record['deadline']:
                self._block(feature, 'The stale worker did not confirm its stop. No replacement writer was started.', 'stop-unconfirmed:' + job['id'])
            _write_json(self._path(assignment['id']), record)
            return
        if wait_until > now:
            record.update(phase='observing', lease_until=wait_until, lease_source='progress')
        elif record.get('phase') == 'nudge_pending':
            self._nudge(job, record, now)
        elif record.get('phase') == 'assessing':
            advisor_dir = self.runtime.jobs_root / record['advisor_job_id']
            if now >= record['deadline'] or (advisor_dir / 'finalized.json').exists():
                self._nudge(job, record, now)
        elif record.get('phase') == 'nudged':
            if now >= record['deadline']:
                job['reliability_stop'] = True
                self.runtime._save_job(job)
                self.runtime._control(job, 'abort', 'No progress after the bounded stability nudge. Preserve evidence for checkpointed continuation.', request_id='stale-stop:' + job['id'] + ':' + str(record['round']))
                record.update(phase='stopping', deadline=now + 60)
                self._event(job, 'stop_requested', 'Stale worker did not respond to the nudge. Waiting for its verified stop before recovery.', 'stale-stop:' + job['id'] + ':' + str(record['round']))
        elif now >= record.get('lease_until', 0) and now - record['progress_epoch'] >= self.interval:
            record['round'] += 1
            events = _recent_records(directory / 'events.jsonl', maximum=100)
            evidence = [e for e in events if e.get('type') in {'message_end', 'tool_execution_start', 'tool_execution_end'}][-20:]
            reason = 'No changed progress evidence during the hourly stability interval. Live token/tool traffic is not proof of progress.'
            advisor = self.runtime._new_job(feature, kind='advisor', claim={'id': f"stability:{job['id']}:{record['round']}"}, parent_job=job,
                prompt=reason + '\nJudge whether this is a legitimate long build/external wait, a context reread loop, or a stranded worker. Use continue only with concrete evidence; otherwise steer, handoff, or pause for a real human blocker. Never authorize new scope.\nCurrent position:\n' + json.dumps(progress) + '\nAssignment:\n' + job['claim'].get('prompt', '') + '\nRecent evidence:\n' + json.dumps([_ledger_event(e) for e in evidence]))
            advisor['reliability_assessment'] = True
            self.runtime._save_job(advisor)
            record.update(phase='assessing', advisor_job_id=advisor['id'], deadline=now + advisor['timeout_seconds'] + 30)
            _write_json(self._path(assignment['id']), record)
            self._event(job, 'stale_suspected', reason, f"stability:{job['id']}:{record['round']}")
            self.runtime._launch(advisor)
        _write_json(self._path(assignment['id']), record)

    def _nudge(self, job, record, now, instruction=''):
        if not self._eligible(self.store.get_feature(job['feature_id'])):
            return
        if record.get('phase') != 'nudge_pending':
            text = ('Service stability check, not new human authorization. Report concrete progress and the exact next step with fm_progress. '
                    'For a legitimate long build/wait, include evidence and a bounded wait_seconds lease. '
                    'If stuck in context rereads, use the latest checkpoint rather than rereading all history. '
                    'Continue from the checkpoint when possible; do not rotate merely to answer this check. '
                    'Only if this executor cannot continue, save fm_handoff at a safe boundary and end. Preserve all work and human gates. ' + instruction)
            # Freeze payload and deadline BEFORE creating a control. A crash may
            # lose the advisor response, but can never change the replay payload.
            record.update(phase='nudge_pending', deadline=now + self.grace, nudge_text=text)
            _write_json(self._path(job['claim']['id']), record)
        self.runtime._control(job, 'steer', record['nudge_text'], request_id=f"stale-nudge:{job['id']}:{record['round']}")
        self._event(job, 'nudged', 'Sent a bounded progress/handoff nudge to the stale worker.', f"stale-nudge:{job['id']}:{record['round']}")
        record['phase'] = 'nudged'
        _write_json(self._path(job['claim']['id']), record)

    def advice(self, advisor, params):
        parent = _read_json(self.runtime.jobs_root / advisor['parent_job_id'] / 'job.json')
        if not parent:
            return False
        record = _read_json(self._path(parent['claim']['id']), {})
        assignment = self.store.get_assignment(parent['claim']['id'])
        feature = self.store.get_feature(parent['feature_id'])
        if (record.get('advisor_job_id') != advisor['id'] or record.get('phase') != 'assessing'
                or assignment['generation'] != parent['claim']['generation'] or not self._eligible(feature)):
            return False
        if params['decision'] == 'continue':
            record.update(phase='observing', lease_until=time.time() + self.interval, lease_source='advisor')
            _write_json(self._path(assignment['id']), record)
        elif params['decision'] in {'steer', 'handoff'}:
            instruction = params.get('instruction') or params['reason']
            if params['decision'] == 'handoff':
                instruction = 'Prefer a fresh checkpointed handoff now. ' + instruction
            self._nudge(parent, record, time.time(), instruction)
        else:
            self.store.request_human_gate(assignment['id'], assignment['generation'], assignment['native_session_id'], params['reason'], 'stability-pause:' + advisor['id'])
            self.runtime._control(parent, 'abort', params['reason'], request_id='stability-pause:' + advisor['id'])
        return True

    def _effect_status(self, job):
        def invalid(reason):
            return {'safe': False, 'has_mutations': True, 'issues': [{'reason': reason}], 'local': []}

        path = self.runtime._job_dir(job) / 'effects.jsonl'
        if job.get('safety_ledger_version') != 1 or not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
            return invalid('Effect ledger is missing, unsupported, or exceeds the inspection limit')
        try:
            rows = [json.loads(line) for line in path.read_text().splitlines()]
        except (OSError, ValueError):
            return invalid('Effect ledger could not be read as complete JSON records')
        if not rows or rows[0] != {'type': 'ledger_ready', 'version': 1, 'job_id': job['id']}:
            return invalid('Effect ledger does not identify this execution')
        pending = {}
        started, ended = set(), set()
        has_mutations = False
        for row in rows[1:]:
            if not isinstance(row, dict) or not isinstance(row.get('id'), str):
                return invalid('Effect ledger contains an invalid call identity')
            if row.get('type') == 'start':
                if row.get('scope') not in {'workspace', 'external', 'observational'} or row['id'] in started:
                    return invalid('Effect ledger contains an invalid scope or duplicate start')
                started.add(row['id'])
                has_mutations |= row['scope'] != 'observational'
                pending[row['id']] = row
            elif row.get('type') == 'end':
                start = pending.get(row.get('id'))
                if not start or not isinstance(row.get('is_error'), bool) or row['id'] in ended:
                    return invalid('Effect ledger contains an unmatched or invalid completion')
                ended.add(row['id'])
                if not row['is_error'] or start.get('scope') in {'workspace', 'observational'}:
                    pending.pop(row['id'], None)
                else:
                    # A failed publisher may already have changed its remote.
                    # An exit code is not proof that nothing happened.
                    pending[row['id']] = {**start, 'is_error': True}
            else:
                return invalid('Effect ledger contains an unsupported record')
        # A failed or unfinished call that may reach beyond this machine needs
        # a human. A local one (a red test run, a build, a diff that found
        # differences, a command cut off mid-run) is listed for the successor,
        # which inspects the workspace before changing anything.
        issues, local = [], []
        for row in pending.values():
            if row['scope'] != 'external':
                continue
            entry = {'id': row['id'][:200], 'tool': str(row.get('tool', 'unknown'))[:200],
                     'scope': 'external', 'command': str(row.get('command', ''))[:4000],
                     'reason': 'External command failed; partial effects require inspection' if row.get('is_error') else 'External command has no completion receipt'}
            if remote_effect(row):
                issues.append(entry)
            else:
                local.append({**entry, 'reason': 'Local command failed; check its effects on this machine first'
                              if row.get('is_error') else 'Local command was cut off; check its effects on this machine first'})
        return {'safe': not issues, 'has_mutations': has_mutations, 'issues': issues, 'local': local,
                'started_tools': len(started), 'completed_tools': len(ended)}

    def _effects_safe(self, job):
        return self._effect_status(job)['safe']

    def _preserve(self, job):
        if job.get('workspace_mode') in {'read_only', 'independent'}:
            # read_only is an instruction, not a tool sandbox in current Pi.
            # No receipt or a capable tool in an unmanaged checkout requires
            # inspection; never assume this label proves the workspace unchanged.
            effects = self._effect_status(job)
            if not effects['safe']:
                raise BackupUnavailable('Workspace intent does not prove effect safety. Inspect the missing or uncertain tool receipts before continuation.')
            if effects['has_mutations']:
                raise BackupUnavailable('An effect-capable tool ran outside a managed isolated worktree. Inspect its workspace and external effects before recovery.')
        if not job.get('recovery_backup'):
            job['recovery_backup'] = capture_backup(self.runtime, job)
            job['automatic_recovery'] = True  # Any successor must verify this checkpoint.
            self.runtime._save_job(job)
        checkpoint = self.runtime._recovery_checkpoint(job)
        self.runtime._event(job['feature_id'], 'recovery.checkpoint', 'Work preserved for recovery inspection.',
            {**checkpoint, 'backup_path': job['recovery_backup'].get('path'), 'backup_sha256': job['recovery_backup'].get('sha256')}, 'automatic-checkpoint:' + job['id'])

    def recover(self, job, state):
        """Return true only once the stopped execution is settled or requeued."""
        assignment = self.store.get_assignment(job['claim']['id'])
        feature = self.store.get_feature(job['feature_id'])
        if assignment['generation'] != job['claim']['generation'] or assignment['status'] in TERMINAL | {'queued'}:
            return True
        if not self.enabled or not self._eligible(feature):
            return False
        if any(j['kind'] == 'worker' and j['claim']['id'] == assignment['id'] and _locked(self.runtime._job_dir(j) / 'writer.lock') for j in self.runtime._jobs()):
            return False
        self.runtime._require_storage(job['cwd'])
        effects = self._effect_status(job)
        if effects['local'] and job.get('recovery_local_effects') != effects['local'][:20]:
            # The recovery advisor and successor see these in the checkpoint.
            job['recovery_local_effects'] = effects['local'][:20]
            self.runtime._save_job(job)
            self._event(job, 'local_effects_noted', 'Failed or cut-off local commands are listed for the successor to check first.',
                        'local-effects:' + job['id'], {'effects': effects['local'][:20],
                            'effects_truncated': len(effects['local']) > 20})
        if not effects['safe']:
            self._event(job, 'effect_inspection_required', 'Inspect the retained uncertain calls before continuation; no external effect was replayed.',
                        'effect-inspection:' + job['id'], {'effects': effects['issues'][:20],
                            'effects_truncated': len(effects['issues']) > 20,
                            'next_permitted_actions': [{'action': 'inspect_effects', 'job_id': job['id'],
                                'ledger_path': str(self.runtime._job_dir(job) / 'effects.jsonl')} ]})
        try:
            self._preserve(job)
        except BackupUnavailable as error:
            self._block(feature, str(error), 'backup-blocked:' + job['id'], job=job)
            return False
        if not self._effects_safe(job):
            self._block(feature, 'An interrupted or failed side-effecting tool has no trustworthy completion receipt. Inspect it before continuation; the original dispatch was not replayed.', 'unsafe-effects:' + job['id'], job=job)
            return False
        if 'recovery_progress_key' not in job:
            job['recovery_progress_key'] = self.recovery_progress_key(assignment, job)
            self.runtime._save_job(job)
        progress_key = job['recovery_progress_key']
        previous_key = assignment.get('metadata', {}).get('recovery_progress_key')
        progress_restored = bool(progress_key and previous_key and progress_key != previous_key)
        if assignment.get('recovery_count', 0) < 2 or progress_restored:
            if not self.runtime._prepare_recovery_brief(job, state):
                return False
            if not job.get('recovery_safe_to_continue'):
                # Advisor uncertainty is not itself a human checkpoint. Once
                # writer, backup and effect receipts pass, a fenced successor
                # can inspect the predecessor or request a real human decision.
                job['recovery_inspection_required'] = True
                self.runtime._save_job(job)
            if job['recovery_backup']['status'] == 'saved':
                archive = self.runtime.root / 'recovery-backups' / (job['id'] + '.zip')
                if not archive.is_file() or archive.stat().st_size > 72 * 1024 * 1024 or hashlib.sha256(archive.read_bytes()).hexdigest() != job['recovery_backup']['sha256']:
                    self._block(feature, 'The recovery archive no longer matches its recorded checksum. No successor was started.', 'backup-changed:' + job['id'], job=job)
                    return False
        result = self.store.recover_assignment(assignment['id'], job['claim']['generation'],
            'Automatic checkpointed continuation after a verified stop. Preserve existing work and verify the recovery checkpoint before mutation.',
            'automatic-recovery:' + job['id'], verified_stopped=True, automatic=True, progress_key=progress_key)
        if result['status'] == 'queued':
            self._event(job, 'restarted', 'Queued a fresh executor from retained progress, not a replay of the original dispatch.', 'auto-restart:' + job['id'])
        return True

    def _block(self, feature, reason, identity, *, job=None):
        # A supplied job has already passed recover()'s writer-stop check. Other
        # blockers never assert that an unresponsive process has stopped.
        current = self.store.get_feature(feature['id'])
        if self._eligible(current):
            self.store.block_reliability(feature['id'], feature['revision'], reason, identity,
                stopped_assignment_id=job['claim']['id'] if job else None,
                stopped_generation=job['claim']['generation'] if job else None)

    def _coordinator_gap(self, feature, assignments, jobs, now):
        if self.store.pending_messages(feature['id']) or any(j['kind'] == 'coordinator' and j['feature_id'] == feature['id'] and not (self.runtime._job_dir(j) / 'finalized.json').exists() for j in jobs):
            return
        if assignments and any(a['status'] not in TERMINAL for a in assignments):
            return
        # A coordinator that already reported to the human after the last outcome settled is
        # waiting on them, not stranded; waking it only ends in a 'did not settle' block.
        settled_at = max((a['updated_at'] for a in assignments), default=None)
        if self.store.coordinator_replied_since(feature['id'], feature['current_visit_id'], settled_at):
            return
        previous = max((j for j in jobs if j['kind'] == 'coordinator' and j['feature_id'] == feature['id']), key=lambda j: j['created_at'], default=None)
        if previous and not self._effects_safe(previous):
            self._block(feature, 'The stranded coordinator has uncertain or missing effect receipts. Inspect its prior actions before another coordination turn.', 'coordinator-effects:' + previous['id'])
            return
        path = self.root / ('coordinator-' + feature['current_visit_id'] + '.json')
        record = _read_json(path, {'attempts': 0})
        if record['attempts'] >= 2:
            self._block(feature, 'Two coordinator kickstarts did not settle the current stage. Inspect the retained outcomes; no new stage was authorized.', 'coordinator-exhausted:' + feature['current_visit_id'])
            return
        # The stable attempt ID bridges DB commit -> controller receipt failure.
        identity = f"coordinator-kick:{feature['current_visit_id']}:{record['attempts']}"
        self.store.queue_system_message(feature['id'], 'Stability sweep found the current authorized stage marked running with no active assignment. Inspect authoritative state, collect settled outcomes, and complete this stage or explain its blocker. Do not begin another stage or invent human permission.', identity, attention='background')
        self.runtime._event(feature['id'], 'reliability.coordinator_kickstarted', 'Woke the stranded coordinator to settle the current stage.', {'visit_id': feature['current_visit_id']}, identity)
        _write_json(path, {'attempts': record['attempts'] + 1, 'at': iso(now)})

    def allow_handoff(self, job, *, verified_stopped=False):
        if not self.enabled:
            return True
        assignment = self.store.get_assignment(job['claim']['id'])
        fingerprint = self.recovery_progress_key(assignment, job) or 'unavailable'
        path = self.root / ('handoffs-' + assignment['id'] + '.json')
        now = time.time()
        reset_generation = assignment.get('metadata', {}).get('reliability_reset_generation')
        history = [r for r in _read_json(path, []) if r['at'] >= now - self.interval
                   and (reset_generation is None or r.get('generation', -1) > reset_generation)]
        if not any(r['job_id'] == job['id'] for r in history):
            history.append({'job_id': job['id'], 'generation': job['claim']['generation'], 'at': now, 'fingerprint': fingerprint})
            _write_json(path, history[-20:])
        if len(history) >= 5 and len({r['fingerprint'] for r in history[-5:]}) == 1:
            self._block(self.store.get_feature(job['feature_id']), 'Work stopped after repeated handoffs made no observable progress, including one focused repair attempt. Your checkpoint is saved. Tell First Mate what to change before trying again.', 'handoff-churn:' + job['id'], job=job if verified_stopped else None)
            return False
        if len(history) >= 4 and len({r['fingerprint'] for r in history[-4:]}) == 1:
            history[-1]['repair_guidance'] = ('Automatic loop repair within the current authorized assignment. Finish required acknowledgement using only the latest checkpoint and targeted missing evidence. '
                'Do not reread full predecessor history or restate plans. Perform the checkpoint\'s next finite action, retain its concrete result, and complete the assignment when its criteria are met. '
                'If that action fails, diagnose and fix it within scope. Request a human only for an actual decision or an uncertain external outcome. Another handoff without observable progress exhausts this repair attempt.')
            _write_json(path, history[-20:])
            self._event(job, 'handoff_repair', 'Repeated context handoffs triggered one focused repair continuation before escalation.', 'handoff-repair:' + job['id'])
        return True

    def continuation_guidance(self, assignment_id):
        history = _read_json(self.root / ('handoffs-' + assignment_id + '.json'), [])
        if not history or history[-1].get('at', 0) < time.time() - self.interval:
            return ''
        assignment = self.store.get_assignment(assignment_id)
        reset_generation = assignment.get('metadata', {}).get('reliability_reset_generation')
        if reset_generation is not None and history[-1].get('generation', -1) <= reset_generation:
            return ''
        return history[-1].get('repair_guidance', '')
