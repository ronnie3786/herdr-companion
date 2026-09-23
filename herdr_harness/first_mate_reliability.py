"""Persistent, bounded recovery within an already human-authorized First Mate stage.

Called only by the fenced scheduler. The independent guardian supervises that
scheduler; neither a wall-clock timer nor an advisor can authorize a new stage.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import time

from .first_mate_backup import BackupUnavailable, capture_backup, git_bytes
from .first_mate_runtime import _bounded, _locked, _read_json, _recent_records, _write_json, _ledger_event, TERMINAL
from .first_mate_store import FirstMateError


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
        self.grace = _bounded(runtime.environ, 'HERDR_FIRST_MATE_NUDGE_GRACE_SECONDS', 300, 60, 3600)
        saved = _read_json(self.root / 'sweep.json', {})
        self.next_sweep = min(epoch(saved.get('next_epoch'), 0), time.time() + self.interval)
        self.last_sweep_at = saved.get('last_sweep_at')
        self._last_tick = 0.0

    def health(self) -> dict:
        return {'automatic_recovery': self.enabled, 'sweep_interval_seconds': self.interval,
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

    def owns(self, job: dict) -> bool:
        record = _read_json(self._path(job['claim']['id']), {})
        return record.get('job_id') == job['id'] and (record.get('phase') in {'assessing', 'nudge_pending', 'nudged', 'stopping'} or record.get('lease_until', 0) > time.time())

    def tick(self, jobs: list[dict], *, now: float | None = None):
        if not self.enabled or not self.runtime.capabilities()['available']:
            return
        if now is None:
            if time.monotonic() - self._last_tick < 10:
                return
            self._last_tick = time.monotonic()
            now = time.time()
        due = now >= self.next_sweep
        for feature in self.store.list_features('all'):
            if not self._eligible(feature):
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
            if due:
                self._coordinator_gap(feature, assignments, jobs, now)
        if due:
            self.last_sweep_at = iso(now)
            self.next_sweep = now + self.interval
            _write_json(self.root / 'sweep.json', {'last_sweep_at': self.last_sweep_at, 'next_epoch': self.next_sweep})

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
        wait_until = min(epoch(progress.get('wait_until_epoch'), 0), epoch(progress.get('recorded_epoch'), 0) + 3600)
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
            record.update(phase='observing', lease_until=wait_until)
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
                    'If this executor cannot continue, save fm_handoff at a safe boundary and end. Preserve all work and human gates. ' + instruction)
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
            record.update(phase='observing', lease_until=time.time() + self.interval)
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

    def _effects_safe(self, job):
        path = self.runtime._job_dir(job) / 'effects.jsonl'
        if job.get('safety_ledger_version') != 1 or not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
            return False
        try:
            rows = [json.loads(line) for line in path.read_text().splitlines()]
        except (OSError, ValueError):
            return False
        if not rows or rows[0] != {'type': 'ledger_ready', 'version': 1, 'job_id': job['id']}:
            return False
        pending = {}
        for row in rows[1:]:
            if not isinstance(row, dict) or not isinstance(row.get('id'), str):
                return False
            if row.get('type') == 'start':
                if row.get('scope') not in {'workspace', 'external'}:
                    return False
                pending[row['id']] = row
            elif row.get('type') == 'end':
                start = pending.get(row.get('id'))
                if not start or not isinstance(row.get('is_error'), bool):
                    return False
                if not row['is_error'] or start.get('scope') == 'workspace':
                    pending.pop(row['id'], None)
            else:
                return False
        return all(row.get('scope') == 'workspace' for row in pending.values())

    def _preserve(self, job):
        if job.get('workspace_mode') == 'read_only':
            # read_only is an instruction, not a tool sandbox in current Pi.
            # No receipt or a capable tool in an unmanaged checkout requires
            # inspection; never assume this label proves the workspace unchanged.
            if not self._effects_safe(job):
                raise BackupUnavailable('Read-only intent does not prove effect safety. Inspect the missing or uncertain tool receipts before continuation.')
            rows = (self.runtime._job_dir(job) / 'effects.jsonl').read_text().splitlines()
            if len(rows) != 1:
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
        try:
            self._preserve(job)
        except BackupUnavailable as error:
            self._block(feature, str(error), 'backup-blocked:' + job['id'], job=job)
            return False
        if not self._effects_safe(job):
            self._block(feature, 'An interrupted or failed side-effecting tool has no trustworthy completion receipt. Inspect it before continuation; the original dispatch was not replayed.', 'unsafe-effects:' + job['id'], job=job)
            return False
        if assignment.get('recovery_count', 0) < 2:
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
            'automatic-recovery:' + job['id'], verified_stopped=True, automatic=True)
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
        self.store.queue_system_message(feature['id'], 'Stability sweep found the current authorized stage marked running with no active assignment. Inspect authoritative state, collect settled outcomes, and complete this stage or explain its blocker. Do not begin another stage or invent human permission.', identity)
        self.runtime._event(feature['id'], 'reliability.coordinator_kickstarted', 'Woke the stranded coordinator to settle the current stage.', {'visit_id': feature['current_visit_id']}, identity)
        _write_json(path, {'attempts': record['attempts'] + 1, 'at': iso(now)})

    def allow_handoff(self, job):
        if not self.enabled:
            return True
        assignment = self.store.get_assignment(job['claim']['id'])
        fingerprint = self._position(assignment, job)
        path = self.root / ('handoffs-' + assignment['id'] + '.json')
        now = time.time()
        history = [r for r in _read_json(path, []) if r['at'] >= now - self.interval]
        if not any(r['job_id'] == job['id'] for r in history):
            history.append({'job_id': job['id'], 'at': now, 'fingerprint': fingerprint})
            _write_json(path, history[-20:])
        if len(history) >= 4 and len({r['fingerprint'] for r in history[-4:]}) == 1:
            self._block(self.store.get_feature(job['feature_id']), 'Four handoffs repeated the same progress within one sweep interval. The latest checkpoint is retained; revise the approach instead of rotating again.', 'handoff-churn:' + job['id'])
            return False
        return True
