"""One per-machine scheduler, with detached workers and restart reattachment."""
from __future__ import annotations

import fcntl
import logging
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .errors import WatchersError
from .process_identity import process_identity, same_process, signal_process
from .schedule import missed_run_trigger, next_fire
from .store import RUNNING, encoded, instant, iso, private_write

_LOG = logging.getLogger(__name__)
HEARTBEAT_SECONDS = 5


def validate_executable(definition):
    for step in definition['steps']:
        if step['kind'] not in ('script', 'gate', 'deliver') or (step['kind'] == 'deliver' and any(d['kind'] != 'inbox' for d in step['to'])):
            raise WatchersError('step_kind_unsupported', 'This companion can run scripts, checks, and Watcher inbox delivery. Save other steps as a draft.', status=409)


def lock_held(path):
    """A missing lock is free; do not mistake process IDs for ownership."""
    try:
        fd = os.open(path, os.O_RDWR)
    except FileNotFoundError:
        return False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False
    finally:
        os.close(fd)


class WatchersRuntime:
    def __init__(self, store, environ, broker=None, *, clock=None, popen=None):
        self.store, self.environ, self.broker = store, dict(environ), broker
        self.clock = clock or store.clock
        self.popen = popen or subprocess.Popen
        try:
            self.capacity = int(self.environ.get('HERDR_WATCHERS_MAX_RUNS', '4'))
        except ValueError as exc:
            raise WatchersError('invalid_configuration', 'HERDR_WATCHERS_MAX_RUNS must be an integer') from exc
        if not 1 <= self.capacity <= 64:
            raise WatchersError('invalid_configuration', 'HERDR_WATCHERS_MAX_RUNS must be between 1 and 64')
        self._wake, self._stop = threading.Event(), threading.Event()
        self._thread = None
        self._lock_fd = None
        self._tick_lock = threading.RLock()
        self._last_tick = self.store.get_metadata('last_tick_at')
        self._last_prune = None
        self._watcher_versions, self._run_versions, self._inbox_versions = {}, {}, {}
        self._tracking = set()
        self._children = {}
        self.last_error = None

    def now(self):
        return instant(self.clock())

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        fd = os.open(self.store.root / 'manager.lock', os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            raise WatchersError('scheduler_already_running', 'Another Watcher scheduler owns this state directory', status=409)
        self._lock_fd = fd
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name='watchers-scheduler', daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        self._wake.set()
        if self._thread and self._thread is not threading.current_thread():
            self._thread.join(timeout=15)
        # Keep ownership if a tick is still blocked; never start a second manager.
        if not self._thread or not self._thread.is_alive():
            if self._lock_fd is not None:
                os.close(self._lock_fd)
                self._lock_fd = None
        # Detached workers and their groups are intentionally left running.

    def wake(self):
        self._wake.set()

    def status(self):
        active = self.store.list(state='active')
        fires = [w['next_fire_at'] for w in active if w.get('next_fire_at')]
        return {'running': bool(self._thread and self._thread.is_alive() and not self._stop.is_set()),
                'last_tick_at': self._last_tick, 'next_fire_at': min(fires) if fires else None,
                **({'error': self.last_error} if self.last_error else {})}

    def _loop(self):
        try:
            while not self._stop.is_set():
                self._wake.clear()
                delay = 30
                try:
                    self.tick()
                    fires = [instant(w['next_fire_at']) for w in self.store.list(state='active') if w.get('next_fire_at')]
                    delay = min(30, max(0.1, (min(fires) - self.now()).total_seconds())) if fires else 30
                    if self.store.runs(status='queued,running', limit=1):
                        delay = min(delay, 1)
                    self.last_error = None
                except Exception:
                    self.last_error = 'The scheduler could not complete its last tick.'
                    _LOG.exception('Watcher scheduler tick failed')
                if not self._stop.is_set():
                    self._wake.wait(delay)
        finally:
            if self._lock_fd is not None:
                os.close(self._lock_fd)
                self._lock_fd = None

    def _spawn(self, run):
        run_dir = self.store.root / run['watcher_id'] / 'runs' / run['id']
        self._tracking.add(run['id'])
        private_write(run_dir / 'runner.log', '')
        try:
            environment = dict(self.environ)
            module_root = str(Path(__file__).resolve().parents[2])
            environment['PYTHONPATH'] = module_root + (os.pathsep + environment['PYTHONPATH'] if environment.get('PYTHONPATH') else '')
            with (run_dir / 'runner.log').open('ab') as output:
                process = self.popen([sys.executable, '-P', '-m', 'herdr_harness.watchers.runner', '--run', str(run_dir.resolve())],
                                     env=environment, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                     start_new_session=True, close_fds=True)
            self._children[run['id']] = process
            self.store.update_run(run['id'], pid=process.pid, pid_identity=process_identity(process.pid))
        except Exception as exc:
            self.store.complete_run(run['id'], 'failed', f'Needs you. The worker could not start ({type(exc).__name__}).')
        return self.store.get_run(run['id'])

    def run_now(self, watcher_id, *, dry_run=False, request_id=None):
        with self._tick_lock:
            run = self.store.create_run(watcher_id, 'dry_run' if dry_run else 'manual', request_id=request_id, capacity=self.capacity)
            # A request receipt replays the original run, never launches it again.
            current = self.store.get_run(run['id'])
            if current['status'] == 'queued' and not current['pid']:
                current = self._spawn(current)
            self.wake()
            return current

    def stop_run(self, run_id, *, request_id=None):
        with self._tick_lock:
            self.store.request_stop(run_id, request_id=request_id)
            run = self.store.get_run(run_id)
            if run['status'] not in RUNNING:
                return run
            run_dir = self.store.root / run['watcher_id'] / 'runs' / run_id
            if not lock_held(run_dir / 'runner.lock'):
                # This also cancels a queued process before it acquires its lock.
                self.store.complete_run(run_id, 'stopped', 'Stopped. Remaining steps were not run.')
                self.wake()
                return self.store.get_run(run_id)
            if run['pid'] and run.get('pid_identity'):
                signal_process(run['pid'], run['pid_identity'], signal.SIGTERM)
            # Wait for actual process ownership release before force delete can remove files.
            deadline = time.monotonic() + 10
            while lock_held(run_dir / 'runner.lock') and time.monotonic() < deadline:
                time.sleep(0.05)
            if lock_held(run_dir / 'runner.lock'):
                latest = self.store.get_run(run_id)
                for field, identity_field in (('process_pid', 'process_identity'), ('pid', 'pid_identity')):
                    if latest[field] and latest.get(identity_field):
                        signal_process(latest[field], latest[identity_field], signal.SIGKILL, group=True)
                deadline = time.monotonic() + 2
                while lock_held(run_dir / 'runner.lock') and time.monotonic() < deadline:
                    time.sleep(0.05)
            if lock_held(run_dir / 'runner.lock'):
                raise WatchersError('run_stopping', 'The worker is still stopping. Try again shortly.', status=409)
            self.store.complete_run(run_id, 'stopped', 'Stopped. Remaining steps were not run.')
            self.wake()
            return self.store.get_run(run_id)

    def delete(self, watcher_id, *, force=False, request_id=None):
        with self._tick_lock:
            replay = self.store.prepare_delete(watcher_id, force=force, request_id=request_id)
            if replay is not None:
                return replay
            if force:
                for run in self.store.runs(watcher_id, status='queued,running'):
                    self.stop_run(run['id'])
            result = self.store.delete(watcher_id, force=force, request_id=request_id)
            self.wake()
            return result

    def _reattach(self, now):
        # Reap owned children before identity checks, so a dead worker cannot be
        # mistaken for a live process just because it is still a zombie.
        for run_id, child in list(self._children.items()):
            if child.poll() is not None:
                del self._children[run_id]
        for run in self.store.runs(status='queued,running', limit=1000):
            self._tracking.add(run['id'])
            if (now - instant(run['heartbeat_at'] or run['started_at'])).total_seconds() <= 3 * HEARTBEAT_SECONDS:
                continue
            run_dir = self.store.root / run['watcher_id'] / 'runs' / run['id']
            if lock_held(run_dir / 'runner.lock'):
                # Scripts inherit the execution lock. If their runner died they
                # still occupy overlap/capacity until a verified group is stopped.
                owner = process_identity(run['pid']) if run['pid'] else None
                dead = False
                if owner is not None and run.get('pid_identity'):
                    dead = not same_process(run['pid'], run['pid_identity'])
                elif run['pid']:
                    try:
                        os.kill(run['pid'], 0)
                    except ProcessLookupError:
                        dead = True
                    except PermissionError:
                        pass
                if dead and run['process_pid'] and run.get('process_identity'):
                    signal_process(run['process_pid'], run['process_identity'], signal.SIGKILL, group=True)
                continue
            # A terminal write precedes unlock. complete_run guards that race.
            self.store.complete_run(run['id'], 'unknown', 'Needs you. The worker stopped without recording an outcome; nothing was resent.')

    def tick(self):
        with self._tick_lock:
            now = self.now()
            self._reattach(now)
            for watcher in self.store.list(state='active'):
                if not watcher.get('next_fire_at') or instant(watcher['next_fire_at']) > now:
                    continue
                fire_at = instant(watcher['next_fire_at'])
                last_tick = instant(self._last_tick) if self._last_tick else fire_at
                trigger = missed_run_trigger(watcher['schedule'], watcher['timezone'], fire_at=fire_at,
                                             last_tick_at=last_tick, now=now, missed_runs=watcher['missed_runs'])
                run = self.store.claim_due(watcher['id'], fire_at, trigger,
                                           next_fire(watcher['schedule'], watcher['timezone'], now), capacity=self.capacity)
                if run is not None:
                    self._spawn(run)
            self._last_tick = iso(now)
            self.store.set_metadata('last_tick_at', self._last_tick)
            if self._last_prune is None or (now - self._last_prune).total_seconds() >= 3600:
                self.store.prune(now)
                self._last_prune = now
            self._publish_changes()
        return self.status()

    def _publish_changes(self):
        if self.broker is None:
            return
        watchers = {w['id']: w for w in self.store.list()}
        for watcher_id, watcher in watchers.items():
            signature = encoded(watcher)
            if self._watcher_versions.get(watcher_id) != signature:
                self.broker.publish('watchers.updated', {'machine': self.store.machine, 'watcher': watcher})
                self._watcher_versions[watcher_id] = signature
        for removed in set(self._watcher_versions) - set(watchers):
            self.broker.publish('watchers.updated', {'machine': self.store.machine, 'id': removed, 'deleted': True})
            del self._watcher_versions[removed]
        self._tracking.update(run['id'] for run in self.store.runs(status='queued,running', limit=1000))
        for run_id in list(self._tracking):
            try:
                run = self.store.get_run(run_id)
            except WatchersError:
                self._tracking.discard(run_id)
                continue
            signature = encoded({k: v for k, v in run.items() if k != 'heartbeat_at'})
            if self._run_versions.get(run_id) != signature:
                self.broker.publish('watchers.run', {'machine': self.store.machine, 'run': run})
                self._run_versions[run_id] = signature
            if run['status'] not in RUNNING:
                self._tracking.discard(run_id)
                self._run_versions.pop(run_id, None)
        inbox = {item['id']: item for item in self.store.inbox(limit=1000)}
        for item_id, item in inbox.items():
            signature = encoded(item)
            if self._inbox_versions.get(item_id) != signature:
                self.broker.publish('watchers.inbox', {'machine': self.store.machine, 'item': item})
        self._inbox_versions = {key: encoded(value) for key, value in inbox.items()}
