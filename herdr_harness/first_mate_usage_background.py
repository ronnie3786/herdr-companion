"""Nonblocking, bounded display projections for optional First Mate accounting.

The worker owns the synchronous accountant. Requests only submit immutable
inventory snapshots and read projections; they never wait on its filesystem I/O.
No cached projection authorizes transcript access or workflow decisions.
"""
from __future__ import annotations

from collections import OrderedDict
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import threading
import time

from .first_mate_usage import FirstMateUsage


class BackgroundFirstMateUsage:
    def __init__(self, sessions_root: Path, *, enabled=True, capacity=64,
                 refresh_seconds=5.0, stale_seconds=30.0, clock=time.monotonic):
        self.enabled = enabled
        self.capacity = capacity
        self.refresh_seconds = refresh_seconds
        self.stale_seconds = stale_seconds
        self.clock = clock
        self._stop = threading.Event()
        self._engine = FirstMateUsage(sessions_root, enabled=enabled, stop_event=self._stop)
        self._metadata = FirstMateUsage(sessions_root, enabled=False)
        self._lock = threading.Lock()
        self._pending = OrderedDict()
        self._entries = OrderedDict()
        self._active = None
        self._thread = None
        self._restart_requested = False
        self._cursor = ""
        self._failures = 0
        self._completed = 0
        self._last_success = None

    @staticmethod
    def _inputs(arguments):
        # Avoid copying prompts, transcripts, role catalogs or execution evidence.
        # Every field consumed by account() is retained, including global owners.
        jobs = []
        for job in arguments['jobs']:
            row = {key: job[key] for key in (
                'id', 'feature_id', 'kind', 'native_session_id', 'session_file',
                'parent_job_id', 'created_at', 'model_selection', 'actual_model',
                'actual_thinking', 'model', 'thinking') if key in job}
            row['claim'] = {key: job['claim'][key] for key in (
                'id', 'title', 'generation', 'attempt', 'input_revision') if key in job.get('claim', {})}
            jobs.append(row)
        value = {**arguments, 'jobs': jobs, 'assignments': [
            {'id': row['id'], 'metadata': {
                'parent_assignment_id': row.get('metadata', {}).get('parent_assignment_id')}}
            for row in arguments['assignments']]}
        serial = {**value, 'jobs_root': str(value['jobs_root'])}
        fingerprint = hashlib.sha256(json.dumps(serial, sort_keys=True, separators=(',', ':')).encode()).digest()
        return fingerprint, value

    def _render(self, value, *, state, stale=False):
        result = deepcopy(value)
        def decorate(summary):
            if stale:
                summary.update(FirstMateUsage._stale(summary))
            summary['refresh_state'] = state
            if state == 'cached':
                summary['validation_age_bound_seconds'] = self.stale_seconds
        decorate(result['usage'])
        for group in ('assignment_usage', 'subtree_usage'):
            for summary in result[group].values():
                decorate(summary)
        for row in result['sessions']:
            decorate(row['usage'])
        return result

    def account(self, **arguments):
        if not self.enabled:
            return self._metadata.account(**arguments, discover_unbound=True)
        if not any(row.get('feature_id') == arguments['feature_id'] for row in
                   (*arguments['jobs'], *arguments['ledger_sessions'])):
            return self._metadata.account(**arguments, discover_unbound=True)
        fingerprint, inputs = self._inputs(arguments)
        identity = arguments['feature_id']
        now = self.clock()
        with self._lock:
            entry = self._entries.get(identity)
            matches = entry is not None and entry['fingerprint'] == fingerprint
            if entry:
                self._entries.move_to_end(identity)
            due = not matches or now - entry['attempted'] >= self.refresh_seconds
            if due and not self._stop.is_set() and self._active != (identity, fingerprint):
                # Circular admission prevents a fixed-order list larger than
                # capacity from refreshing its first cards forever. Retain the
                # nearest pending keys after the last dispatch, then wrap.
                if identity not in self._pending and len(self._pending) >= self.capacity:
                    farthest = max(self._pending, key=self._rank)
                    if self._rank(identity) < self._rank(farthest):
                        del self._pending[farthest]
                if identity in self._pending or len(self._pending) < self.capacity:
                    self._pending[identity] = (fingerprint, deepcopy(inputs))
                    if self._thread is None:
                        self._start_locked()
            cached = entry['value'] if matches else None
            failed = bool(matches and entry['failed'])
            overdue = bool(matches and now - entry['validated'] >= self.stale_seconds)
            stopped = self._stop.is_set()
        if cached is not None:
            # Ordinary refreshes preserve conditional versions when no evidence
            # changes. Overdue/failed validation explicitly downgrades coverage.
            return self._render(cached, state='stopped' if stopped else 'failed' if failed else 'stale' if overdue else 'cached',
                                stale=stopped or failed or overdue)
        return self._render(self._metadata.account(**inputs, discover_unbound=True),
                            state='stopped' if self._stop.is_set() else 'failed' if failed else 'pending')

    def _rank(self, identity):
        return identity <= self._cursor, identity

    def _start_locked(self):
        self._thread = threading.Thread(target=self._run, name='first-mate-usage', daemon=True)
        self._thread.start()

    def _finish_locked(self):
        self._active = None
        self._thread = None
        if self._restart_requested:
            self._restart_requested = False
            self._stop.clear()

    def _run(self):
        with self._lock:
            owner = self._thread
        try:
            self._work_loop()
        finally:
            with self._lock:
                # Normal exits release ownership under the queue lock. Do not
                # clear a replacement created after that release.
                if self._thread is owner:
                    self._finish_locked()
                    if self._pending and not self._stop.is_set():
                        self._start_locked()

    def _work_loop(self):
        while True:
            with self._lock:
                if self._stop.is_set() or not self._pending:
                    self._finish_locked()
                    return
                identity = min(self._pending, key=self._rank)
                fingerprint, inputs = self._pending.pop(identity)
                self._cursor = identity
                self._active = (identity, fingerprint)
            started = self.clock()
            value, failed = None, False
            try:
                value = self._engine.account(**inputs)
            except InterruptedError:
                failed = True
            except Exception:
                # Diagnostics expose counts/state only, never paths or content.
                failed = True
            now = self.clock()
            with self._lock:
                old = self._entries.get(identity)
                if not self._stop.is_set():
                    if failed:
                        self._failures += 1
                        if old and old['fingerprint'] == fingerprint:
                            value = old['value']
                    else:
                        self._completed += 1
                        self._last_success = now
                    self._entries[identity] = {
                        'fingerprint': fingerprint, 'value': value,
                        'attempted': now, 'validated': old['validated'] if failed and old else started,
                        'failed': failed,
                    }
                    self._entries.move_to_end(identity)
                    while len(self._entries) > self.capacity:
                        self._entries.popitem(last=False)
                self._active = None
            # Yield between features so an initial historical rebuild does not
            # become a tight loop on an already busy companion.
            if self._stop.wait(0.01):
                with self._lock:
                    self._finish_locked()
                return

    def session_usage(self, session_file, expected_session_id=None):
        # A saved-session page may be opened without an earlier feature read.
        # Submit it through the same bounded owner using a private projection key.
        identity = 'session:' + str(session_file) + ':' + str(expected_session_id)
        result = self.account(feature_id=identity, assignments=[], jobs=[],
            ledger_sessions=[{'feature_id': identity, 'native_session_id': expected_session_id,
                              'session_file': str(session_file), 'updated_at': ''}],
            jobs_root=self._engine.sessions_root.parent / 'jobs', updated_at='')
        row = next(iter(result['sessions']), None)
        summary = dict(row['usage'] if row else result['usage'])
        selection = (row or {}).get('model_selection') or {}
        summary.update(_actual_model=selection.get('actual_model'),
                       _actual_thinking=selection.get('actual_thinking'),
                       _identity_valid=bool(summary.get('refresh_state') == 'cached' and
                           (selection.get('actual_model') or selection.get('actual_thinking'))))
        return summary

    def open_session(self, path):
        return self._metadata._open_source(path)

    def discover_session_id(self, session_file, expected=None):
        return self._metadata.discover_session_id(session_file, expected)

    public_summary = staticmethod(FirstMateUsage.public_summary)

    def health(self):
        with self._lock:
            return {'enabled': self.enabled, 'mode': 'background', 'capacity': self.capacity,
                    'refresh_interval_seconds': self.refresh_seconds,
                    'validation_age_bound_seconds': self.stale_seconds, 'stopped': self._stop.is_set(), 'pending': len(self._pending),
                    'active': self._active is not None, 'cached': len(self._entries),
                    'completed': self._completed, 'failures': self._failures,
                    'last_success_age_seconds': None if self._last_success is None else
                        round(max(0, self.clock() - self._last_success), 1)}

    def start(self):
        with self._lock:
            # Never clear cancellation beneath a still-running old worker.
            if self._thread is not None:
                if self._stop.is_set():
                    self._restart_requested = True
                return not self._stop.is_set()
            self._restart_requested = False
            self._stop.clear()
            return True

    def stop(self):
        with self._lock:
            self._stop.set()
            self._restart_requested = False
            self._pending.clear()
            thread = self._thread
        if thread and thread is not threading.current_thread():
            thread.join(timeout=1)
