"""Concurrency, freshness, topology and lifecycle of optional accounting."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock

from herdr_harness.first_mate_runtime import FirstMateRuntime, _write_json
from herdr_harness.first_mate_store import FirstMateStore
from herdr_harness.first_mate_usage_background import BackgroundFirstMateUsage
from test_first_mate_usage import assistant, write_session


class BackgroundUsageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.now = 100.0
        self.usage = BackgroundFirstMateUsage(self.root / 'sessions', capacity=3, clock=lambda: self.now)
        self.addCleanup(self.usage.stop)
        self.path = self.root / 'sessions' / 'one.jsonl'
        write_session(self.path, 'native-one', [assistant('one', 2.5)])
        self.inputs = dict(feature_id='feature-one', assignments=[], jobs=[],
            ledger_sessions=[{'feature_id': 'feature-one', 'native_session_id': 'native-one',
                              'session_file': str(self.path), 'updated_at': '2030-01-01T00:00:00Z'}],
            jobs_root=self.root / 'jobs', updated_at='2030-01-01T00:00:00Z')

    def drain(self, instance=None):
        instance = instance or self.usage
        with instance._lock:
            thread = instance._thread
        if thread:
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive(), 'background refresh did not finish')
        self.assertEqual(instance.health()['pending'], 0)
        self.assertFalse(instance.health()['active'])

    def test_blocked_refresh_never_blocks_readers_and_coalesces_one_owner(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        original = self.usage._engine.account
        def blocked(**arguments):
            entered.set()
            self.assertTrue(release.wait(5))
            return original(**arguments)
        with mock.patch.object(self.usage._engine, 'account', side_effect=blocked) as compute:
            first = self.usage.account(**self.inputs)
            self.assertIsNone(first['usage']['cost_usd'])
            self.assertEqual(first['usage']['refresh_state'], 'pending')
            self.assertTrue(entered.wait(2))
            with ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda _: self.usage.account(**self.inputs), range(40)))
            self.assertTrue(all(result == first for result in results))
            self.assertEqual(compute.call_count, 1)
            self.assertEqual(self.usage.health()['pending'], 0)
            release.set()
            self.drain()
        warmed = self.usage.account(**self.inputs)
        self.assertEqual((warmed['usage']['cost_usd'], warmed['usage']['status']), (2.5, 'complete'))
        self.assertEqual(warmed['usage']['refresh_state'], 'cached')

    def test_queue_cache_and_threads_remain_bounded_under_churn(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        original = self.usage._engine.account
        def blocked(**arguments):
            entered.set()
            self.assertTrue(release.wait(5))
            return original(**arguments)
        with mock.patch.object(self.usage._engine, 'account', side_effect=blocked):
            self.usage.account(**self.inputs)
            self.assertTrue(entered.wait(2))
            for index in range(30):
                identity = 'feature-' + str(index)
                inputs = {**self.inputs, 'feature_id': identity, 'ledger_sessions': [
                    {**self.inputs['ledger_sessions'][0], 'feature_id': identity}]}
                self.usage.account(**inputs)
            self.assertEqual(self.usage.health()['pending'], 3)
            self.assertEqual(len([t for t in threading.enumerate() if t.name == 'first-mate-usage']), 1)
            release.set()
            self.drain()
            self.assertLessEqual(self.usage.health()['cached'], 3)

    def test_fixed_order_polling_larger_than_queue_and_cache_eventually_refreshes_every_feature(self):
        visited = set()
        original = self.usage._engine.account
        def record(**arguments):
            visited.add(arguments['feature_id'])
            return original(**arguments)
        self.usage.capacity = 2
        with mock.patch.object(self.usage._engine, 'account', side_effect=record):
            for _ in range(5):
                self.now += 6
                # A permitted schedule: readers submit their entire list before
                # the worker gets CPU. This reproduced permanent starvation.
                with mock.patch('threading.Thread.start'):
                    for index in range(8):
                        identity = f'feature-{index}'
                        inputs = {**self.inputs, 'feature_id': identity, 'ledger_sessions': [
                            {**self.inputs['ledger_sessions'][0], 'feature_id': identity}]}
                        self.usage.account(**inputs)
                    self.assertLessEqual(self.usage.health()['pending'], 2)
                self.usage._run()
        self.assertEqual(visited, {f'feature-{index}' for index in range(8)})
        self.assertLessEqual(self.usage.health()['cached'], 2)

    def test_changed_ownership_never_reuses_old_account_and_disabled_opens_unbound(self):
        self.usage.account(**self.inputs)
        self.drain()
        conflict = {**self.inputs['ledger_sessions'][0], 'feature_id': 'other-feature'}
        changed = {**self.inputs, 'ledger_sessions': [*self.inputs['ledger_sessions'], conflict]}
        first = self.usage.account(**changed)
        self.assertIsNone(first['usage']['cost_usd'])
        self.assertEqual(first['sessions'], [])
        self.drain()
        self.assertIsNone(self.usage.account(**changed)['usage']['cost_usd'])
        disabled = BackgroundFirstMateUsage(self.root / 'sessions', enabled=False)
        self.addCleanup(disabled.stop)
        self.assertEqual(disabled.discover_session_id(self.path), 'native-one')
        self.assertIsNone(disabled.account(**self.inputs)['usage']['cost_usd'])
        self.assertIsNone(disabled._thread)

    def test_failure_backoff_and_recovery_do_not_rescan_per_poll(self):
        self.usage.account(**self.inputs)
        self.drain()
        self.now += 6
        with mock.patch.object(self.usage._engine, 'account', side_effect=OSError('synthetic')) as compute:
            self.usage.account(**self.inputs)
            self.drain()
            failed = self.usage.account(**self.inputs)
            for _ in range(10):
                self.assertEqual(self.usage.account(**self.inputs), failed)
            self.assertEqual(compute.call_count, 1)
            self.assertEqual((failed['usage']['cost_usd'], failed['usage']['status']), (2.5, 'partial'))
            self.assertTrue(failed['usage']['stale'])
            self.assertEqual(failed['usage']['refresh_state'], 'failed')
        self.now += 6
        self.usage.account(**self.inputs)
        self.drain()
        self.assertEqual(self.usage.account(**self.inputs)['usage']['status'], 'complete')

    def test_unchanged_refresh_keeps_projection_stable_and_append_converges(self):
        self.usage.account(**self.inputs)
        self.drain()
        first = self.usage.account(**self.inputs)
        self.now += 6
        self.assertEqual(self.usage.account(**self.inputs), first)
        self.drain()
        self.assertEqual(self.usage.account(**self.inputs), first)
        with self.path.open('a') as handle:
            handle.write(json.dumps(assistant('two', 1.0)) + '\n')
        self.now += 6
        self.usage.account(**self.inputs)
        self.drain()
        self.assertEqual(self.usage.account(**self.inputs)['usage']['cost_usd'], 3.5)
        restarted = BackgroundFirstMateUsage(self.root / 'sessions', clock=lambda: self.now)
        self.addCleanup(restarted.stop)
        # Cold restart rebuilds asynchronously from retained authoritative data.
        cold = restarted.account(**self.inputs)
        self.assertIsNone(cold['usage']['cost_usd'])
        self.drain(restarted)
        self.assertEqual(restarted.account(**self.inputs)['usage']['cost_usd'], 3.5)

    def test_overdue_or_stopped_worker_cannot_claim_fresh_complete_coverage(self):
        self.usage.account(**self.inputs)
        self.drain()
        self.usage.stop()
        self.now += 31
        stale = self.usage.account(**self.inputs)
        self.assertEqual(stale['usage']['status'], 'partial')
        self.assertEqual(stale['usage']['refresh_state'], 'stopped')
        self.assertIsNone(self.usage._thread)
        self.assertTrue(self.usage.start())
        self.usage.account(**self.inputs)
        self.drain()
        self.assertEqual(self.usage.account(**self.inputs)['usage']['status'], 'complete')

    def test_stop_is_bounded_even_for_a_blocked_refresh_and_prevents_late_publication(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        original = self.usage._engine.account
        def blocked(**arguments):
            entered.set()
            release.wait(5)
            return original(**arguments)
        with mock.patch.object(self.usage._engine, 'account', side_effect=blocked):
            self.usage.account(**self.inputs)
            self.assertTrue(entered.wait(2))
            self.usage.stop()
            self.assertEqual(self.usage.health()['cached'], 0)
            self.assertEqual(self.usage.account(**self.inputs)['usage']['refresh_state'], 'stopped')
            self.assertFalse(self.usage.start())
            self.assertTrue(self.usage.health()['stopped'])
            release.set()
            self.drain()
            self.assertEqual(self.usage.health()['cached'], 0)
            self.assertFalse(self.usage.health()['stopped'])
            self.usage.account(**self.inputs)
            self.drain()
            self.assertEqual(self.usage.account(**self.inputs)['usage']['status'], 'complete')


class RuntimeBackgroundUsageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = FirstMateStore(self.root / 'state.sqlite3')
        self.addCleanup(self.store.close)
        self.runtime = FirstMateRuntime(self.store, environ={'PATH': ''}, runtime_root=self.root / 'runtime')
        self.addCleanup(self.runtime.stop)
        self.feature = self.store.create_feature({'title': 'Synthetic', 'goal': 'Preserve access',
            'cwd': str(self.root), 'request_id': 'synthetic'})
        self.path = self.runtime.root / 'sessions' / 'saved.jsonl'
        write_session(self.path, 'native-saved', [assistant('one', 1)])
        self.job = {'id': 'synthetic-job', 'kind': 'coordinator', 'feature_id': self.feature['id'],
            'session_file': str(self.path), 'claim': {}, 'created_at': self.feature['created_at']}
        _write_json(self.runtime.jobs_root / self.job['id'] / 'job.json', self.job)
        _write_json(self.runtime.jobs_root / self.job['id'] / 'started.json', {})

    def test_cold_list_chat_and_saved_session_do_not_wait_for_usage(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        original = self.runtime.usage._engine.account
        def blocked(**arguments):
            entered.set()
            self.assertTrue(release.wait(5))
            return original(**arguments)
        with mock.patch.object(self.runtime.usage._engine, 'account', side_effect=blocked):
            self.assertTrue(self.runtime.list_features())
            self.assertTrue(entered.wait(2))
            for view in ('chat', 'overview', 'details'):
                result = self.runtime.read_view(self.feature['id'], view=view)
                self.assertEqual(result['feature']['usage']['status'], 'unavailable')
                self.assertTrue(self.runtime.read_view(self.feature['id'], view=view,
                    if_version=result['version'])['unchanged'])
            # Header discovery works while the accounting worker is blocked.
            page = self.runtime.session('native-saved', limit=1)
            self.assertEqual(page['messages'][0]['id'], 'one')
            self.assertEqual(page['usage']['status'], 'unavailable')
            release.set()

    def test_job_parse_cache_revalidates_rewrite_deletion_and_does_not_share_mutable_dicts(self):
        with mock.patch('herdr_harness.first_mate_runtime._read_json', wraps=__import__(
                'herdr_harness.first_mate_runtime', fromlist=['_read_json'])._read_json) as read:
            jobs = self.runtime._jobs()
            jobs[0]['claim']['title'] = 'Only caller copy'
            self.assertNotIn('title', self.runtime._jobs()[0]['claim'])
            self.assertEqual(read.call_count, 1)
            self.job['native_session_id'] = 'native-saved'
            _write_json(self.runtime.jobs_root / self.job['id'] / 'job.json', self.job)
            self.assertEqual(self.runtime._jobs()[0]['native_session_id'], 'native-saved')
            self.assertEqual(read.call_count, 2)
            (self.runtime.jobs_root / self.job['id'] / 'job.json').unlink()
            self.assertEqual(self.runtime._jobs(), [])
            self.assertEqual(self.runtime._jobs_cache, {})


    def test_job_change_during_read_retries_and_repeated_churn_fails_without_omitting_dispatch(self):
        path = self.runtime.jobs_root / self.job['id'] / 'job.json'
        original = __import__('herdr_harness.first_mate_runtime', fromlist=['_read_json'])._read_json
        calls = 0
        def mutate(source):
            nonlocal calls
            result = original(source)
            calls += 1
            self.job['native_session_id'] = 'native-updated-' + str(calls)
            _write_json(path, self.job)
            return result
        from herdr_harness.first_mate_store import FirstMateError
        with mock.patch('herdr_harness.first_mate_runtime._read_json', side_effect=mutate):
            with self.assertRaisesRegex(FirstMateError, 'changed while being read'):
                self.runtime._jobs()
        self.assertEqual(calls, 2)
        self.assertEqual(self.runtime._jobs()[0]['native_session_id'], 'native-updated-2')
        path.write_text('invalid JSON')
        with self.assertRaisesRegex(FirstMateError, 'temporarily unreadable'):
            self.runtime._jobs()


if __name__ == '__main__':
    unittest.main()
