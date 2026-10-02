from __future__ import annotations

import fcntl
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock

from herdr_harness.events import EventBroker
from herdr_harness.watchers.errors import WatchersError
from herdr_harness.watchers.runtime import WatchersRuntime
from herdr_harness.watchers.store import WatchersStore, iso


class WatcherRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.now = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
        self.store = WatchersStore(self.base / 'store.sqlite3', self.base / 'watchers', {'id': 'test', 'name': 'Test machine'}, clock=lambda: self.now)
        self.broker = EventBroker()
        self.child = Mock(pid=987654)
        self.child.poll.return_value = None
        self.popen = Mock(return_value=self.child)
        self.runtime = WatchersRuntime(self.store, {'PATH': '/usr/bin:/bin'}, self.broker, clock=lambda: self.now, popen=self.popen)

    def watcher(self, **changes):
        definition = {'name': 'Synthetic timer', 'timezone': 'UTC', 'summary': '{time}, I run {script:check.sh}.',
                      'schedule': {'kind': 'interval', 'every_minutes': 5},
                      'steps': [{'id': 'check', 'kind': 'script', 'title': 'Check', 'file': 'check.sh', 'interpreter': '/bin/bash'}]}
        definition.update(changes)
        watcher = self.store.create(definition, scripts={'check': 'true'})
        return self.store.transition(watcher['id'], 'active', confirmed_by='user')

    def test_due_fire_without_client_uses_frozen_detached_worker(self):
        watcher = self.watcher()
        self.runtime.tick()
        self.now += timedelta(minutes=4, seconds=50)
        self.runtime.tick()
        self.now += timedelta(seconds=10)
        self.runtime.tick()
        runs = self.store.runs(watcher['id'])
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]['trigger'], 'scheduled')
        args, kwargs = self.popen.call_args
        self.assertEqual(args[0][1:5], ['-P', '-m', 'herdr_harness.watchers.runner', '--run'])
        self.assertTrue(kwargs['start_new_session'])
        self.assertEqual(self.store.get(watcher['id'])['next_fire_at'], '2026-01-01T12:10:00Z')
        events = [e['event'] for e in self.broker.after(0)]
        self.assertIn('watchers.updated', events)
        self.assertIn('watchers.run', events)

    def test_short_restart_gap_keeps_five_minute_poll(self):
        watcher = self.watcher()
        self.now += timedelta(minutes=4)
        self.runtime.tick()
        self.now += timedelta(minutes=2)
        restarted = WatchersRuntime(self.store, {}, clock=lambda: self.now, popen=self.popen)
        restarted.tick()
        self.assertEqual(self.store.runs(watcher['id'])[0]['trigger'], 'scheduled')

    def test_long_gap_skip_and_daily_single_catch_up(self):
        poll = self.watcher()
        daily = self.watcher(name='Daily', schedule={'kind': 'daily', 'at': '13:00'})
        self.runtime.tick()
        self.now += timedelta(days=3)
        self.runtime.tick()
        self.assertEqual(self.store.runs(poll['id']), [])
        self.assertEqual(len(self.store.runs(daily['id'])), 1)
        self.assertEqual(self.store.runs(daily['id'])[0]['trigger'], 'catch_up')

    def test_overlap_skip_and_capacity_advance_due_time(self):
        first = self.watcher()
        self.runtime.capacity = 1
        run = self.runtime.run_now(first['id'])
        self.now += timedelta(minutes=4, seconds=50)
        # Keep the worker alive across this tick to isolate overlap from crash recovery.
        self.store.update_run(run['id'], heartbeat_at=iso(self.now))
        self.runtime.tick()
        second = self.watcher(name='Second')
        self.store.set_next_fire(second['id'], self.now + timedelta(seconds=10))
        self.now += timedelta(seconds=10)
        self.runtime.tick()
        self.assertEqual(len(self.store.runs(first['id'])), 1)
        self.assertEqual(self.store.runs(second['id']), [])
        self.assertEqual(self.store.get(second['id'])['next_fire_at'], '2026-01-01T12:10:00Z')

    def test_spawn_failure_is_failed_and_needs_you(self):
        watcher = self.watcher()
        self.popen.side_effect = OSError('Synthetic failure')
        run = self.runtime.run_now(watcher['id'])
        self.assertEqual(run['status'], 'failed')
        self.assertIsNotNone(run['finished_at'])
        self.assertEqual(len(self.store.inbox()), 1)

    def test_stale_unlocked_worker_becomes_unknown_and_never_resends(self):
        watcher = self.watcher()
        run = self.store.create_run(watcher['id'], 'manual')
        self.store.update_run(run['id'], status='running')
        self.now += timedelta(seconds=16)
        self.runtime.tick()
        self.assertEqual(self.store.get_run(run['id'])['status'], 'unknown')
        self.assertEqual(len(self.store.inbox()), 1)
        self.runtime.tick()
        self.assertEqual(len(self.store.inbox()), 1)
        self.popen.assert_not_called()

    def test_restart_reattaches_live_lock_even_with_stale_heartbeat(self):
        watcher = self.watcher()
        run = self.store.create_run(watcher['id'], 'manual')
        self.store.update_run(run['id'], status='running')
        path = self.store.root / watcher['id'] / 'runs' / run['id'] / 'runner.lock'
        with path.open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.now += timedelta(seconds=60)
            restarted = WatchersRuntime(self.store, {}, clock=lambda: self.now, popen=self.popen)
            restarted.tick()
            self.assertEqual(self.store.get_run(run['id'])['status'], 'running')
            self.popen.assert_not_called()
        self.store.complete_run(run['id'], 'finished', 'Finished.')
        restarted.tick()
        self.assertEqual(self.store.get_run(run['id'])['status'], 'finished')

    def test_manual_request_replay_never_starts_second_worker(self):
        watcher = self.watcher()
        first = self.runtime.run_now(watcher['id'], request_id='manual-1')
        replay = self.runtime.run_now(watcher['id'], request_id='manual-1')
        self.assertEqual(first['id'], replay['id'])
        self.assertEqual(self.popen.call_count, 1)

    def test_manager_lock_allows_only_one_scheduler(self):
        first = WatchersRuntime(self.store, {})
        second = WatchersRuntime(self.store, {})
        first.start()
        self.addCleanup(first.stop)
        with self.assertRaises(WatchersError) as caught:
            second.start()
        self.assertEqual(caught.exception.code, 'scheduler_already_running')
        first.stop()
        second.start()
        second.stop()

    def test_inbox_and_finished_run_are_published_by_scheduler(self):
        watcher = self.watcher()
        run = self.runtime.run_now(watcher['id'])
        self.store.deliver_inbox(run['id'], 'post', {'kind': 'inbox'}, 'Result', 'Synthetic result')
        self.store.complete_run(run['id'], 'finished', 'Finished.')
        self.runtime.tick()
        events = self.broker.after(0)
        self.assertTrue(any(e['event'] == 'watchers.run' and e['data']['run']['status'] == 'finished' for e in events))
        self.assertTrue(any(e['event'] == 'watchers.inbox' for e in events))
