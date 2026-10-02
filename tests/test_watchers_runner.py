from __future__ import annotations

import json
import os
import signal
import tempfile
import time
import unittest
from pathlib import Path
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from herdr_harness.watchers import runner
from herdr_harness.watchers.runtime import WatchersRuntime, lock_held
from herdr_harness.watchers.steps.script import OUTPUT_LIMIT, environment
from herdr_harness.watchers.store import WatchersStore


def fixture(*, gate=True, deliver=True, once=False):
    steps = [{'id': 'find', 'kind': 'script', 'title': 'Find synthetic items', 'file': 'find.sh', 'interpreter': '/bin/bash'}]
    if gate:
        steps.append({'id': 'new', 'kind': 'gate', 'title': 'Check for new items', 'rule': {'kind': 'new_items', 'from': 'find', 'key': 'id', 'version': 'version'}})
    if deliver:
        steps.append({'id': 'post', 'kind': 'deliver', 'title': 'Post to Watcher inbox', 'to': [{'kind': 'inbox'}]})
    return {'name': 'Synthetic collector', 'timezone': 'UTC',
            'schedule': {'kind': 'once', 'at': '2027-01-01T00:00:00Z'} if once else {'kind': 'interval', 'every_minutes': 5},
            'summary': '{time}, I run {script:find.sh}.', 'steps': steps}


class WatcherRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.store = WatchersStore(self.base / 'watchers.sqlite3', self.base / 'watchers', {'id': 'test', 'name': 'Test machine'})

    def create(self, script="printf '[{\"id\":\"item-1\",\"version\":1}]'", **options):
        return self.store.create(fixture(**options), scripts={'find': script})

    def execute(self, watcher, trigger='manual', environ=None):
        run = self.store.create_run(watcher['id'], trigger)
        run_dir = self.store.root / watcher['id'] / 'runs' / run['id']
        runner.run(run_dir, environ=environ or {'PATH': '/usr/bin:/bin'})
        self.assertFalse(lock_held(run_dir / 'runner.lock'))
        return self.store.get_run(run['id'])

    def test_gate_delivery_and_repeat_nothing_new(self):
        watcher = self.create()
        first = self.execute(watcher)
        self.assertEqual(first['status'], 'finished')
        self.assertIsNotNone(first['finished_at'])
        self.assertEqual(len(self.store.inbox()), 1)
        self.assertIn('item-1', self.store.inbox()[0]['body_md'])
        self.assertEqual(len(self.store.gate_cursor(watcher['id'], 'new')['keys']), 1)
        again = self.execute(watcher)
        self.assertEqual(again['status'], 'nothing_new')
        self.assertEqual(again['summary'], 'Nothing new. Stopped at the check.')
        self.assertEqual(len(self.store.inbox()), 1)

    def test_dry_run_creates_would_post_without_cursor_or_inbox(self):
        watcher = self.create()
        run = self.execute(watcher, 'dry_run')
        self.assertEqual(run['status'], 'finished')
        self.assertEqual(run['deliveries'][0]['status'], 'would_post')
        self.assertEqual(self.store.inbox(), [])
        self.assertIsNone(self.store.gate_cursor(watcher['id'], 'new'))
        self.assertEqual(self.execute(watcher)['status'], 'finished')

    def test_delivery_failure_does_not_commit_cursor_and_notifies_once(self):
        watcher = self.create()
        with patch.object(WatchersStore, 'deliver_inbox', side_effect=RuntimeError('Synthetic delivery failure')):
            failed = self.execute(watcher)
        self.assertEqual(failed['status'], 'failed')
        self.assertIsNone(self.store.gate_cursor(watcher['id'], 'new'))
        self.assertEqual(len(self.store.inbox()), 1)
        self.assertIn('needs you', self.store.inbox()[0]['title'])
        self.assertEqual(self.execute(watcher)['status'], 'finished')

    def test_gate_without_delivery_commits_only_on_success(self):
        watcher = self.create(deliver=False)
        self.assertEqual(self.execute(watcher)['status'], 'finished')
        self.assertIsNotNone(self.store.gate_cursor(watcher['id'], 'new'))
        self.assertEqual(self.execute(watcher)['status'], 'nothing_new')

    def test_exit_75_stops_cleanly_without_delivery(self):
        watcher = self.create('exit 75')
        run = self.execute(watcher)
        self.assertEqual(run['status'], 'nothing_new')
        self.assertEqual(self.store.inbox(), [])
        self.assertEqual(len(run['step_runs']), 1)

    def test_output_file_wins_and_private_environment_is_removed(self):
        watcher = self.create('printf ignored; printf "$MODEL_API_KEY" > "$HERDR_WATCHER_OUTPUT"', gate=False)
        run = self.execute(watcher, environ={'HERDR_HARNESS_API_TOKEN': 'private-control-token',
                    'HERDR_PRIVATE': 'private-value', 'MODEL_API_KEY': 'synthetic-provider-secret'})
        self.assertEqual(run['status'], 'finished')
        self.assertEqual(self.store.inbox()[0]['body_md'], '[redacted]')
        env = environment({'HERDR_HARNESS_API_TOKEN': 'token', 'HERDR_WATCHERS_PATH': '/test/bin', 'PATH': '/untrusted'},
                          watcher_id='w', run_id='r', step_id='s', input_path='in', output_path='out', state_dir='state')
        self.assertNotIn('HERDR_HARNESS_API_TOKEN', env)
        self.assertNotIn('HERDR_WATCHERS_PATH', env)
        self.assertEqual(env['PATH'], '/test/bin')
        for name in ('HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'LANG'):
            self.assertTrue(env[name])

    def test_timeout_kills_descendants_and_preserves_disk_logs(self):
        marker = self.base / 'escaped'
        watcher = self.create(f'printf before; (sleep 2; touch "{marker}") & wait', gate=False, deliver=False)
        steps = watcher['steps']
        steps[0]['timeout_seconds'] = 1
        watcher = self.store.patch(watcher['id'], {'steps': steps}, watcher['revision'])
        run = self.execute(watcher)
        self.assertEqual(run['status'], 'failed')
        self.assertTrue(run['step_runs'], run['summary'])
        self.assertEqual(run['step_runs'][0]['status'], 'timed_out')
        self.assertEqual(self.store.logs(run['id'])['content'], 'before')
        time.sleep(1.2)
        self.assertFalse(marker.exists())

    def test_output_payload_is_capped_but_disk_log_is_complete(self):
        watcher = self.create('head -c 2200000 /dev/zero', gate=False, deliver=False)
        run = self.execute(watcher)
        result = run['step_runs'][0]
        self.assertEqual(run['status'], 'finished')
        self.assertTrue(result['output_truncated'])
        self.assertEqual(Path(result['output_ref']).stat().st_size, OUTPUT_LIMIT)
        self.assertEqual(Path(result['stdout_path']).stat().st_size, 2200000)
        self.assertTrue(self.store.logs(run['id'])['truncated'])

    def test_once_becomes_done_except_dry_run(self):
        watcher = self.create(once=True)
        self.execute(watcher, 'dry_run')
        self.assertEqual(self.store.get(watcher['id'])['state'], 'draft')
        self.execute(watcher)
        self.assertEqual(self.store.get(watcher['id'])['state'], 'done')

    def test_real_detached_runner_finishes_after_manager_stops(self):
        watcher = self.create('sleep 0.3; printf completed', gate=False, deliver=True)
        runtime = WatchersRuntime(self.store, {'PATH': '/usr/bin:/bin'})
        run = runtime.run_now(watcher['id'])
        self.addCleanup(lambda: runtime.stop_run(run['id']) if self.store.get_run(run['id'])['status'] in ('queued', 'running') else None)
        runtime.stop()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            run = self.store.get_run(run['id'])
            if run['status'] not in ('queued', 'running'):
                break
            time.sleep(0.05)
        if run['status'] != 'finished':
            log = self.store.root / watcher['id'] / 'runs' / run['id'] / 'runner.log'
            self.fail(f"Detached run did not finish: {run}; {log.read_text()}")
        self.assertEqual(self.store.inbox()[0]['body_md'], 'completed')
        runtime.tick()  # Reap the child without retaining a live subprocess object.

    def test_stop_waits_for_worker_and_avoids_delivery(self):
        watcher = self.create('sleep 30; printf unexpected', gate=False, deliver=True)
        runtime = WatchersRuntime(self.store, {'PATH': '/usr/bin:/bin'})
        run = runtime.run_now(watcher['id'])
        self.addCleanup(runtime.stop)
        deadline = time.monotonic() + 5
        while not self.store.get_run(run['id'])['process_pid'] and time.monotonic() < deadline:
            time.sleep(0.02)
        stopped = runtime.stop_run(run['id'])
        self.assertEqual(stopped['status'], 'stopped')
        self.assertEqual(self.store.inbox(), [])
        runtime.tick()

    def test_killed_runner_retains_overlap_and_recovers_its_orphan_script(self):
        marker = self.base / 'orphan-side-effect'
        watcher = self.create(f'sleep 2; touch "{marker}"', gate=False, deliver=False)
        runtime = WatchersRuntime(self.store, {'PATH': '/usr/bin:/bin'})
        run = runtime.run_now(watcher['id'])
        self.addCleanup(runtime.stop)
        deadline = time.monotonic() + 5
        while not self.store.get_run(run['id'])['process_pid'] and time.monotonic() < deadline:
            time.sleep(0.01)
        run = self.store.get_run(run['id'])
        self.assertIsNotNone(run['process_identity'])
        os.kill(run['pid'], signal.SIGKILL)
        runtime._children[run['id']].wait(timeout=3)
        run_dir = self.store.root / watcher['id'] / 'runs' / run['id']
        self.assertTrue(lock_held(run_dir / 'runner.lock'))
        from herdr_harness.watchers.errors import WatchersError
        with self.assertRaises(WatchersError) as caught:
            runtime.run_now(watcher['id'])
        self.assertEqual(caught.exception.code, 'watcher_busy')
        self.store.update_run(run['id'], heartbeat_at=(datetime.now(timezone.utc) - timedelta(seconds=20)).isoformat())
        runtime.tick()
        deadline = time.monotonic() + 3
        while lock_held(run_dir / 'runner.lock') and time.monotonic() < deadline:
            time.sleep(0.02)
        runtime.tick()
        self.assertEqual(self.store.get_run(run['id'])['status'], 'unknown')
        self.assertEqual(len(self.store.inbox()), 1)
        time.sleep(2.1)
        self.assertFalse(marker.exists())

    def test_completed_script_cleans_background_descendants(self):
        marker = self.base / 'background-side-effect'
        watcher = self.create(f'(sleep 1; touch "{marker}") & printf finished', gate=False, deliver=False)
        run = self.execute(watcher)
        self.assertEqual(run['status'], 'finished')
        time.sleep(1.1)
        self.assertFalse(marker.exists())

    def test_known_credential_patterns_are_redacted_without_environment_values(self):
        token = 'ghp_' + 'a' * 36
        marker = 'PRIVATE' + ' KEY'
        private_key = f'-----BEGIN {marker}-----\nsynthetic-key\n-----END {marker}-----'
        cleaned = runner.scrub(token + '\n' + private_key + '\n/Users/example/project', {})
        self.assertNotIn(token, cleaned)
        self.assertNotIn('synthetic-key', cleaned)
        self.assertIn('/Users/example/project', cleaned)
