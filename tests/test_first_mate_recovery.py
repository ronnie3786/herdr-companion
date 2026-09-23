"""Fault injection only: never fill a real disk or touch live First Mate runs."""
import errno
import fcntl
import json
import threading
import time
import unittest
from unittest.mock import Mock, patch

from herdr_harness.first_mate_runtime import FirstMateRuntime, _read_json, _write_json
from herdr_harness.first_mate_store import FirstMateError
from tests import test_first_mate_acceptance as fixtures


class FirstMateRecoveryTests(unittest.TestCase):
    setUp = fixtures.FirstMateAcceptanceTests.setUp
    tearDown = fixtures.FirstMateAcceptanceTests.tearDown
    feature = fixtures.FirstMateAcceptanceTests.feature
    worker = fixtures.FirstMateAcceptanceTests.worker
    coordinator = fixtures.FirstMateAcceptanceTests.coordinator

    def wait_for(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.02)
        self.fail("Timed out waiting for synthetic runtime state")

    def recovery_coordinator(self, feature):
        message = self.store.append_human_message(feature['id'], 'Recover the interrupted assignment after inspection', 'human-recover')
        claim = self.store.claim_message(feature['id'], 'recovery-owner')
        self.assertEqual(claim['id'], message['id'])
        return self.runtime._new_job(self.store.get_feature(feature['id']), kind='coordinator', claim=claim, prompt=message['text'])

    def test_atomic_write_failure_preserves_previous_file_and_removes_partial_temp(self):
        path = self.root / 'atomic.json'
        _write_json(path, {'retained': True})
        for number in (errno.ENOSPC, errno.EROFS, errno.EACCES):
            with self.subTest(errno=number):
                with patch('herdr_harness.first_mate_runtime.os.fsync', side_effect=OSError(number, 'synthetic storage failure')):
                    with self.assertRaises(OSError):
                        _write_json(path, {'replacement': True})
                self.assertEqual(_read_json(path), {'retained': True})
                self.assertEqual(list(self.root.glob('atomic.json.*.tmp')), [])

    def test_scheduler_survives_both_reconcile_and_diagnostic_write_failure_then_recovers(self):
        failed = threading.Event()
        restored = threading.Event()
        calls = []

        def reconcile():
            calls.append(time.monotonic())
            if not restored.is_set():
                failed.set()
                raise OSError(errno.ENOSPC, 'synthetic full disk')

        with patch.object(self.runtime, 'reconcile', side_effect=reconcile), \
             patch('herdr_harness.first_mate_runtime._write_json', side_effect=OSError(errno.ENOSPC, 'diagnostic also fails')):
            self.runtime.start()
            self.assertTrue(failed.wait(2))
            self.wait_for(lambda: self.runtime.health()['status'] == 'degraded')
            self.assertTrue(self.runtime.health()['scheduler_alive'])
            self.assertEqual(self.runtime.health()['error_kind'], 'storage_full')
            for _ in range(20):
                self.runtime.wake()
            time.sleep(.1)
            self.assertEqual(len(calls), 1, 'wake storms must not bypass failure backoff')
            restored.set()
            self.wait_for(lambda: self.runtime.health()['status'] == 'healthy')
            self.assertIsNotNone(self.runtime.health()['last_success_at'])
            self.assertEqual(self.runtime.health()['consecutive_failures'], 0)
            self.runtime.stop()
        self.assertEqual(self.runtime.health()['status'], 'stopped')

    def test_job_error_diagnostic_failure_does_not_skip_other_observations_or_dispatch(self):
        feature, assignment, job = self.worker()
        visit = self.store.get_feature(feature['id'])['current_visit_id']
        other = self.store.create_assignment(visit, {'title':'Other','role':'planner','prompt':'Observe only','request_id':'other'})
        claim = self.store.claim_assignment(other['id'], 'other-owner')
        other_job = self.runtime._new_job(feature, kind='worker', claim=claim, prompt=claim['prompt'])
        observed = []

        def observe(execution):
            observed.append(execution['id'])
            raise OSError(errno.ENOSPC, 'synthetic cursor failure')

        with patch.object(self.runtime, '_observe', side_effect=observe), \
             patch.object(self.runtime, '_event', side_effect=OSError(errno.ENOSPC, 'database is full too')), \
             patch('herdr_harness.first_mate_runtime._write_json', side_effect=OSError(errno.ENOSPC, 'diagnostic failure')), \
             patch.object(self.runtime, '_launch') as launch:
            self.runtime.reconcile()
        self.assertEqual(set(observed), {job['id'], other_job['id']})
        launch.assert_not_called()
        self.assertEqual(self.runtime.health()['error_kind'], 'storage_full')

    def test_original_cursor_error_cascade_recovers_without_manager_restart(self):
        feature, assignment, job = self.worker()
        directory = self.runtime._job_dir(job)
        _write_json(directory / 'started.json', {'pid': 0})
        _write_json(directory / 'status.json', {'ended': False, 'accepted': True})
        (directory / 'events.jsonl').write_text(json.dumps({'type': 'agent_end', 'id': 'retained-event'}) + '\n')
        restored = threading.Event()
        failed_paths = []

        def storage_write(path, value):
            if not restored.is_set():
                failed_paths.append(path.name)
                raise OSError(errno.ENOSPC, 'synthetic full disk')
            _write_json(path, value)

        with patch('herdr_harness.first_mate_runtime._write_json', side_effect=storage_write), \
             patch.object(self.runtime, '_launch'):
            self.runtime.start()
            original_thread = self.runtime._thread
            self.wait_for(lambda: self.runtime.health()['status'] == 'degraded')
            self.assertIn('cursor.json', failed_paths)
            self.assertIn('reconcile-error.json', failed_paths)
            self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'running')
            restored.set()
            # Monitoring resumes automatically, but this legacy synthetic job
            # has no effect ledger: read_only is no longer a tool sandbox.
            self.wait_for(lambda: self.store.get_assignment(assignment['id'])['status'] == 'blocked')
            self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 0)
            self.wait_for(lambda: self.runtime.health()['status'] == 'healthy')
            self.assertIs(self.runtime._thread, original_thread)
            self.assertTrue(_read_json(directory / 'finalized.json')['unknown'])
            self.runtime.stop()

    def test_timed_out_stop_keeps_manager_fencing_lock(self):
        lock = (self.runtime.root / 'manager.lock').open('a')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.runtime._manager_lock = lock
        self.runtime._thread = Mock()
        self.runtime._thread.is_alive.return_value = True
        self.runtime.stop()
        self.assertFalse(lock.closed)
        replacement = FirstMateRuntime(self.store, environ=self.environ, runtime_root=self.runtime.root)
        self.managers.append(replacement)
        replacement.start()
        self.assertIsNone(replacement._thread)
        self.runtime._thread = None
        self.runtime.stop()
        self.assertTrue(lock.closed)

    def test_health_does_not_need_scheduler_mutex_or_storage_and_detects_stall(self):
        entered, release = threading.Event(), threading.Event()

        def stuck_pass():
            with self.runtime._mutex:
                entered.set()
                release.wait(5)

        with patch.object(self.runtime, 'reconcile', side_effect=stuck_pass):
            self.runtime.start()
            try:
                self.assertTrue(entered.wait(2))
                with self.runtime._health_lock:
                    self.runtime._last_progress = time.monotonic() - 61
                with patch('herdr_harness.first_mate_runtime._write_json', side_effect=AssertionError('health must not write')):
                    self.assertEqual(self.runtime.health()['status'], 'stalled')
                    self.assertTrue(self.runtime.capabilities()['runtime_health']['scheduler_alive'])
            finally:
                release.set()
                self.runtime.stop()

    def test_unknown_retains_dirty_workspace_checkpoint_and_latest_handoff_reference(self):
        feature, assignment, job = self.worker()
        handoff = self.store.begin_handoff(assignment['id'], 1, 'handoff', 'Completed one change. Next: run focused tests. Do not deploy.')
        (self.cwd / 'README.md').write_text('Important uncommitted work\n')
        (self.cwd / 'new.txt').write_text('New source file\n')
        original_head = self.runtime._git(str(self.cwd), 'rev-parse', 'HEAD')
        self.runtime._unknown(job)
        checkpoint = _read_json(self.runtime._job_dir(job) / 'recovery-checkpoint.json')
        self.assertEqual(checkpoint['head'], original_head)
        self.assertIn('README.md', checkpoint['working_tree_status'])
        self.assertIn('new.txt', checkpoint['working_tree_status'])
        self.assertFalse(checkpoint['side_effects_verified'])
        self.assertEqual(checkpoint['handoff_document_id'], handoff['document_id'])
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'recovering')
        self.assertEqual(self.store.list_attempts(assignment['id'])[0]['status'], 'unknown')
        self.assertEqual((self.cwd / 'README.md').read_text(), 'Important uncommitted work\n')
        self.assertEqual(self.runtime._git(str(self.cwd), 'rev-parse', 'HEAD'), original_head)
        self.assertTrue(any(m['role'] == 'system' and m['metadata'].get('assignment_id') == assignment['id'] for m in self.store.pending_messages()))

    def test_human_recovery_returns_success_without_second_resume_and_reuses_checkpoint(self):
        feature, assignment, job = self.worker()
        self.runtime._unknown(job)
        coordinator = self.recovery_coordinator(feature)
        params = {'assignment_id': assignment['id'], 'reason': 'Verified the retained workspace and uncertain effects'}
        with patch.object(self.store, 'feature_action', side_effect=AssertionError('Recovery is already atomic')):
            result = self.runtime._tool(coordinator, 'fm_recover', params, 'recover')
            duplicate = self.runtime._tool(coordinator, 'fm_recover', params, 'recover')
        self.assertEqual(result, duplicate)
        self.assertEqual(result['status'], 'queued')
        self.assertEqual(result['recovery_count'], 1)
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'running')
        claim = self.store.claim_assignment(assignment['id'], 'successor-owner')
        successor = self.runtime._new_job(self.store.get_feature(feature['id']), kind='worker', claim=claim, prompt='Continue')
        self.assertNotEqual(successor['id'], job['id'])
        self.assertEqual(successor['cwd'], job['cwd'])
        self.assertIn('Observed recovery facts', successor['prompt'])
        self.assertIn('side_effects_verified', successor['prompt'])
        self.assertIn('request human direction', successor['prompt'])

    def test_recovering_one_assignment_does_not_resume_other_unknown_assignment(self):
        feature, assignment, job = self.worker()
        other = self.store.create_assignment(assignment['visit_id'], {'title':'Other','role':'planner','prompt':'Inspect','request_id':'other'})
        other = self.store.claim_assignment(other['id'], 'other-owner')
        self.store.mark_dispatch_unknown(other['id'], other['generation'], 'Uncertain other writer', 'other-unknown')
        self.runtime._unknown(job)
        coordinator = self.recovery_coordinator(feature)
        self.runtime._tool(coordinator, 'fm_recover', {'assignment_id': assignment['id'], 'reason':'Checked first assignment'}, 'recover-one')
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'recovering')
        with self.assertRaises(FirstMateError) as error:
            self.store.claim_assignment(assignment['id'], 'not-yet')
        self.assertEqual(error.exception.code, 'not_dispatchable')
        self.store.feature_action(feature['id'], 'resume', 'generic-resume')
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'recovering')

    def test_recovery_never_bypasses_live_writer_human_gate_or_system_authority(self):
        feature, assignment, job = self.worker()
        coordinator = self.recovery_coordinator(feature)
        params = {'assignment_id': assignment['id'], 'reason':'Recover'}
        with (self.runtime._job_dir(job) / 'writer.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with self.assertRaises(FirstMateError):
                self.runtime._tool(coordinator, 'fm_recover', params, 'live')
        self.store.request_human_gate(assignment['id'], 1, assignment['native_session_id'], 'Approve the intended deployment separately', 'gate')
        with self.assertRaises(FirstMateError) as error:
            self.runtime._tool(coordinator, 'fm_recover', params, 'gate-bypass')
        self.assertEqual(error.exception.code, 'human_direction_required')
        coordinator['claim']['role'] = 'system'
        with self.assertRaises(FirstMateError) as error:
            self.runtime._tool(coordinator, 'fm_recover', params, 'system')
        self.assertEqual(error.exception.code, 'human_direction_required')

    def test_unknown_finalization_retries_after_crash_without_duplicate_notice(self):
        feature, assignment, job = self.worker()
        original_write = _write_json

        def fail_final(path, value):
            if path.name == 'finalized.json':
                raise OSError(errno.ENOSPC, 'synthetic final receipt failure')
            original_write(path, value)

        with patch('herdr_harness.first_mate_runtime._write_json', side_effect=fail_final):
            with self.assertRaises(OSError):
                self.runtime._unknown(job)
        replacement = FirstMateRuntime(self.store, environ=self.environ, runtime_root=self.runtime.root)
        self.managers.append(replacement)
        reloaded = _read_json(replacement._job_dir(job) / 'job.json')
        self.assertTrue(reloaded['unknown_recorded'])
        replacement._unknown(reloaded)
        self.assertTrue(_read_json(replacement._job_dir(job) / 'finalized.json')['unknown'])
        events = self.store.get_events(feature['id'])['events']
        self.assertEqual(sum(e['type'] == 'assignment.dispatch_unknown' for e in events), 1)

    def test_typed_outcome_is_not_overwritten_by_unknown_supervisor_exit(self):
        feature, assignment, job = self.worker()
        self.store.record_outcome(assignment['id'], 1, assignment['native_session_id'], 1, 'success', 'Evidence retained', 'outcome')
        self.runtime._unknown(job)
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'completed')
        self.assertFalse(any(e['type'] == 'assignment.dispatch_unknown' for e in self.store.get_events(feature['id'])['events']))


if __name__ == '__main__':
    unittest.main()
