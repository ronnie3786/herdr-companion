"""Deterministic hourly sweeps and recovery: synthetic work, no real timers/models."""
import fcntl
import json
from pathlib import Path
import time
import unittest
from unittest.mock import Mock, patch
import zipfile

from herdr_harness.first_mate_backup import BackupUnavailable, capture_backup
from herdr_harness.first_mate_runtime import FirstMateRuntime, _read_json, _write_json
from herdr_harness.first_mate_store import FirstMateError
from tests import test_first_mate_acceptance as fixtures


class FirstMateReliabilityTests(unittest.TestCase):
    setUp = fixtures.FirstMateAcceptanceTests.setUp
    tearDown = fixtures.FirstMateAcceptanceTests.tearDown
    feature = fixtures.FirstMateAcceptanceTests.feature
    def worker(self):
        feature, assignment, job = fixtures.FirstMateAcceptanceTests.worker(self)
        self.ledger(job)
        for coordinator in self.runtime._jobs():
            if coordinator['kind'] == 'coordinator':
                self.ledger(coordinator)
        return feature, assignment, job

    coordinator = fixtures.FirstMateAcceptanceTests.coordinator
    until = fixtures.FirstMateAcceptanceTests.until

    def stalled(self):
        feature, assignment, job = self.worker()
        now = time.time()
        directory = self.runtime._job_dir(job)
        _write_json(directory / 'started.json', {'pid': 0})
        _write_json(directory / 'status.json', {'ended': False, 'accepted': True, 'last_event_epoch': now})
        # Fresh token activity is NOT fresh task progress.
        (directory / 'events.jsonl').write_text(json.dumps({'type':'message_update', 'assistantMessageEvent':{'delta':'Still thinking'}}) + '\n')
        controller = self.runtime.reliability
        record = {'job_id':job['id'], 'assignment_id':assignment['id'], 'phase':'observing',
                  'fingerprint':controller._position(assignment, job), 'progress_epoch':now-7200, 'round':0}
        _write_json(controller._path(assignment['id']), record)
        lock = (directory / 'writer.lock').open('a')
        fcntl.flock(lock, fcntl.LOCK_EX)
        self.addCleanup(lock.close)
        return feature, assignment, job, lock, now

    def isolated(self):
        feature, message, coordinator, visit = self.coordinator()
        self.store.finish_message(message['id'], coordinator['owner'])
        _write_json(self.runtime._job_dir(coordinator) / 'finalized.json', {'at':'test'})
        metadata = self.runtime._workspace(feature, {'workspace_mode':'isolated'}, 'isolated')
        assignment = self.store.create_assignment(visit['id'], {'title':'Implement','role':'coder','prompt':'Implement locally; do not publish','request_id':'coder','metadata':metadata})
        claim = self.store.claim_assignment(assignment['id'], 'coder-owner')
        job = self.runtime._new_job(feature, kind='worker', claim=claim, prompt=claim['prompt'])
        self.runtime._bind(job, 'isolated-native', job['session_file'])
        return feature, self.store.get_assignment(assignment['id']), job

    def ledger(self, job, rows=()):
        path = self.runtime._job_dir(job) / 'effects.jsonl'
        values = [{'type':'ledger_ready','version':1,'job_id':job['id']}, *rows]
        path.write_text(''.join(json.dumps(row)+'\n' for row in values))

    def test_hourly_sweep_assesses_chatty_but_stale_work_then_nudges_and_stops_once(self):
        feature, assignment, job, lock, now = self.stalled()
        controller = self.runtime.reliability
        with patch.object(self.runtime, '_launch') as launch:
            controller.tick(self.runtime._jobs(), now=now)
            self.assertEqual(launch.call_count, 1)
            record = _read_json(controller._path(assignment['id']))
            self.assertEqual(record['phase'], 'assessing')
            self.assertFalse((self.runtime._job_dir(job) / 'controls').exists())
            # An unavailable advisor cannot strand the controller indefinitely.
            controller.tick(self.runtime._jobs(), now=record['deadline'] + 1)
            nudged = _read_json(controller._path(assignment['id']))
            self.assertEqual(nudged['phase'], 'nudged')
            controller.tick(self.runtime._jobs(), now=nudged['deadline'] - 1)
            paths = list((self.runtime._job_dir(job) / 'controls').glob('*.json'))
            self.assertEqual(len(paths), 1)
            self.assertEqual(_read_json(paths[0])['action'], 'steer')
            controller.tick(self.runtime._jobs(), now=nudged['deadline'] + 1)
            actions = sorted(_read_json(p)['action'] for p in (self.runtime._job_dir(job) / 'controls').glob('*.json'))
            self.assertEqual(actions, ['abort', 'steer'])
            self.assertEqual(self.store.get_assignment(assignment['id'])['generation'], 1)
            stopped = _read_json(controller._path(assignment['id']))
            controller.tick(self.runtime._jobs(), now=stopped['deadline'] + 1)
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'blocked')
        self.assertEqual(self.store.get_assignment(assignment['id'])['generation'], 1, 'Never replace an unconfirmed live writer')

    def test_nudge_payload_survives_crash_after_control_before_journal_receipt(self):
        feature, assignment, job, lock, now = self.stalled()
        controller = self.runtime.reliability
        record = _read_json(controller._path(assignment['id']))
        record['round'] = 1
        with patch.object(self.runtime, '_event', side_effect=OSError('synthetic journal outage')):
            with self.assertRaises(OSError):
                controller._nudge(job, record, now, 'Keep the original advisor instruction.')
        pending = _read_json(controller._path(assignment['id']))
        self.assertEqual(pending['phase'], 'nudge_pending')
        controller.tick(self.runtime._jobs(), now=now+10)
        controls = list((self.runtime._job_dir(job)/'controls').glob('*.json'))
        self.assertEqual(len(controls), 1)
        self.assertIn('Keep the original advisor instruction.', _read_json(controls[0])['text'])
        final = _read_json(controller._path(assignment['id']))
        self.assertEqual(final['deadline'], pending['deadline'])
        self.assertEqual(final['phase'], 'nudged')

    def test_disabling_automatic_recovery_never_restarts_a_stopped_worker(self):
        feature, assignment, job = self.worker()
        self.runtime.reliability.enabled = False
        with patch.object(self.runtime, '_launch') as launch:
            self.runtime._finish(job, {'ended':True, 'error':'Interrupted'})
        launch.assert_not_called()
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'recovering')
        self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 0)

    def test_old_handoff_spool_cannot_launch_after_newer_recovery_owns_assignment(self):
        feature, assignment, job = self.worker()
        job['pending_handoff'] = self.store.begin_handoff(assignment['id'], 1, 'handoff', 'Preserved checkpoint')
        self.store.recover_assignment(assignment['id'], 1, 'Explicit recovery', 'manual', verified_stopped=True)
        self.store.claim_assignment(assignment['id'], 'new-owner')
        with patch.object(self.runtime, '_launch') as launch:
            self.runtime._finish(job, {'ended':True})
        launch.assert_not_called()
        self.assertTrue((self.runtime._job_dir(job)/'finalized.json').exists())
        self.assertEqual(self.store.get_assignment(assignment['id'])['generation'], 2)

    def test_evidence_backed_long_build_lease_prevents_nudging(self):
        feature, assignment, job, lock, now = self.stalled()
        self.runtime._tool(job, 'fm_progress', {'summary':'Building the implementation', 'next_action':'Inspect build result', 'evidence':'Build log is growing; compilation phase 3 of 5', 'wait_seconds':3600}, 'build-lease')
        with patch.object(self.runtime, '_launch') as launch:
            self.runtime.reliability.tick(self.runtime._jobs(), now=now+100)
            self.runtime._watch(self.runtime._jobs())
        launch.assert_not_called()
        self.assertFalse((self.runtime._job_dir(job) / 'controls').exists())

    def test_changed_progress_clears_nudge_but_identical_heartbeats_do_not(self):
        feature, assignment, job, lock, now = self.stalled()
        controller = self.runtime.reliability
        with patch.object(self.runtime, '_launch'):
            controller.tick(self.runtime._jobs(), now=now)
            record = _read_json(controller._path(assignment['id']))
            controller.tick(self.runtime._jobs(), now=record['deadline']+1)
            self.runtime._tool(job, 'fm_progress', {'summary':'Implemented the parser', 'next_action':'Run focused tests', 'evidence':'Parser.swift and two regression cases changed'}, 'new-progress')
            controller.tick(self.runtime._jobs(), now=record['deadline']+2)
            record = _read_json(controller._path(assignment['id']))
            self.assertEqual(record['phase'], 'observing')
            position = record['progress_epoch']
            self.runtime._tool(job, 'fm_progress', {'summary':'Implemented the parser', 'next_action':'Run focused tests', 'evidence':'Parser.swift and two regression cases changed'}, 'same-progress')
            controller.next_sweep = 0
            controller.tick(self.runtime._jobs(), now=position+3601)
            record = _read_json(controller._path(assignment['id']))
            self.assertEqual(record['phase'], 'assessing')
            self.assertEqual(record['progress_epoch'], position)

    def test_advisor_can_grant_bounded_continue_without_faking_progress(self):
        feature, assignment, job, lock, now = self.stalled()
        controller = self.runtime.reliability
        with patch.object(self.runtime, '_launch'):
            controller.tick(self.runtime._jobs(), now=now)
            record = _read_json(controller._path(assignment['id']))
            advisor = _read_json(self.runtime.jobs_root / record['advisor_job_id'] / 'job.json')
            with patch('herdr_harness.first_mate_reliability.time.time', return_value=now):
                self.runtime._tool(advisor, 'fm_advice', {'decision':'continue','reason':'The build log shows compilation is still advancing'}, 'continue-build')
            continued = _read_json(controller._path(assignment['id']))
            self.assertEqual(continued['progress_epoch'], record['progress_epoch'])
            self.assertEqual(continued['lease_until'], now + 3600)
            controller.tick(self.runtime._jobs(), now=now+3599)
            self.assertEqual(_read_json(controller._path(assignment['id']))['phase'], 'observing')

    def test_pause_or_pending_human_direction_cancels_automatic_escalation(self):
        feature, assignment, job, lock, now = self.stalled()
        controller = self.runtime.reliability
        with patch.object(self.runtime, '_launch'):
            controller.tick(self.runtime._jobs(), now=now)
        record = _read_json(controller._path(assignment['id']))
        self.store.append_human_message(feature['id'], 'Change direction; hold the previous work', 'new-direction')
        controller.tick(self.runtime._jobs(), now=record['deadline']+1)
        self.assertFalse((self.runtime._job_dir(job) / 'controls').exists())
        self.store.feature_action(feature['id'], 'pause', 'pause')
        controller.tick(self.runtime._jobs(), now=record['deadline']+1000)
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'paused')

    def test_controller_restart_retains_hourly_schedule_and_nudge_deadline(self):
        feature, assignment, job, lock, now = self.stalled()
        with patch.object(self.runtime, '_launch'):
            self.runtime.reliability.tick(self.runtime._jobs(), now=now)
            record = _read_json(self.runtime.reliability._path(assignment['id']))
            self.runtime.reliability.tick(self.runtime._jobs(), now=record['deadline']+1)
        record = _read_json(self.runtime.reliability._path(assignment['id']))
        replacement = FirstMateRuntime(self.store, environ=self.environ, runtime_root=self.runtime.root)
        self.managers.append(replacement)
        self.assertEqual(replacement.reliability.next_sweep, self.runtime.reliability.next_sweep)
        with patch.object(replacement, '_launch') as launch:
            replacement.reliability.tick(replacement._jobs(), now=record['deadline']-1)
        launch.assert_not_called()
        self.assertEqual(len(list((replacement._job_dir(job)/'controls').glob('*.json'))), 1)

    def test_real_stale_worker_is_nudged_stopped_and_restarted_without_human_message(self):
        source = self.fake.read_text()
        source = source.replace("  elif job['kind']=='worker':\n", "  elif job['kind']=='worker':\n   if 'stale-workflow-sample' in job['prompt'] and not job.get('requires_recovery_ack'):\n    continue\n")
        source = source.replace("else: tool('fm_advice',{'decision':'continue','reason':'The observed activity is expected'},'advice')", "else: tool('fm_advice',{'decision':'steer' if job.get('reliability_assessment') else 'continue','reason':'No task progress; nudge the synthetic worker'},'advice')")
        self.fake.write_text(source)
        feature = self.feature('Plan stale-workflow-sample')
        self.until(lambda: any(a['status']=='running' for a in self.store.snapshot(feature['id'])['assignments']) and not any(m['role']=='user' for m in self.store.pending_messages(feature['id'])))
        assignment = self.store.snapshot(feature['id'])['assignments'][0]
        job = next(j for j in self.runtime._jobs() if j['kind']=='worker' and j['claim']['id']==assignment['id'])
        controller = self.runtime.reliability
        now = time.time()
        _write_json(controller._path(assignment['id']), {'job_id':job['id'],'phase':'observing','round':0,
            'progress_epoch':now-7200,'fingerprint':controller._position(assignment,job)})
        controller.next_sweep = 0
        controller.tick(self.runtime._jobs(), now=now)
        self.until(lambda: _read_json(controller._path(assignment['id']), {}).get('phase') == 'nudged')
        nudged = _read_json(controller._path(assignment['id']))
        controller.tick(self.runtime._jobs(), now=nudged['deadline']+1)
        self.until(lambda: self.store.get_feature(feature['id'])['status']=='awaiting_direction', timeout=60)
        final = self.store.get_assignment(assignment['id'])
        self.assertEqual(final['generation'], 2)
        self.assertEqual(final['recovery_count'], 1)
        self.assertEqual(final['status'], 'completed')
        self.assertNotEqual(final['native_session_id'], assignment['native_session_id'])
        self.assertEqual(len([m for m in self.store.snapshot(feature['id'])['messages'] if m['role']=='user']), 1)
        kinds = [e['type'] for e in self.store.get_events(feature['id'])['events']]
        for kind in ('reliability.nudged', 'reliability.stop_requested', 'reliability.restarted', 'reliability.recovery_acknowledged'):
            self.assertIn(kind, kinds)

    def test_checkpointed_automatic_recovery_preserves_source_and_fences_successor(self):
        feature, assignment, job = self.isolated()
        worktree = Path(job['cwd'])
        (worktree / 'README.md').write_text('Uncommitted implementation\n')
        (worktree / 'new.bin').write_bytes(b'\x00new-source\xff')
        self.ledger(job, [{'type':'start','id':'write','scope':'workspace','tool':'write'}])
        original = self.runtime._git(job['cwd'], 'status', '--porcelain')
        with patch.object(self.runtime, '_launch'):
            self.assertFalse(self.runtime.reliability.recover(job, {'error':'synthetic interruption'}))
            advisor = _read_json(self.runtime.jobs_root / job['recovery_job_id'] / 'job.json')
            self.runtime._tool(advisor, 'fm_recovery_brief', {'summary':'Inspect the preserved edit, then run the next focused test; no external commands were pending', 'safe_to_continue':True}, 'safe-brief')
            restored = _read_json(self.runtime._job_dir(job) / 'job.json')
            self.assertTrue(self.runtime.reliability.recover(restored, {}))
            self.assertTrue(self.runtime.reliability.recover(restored, {}))
        self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 1)
        with zipfile.ZipFile(restored['recovery_backup']['path']) as archive:
            self.assertIn(b'Uncommitted implementation', archive.read('tracked.patch'))
            self.assertEqual(archive.read('untracked/new.bin'), b'\x00new-source\xff')
        self.assertEqual(self.runtime._git(job['cwd'], 'status', '--porcelain'), original)
        claim = self.store.claim_assignment(assignment['id'], 'successor-owner')
        successor = self.runtime._new_job(feature, kind='worker', claim=claim, prompt='Continue safely')
        self.assertTrue(successor['requires_recovery_ack'])
        self.runtime._bind(successor, 'successor-native', successor['session_file'])
        with self.assertRaises(FirstMateError):
            self.runtime._tool(successor, 'fm_progress', {'summary':'No inspection yet'}, 'premature')
        result = self.runtime._tool(successor, 'fm_acknowledge_recovery', {'summary':'Workspace and exact next test verified against the retained checkpoint'}, 'acknowledge')
        self.assertTrue(result['acknowledged'])
        self.assertEqual(successor['cwd'], job['cwd'])

    def test_unfinished_external_effect_or_legacy_uninstrumented_worker_never_autoreplays(self):
        feature, assignment, job = self.isolated()
        self.ledger(job, [{'type':'start','id':'publish','tool':'bash','scope':'external'}])
        with patch.object(self.runtime, '_launch') as launch:
            self.assertFalse(self.runtime.reliability.recover(job, {}))
        launch.assert_not_called()
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'blocked')
        self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 0)
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'blocked')
        self.assertEqual(self.store.get_session(assignment['native_session_id'])['status'], 'retained')
        # Explicit human recovery releases this blocker atomically, without a
        # second Resume call or weakening the automatic side-effect gate.
        result = self.store.recover_assignment(assignment['id'], assignment['generation'], 'Human verified the external effect', 'verified-manually', verified_stopped=True)
        self.assertEqual(result['status'], 'queued')
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'running')
        job.pop('safety_ledger_version')
        self.assertFalse(self.runtime.reliability._effects_safe(job))

    def test_read_only_label_never_bypasses_receipts_or_unmanaged_worktree_safety(self):
        feature, assignment, job = self.worker()
        self.ledger(job, [{'type':'start','id':'shell','tool':'bash','scope':'external'}, {'type':'end','id':'shell','is_error':False}])
        with patch.object(self.runtime, '_launch') as launch:
            self.assertFalse(self.runtime.reliability.recover(job, {}))
        launch.assert_not_called()
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'blocked')
        self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 0)
        (self.runtime._job_dir(job) / 'effects.jsonl').unlink()
        self.assertFalse(self.runtime.reliability._effects_safe(job))

    def test_failed_external_receipt_remains_uncertain_and_success_is_inspectable(self):
        feature, assignment, job = self.isolated()
        start = {'type':'start','id':'external','tool':'bash','scope':'external'}
        self.ledger(job, [start, {'type':'end','id':'external','is_error':True}])
        self.assertFalse(self.runtime.reliability._effects_safe(job))
        self.ledger(job, [start, {'type':'end','id':'external','is_error':False}])
        self.assertTrue(self.runtime.reliability._effects_safe(job))
        (self.runtime._job_dir(job) / 'effects.jsonl').write_text('{"partial":')
        self.assertFalse(self.runtime.reliability._effects_safe(job))

    def test_pending_human_gate_prevents_automatic_recovery_even_after_verified_stop(self):
        feature, assignment, job = self.worker()
        self.store.request_human_gate(assignment['id'], 1, assignment['native_session_id'], 'Explicit approval required', 'human-gate')
        with patch.object(self.runtime, '_launch') as launch:
            self.runtime.reliability.tick(self.runtime._jobs(), now=time.time()+7200)
        launch.assert_not_called()
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'awaiting_direction')
        with self.assertRaises(FirstMateError):
            self.store.recover_assignment(assignment['id'], 1, 'automatic attempt', 'auto-gate', verified_stopped=True, automatic=True)

    def test_guardian_restarts_only_dead_scheduler_under_original_manager_lock(self):
        lock = (self.runtime.root/'manager.lock').open('a')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.runtime._manager_lock = lock
        self.runtime._thread = Mock()
        self.runtime._thread.is_alive.return_value = False
        with patch('herdr_harness.first_mate_runtime.threading.Thread') as thread:
            thread.return_value.is_alive.return_value = True
            self.runtime._supervise_once()
            thread.return_value.start.assert_called_once()
            self.runtime._supervise_once()
            thread.return_value.start.assert_called_once()
        self.assertIs(self.runtime._manager_lock, lock)
        self.assertFalse(lock.closed)
        self.runtime._thread = None
        self.runtime._guardian_restarts = [time.monotonic()] * 3
        with patch('herdr_harness.first_mate_runtime.threading.Thread') as thread:
            self.runtime._supervise_once()
            thread.assert_not_called()

    def test_low_space_defers_launch_without_starting_or_replacing_dispatch(self):
        feature, assignment, job = self.worker()
        with patch('herdr_harness.first_mate_runtime.shutil.disk_usage', return_value=Mock(free=1024)), patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            with self.assertRaises(OSError):
                self.runtime._launch(job)
        spawn.assert_not_called()
        self.assertFalse((self.runtime._job_dir(job)/'started.json').exists())
        self.assertEqual(self.store.get_assignment(assignment['id'])['generation'], 1)

    def test_low_space_waits_without_converting_temporary_pressure_into_human_blocker(self):
        feature, assignment, job = self.isolated()
        self.ledger(job)
        with patch('herdr_harness.first_mate_backup.shutil.disk_usage', return_value=Mock(free=self.runtime.minimum_free_bytes + 1024)):
            with self.assertRaises(OSError) as raised:
                self.runtime.reliability.recover(job, {})
        self.assertTrue(raised.exception.storage_low)
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'running')
        self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 0)
        # Once reserve is restored, the same execution can preserve its work and
        # start assessment without another human message or generation change.
        with patch.object(self.runtime, '_launch') as launch:
            self.assertFalse(self.runtime.reliability.recover(job, {}))
        launch.assert_called_once()
        self.assertEqual(job['recovery_backup']['status'], 'saved')

    def test_handoff_churn_circuit_breaker_retains_checkpoint_without_another_rotation(self):
        feature, assignment, job = self.worker()
        for index in range(3):
            self.assertTrue(self.runtime.reliability.allow_handoff({**job, 'id':f'job-{index}'}))
        self.assertFalse(self.runtime.reliability.allow_handoff({**job, 'id':'job-3'}))
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'blocked')
        self.assertEqual(self.store.get_assignment(assignment['id'])['generation'], 1)

    def test_orphaned_stage_coordinator_is_kickstarted_without_authorizing_next_stage(self):
        feature, assignment, job = self.worker()
        self.store.record_outcome(assignment['id'], 1, assignment['native_session_id'], 1, 'success', 'Plan complete', 'outcome')
        for message in self.store.pending_messages(feature['id']):
            claim = self.store.claim_message(feature['id'], 'drain-owner')
            self.store.finish_message(claim['id'], 'drain-owner')
        _write_json(self.runtime._job_dir(job)/'finalized.json', {'at':'test'})
        controller = self.runtime.reliability
        with patch.object(self.runtime, '_launch'):
            controller.tick(self.runtime._jobs(), now=time.time())
            controller.tick(self.runtime._jobs(), now=time.time()+1)
        pending = self.store.pending_messages(feature['id'])
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]['role'], 'system')
        self.assertIn('Do not begin another stage', pending[0]['text'])
        self.assertEqual(len(self.store.snapshot(feature['id'])['visits']), 1)

    def test_backup_reuse_and_symlink_capture_do_not_read_outside_worktree(self):
        feature, assignment, job = self.isolated()
        outside = self.root / 'outside.txt'
        outside.write_text('Outside private content must not enter the archive')
        (Path(job['cwd']) / 'reference').symlink_to(outside)
        first = capture_backup(self.runtime, job)
        second = capture_backup(self.runtime, job)
        self.assertEqual(first, second)
        with zipfile.ZipFile(first['path']) as archive:
            self.assertNotIn('untracked/reference', archive.namelist())
            self.assertEqual(json.loads(archive.read('manifest.json'))['untracked_symlinks']['reference'], str(outside))
        job['cwd'] = str(self.cwd)
        with self.assertRaises(BackupUnavailable):
            capture_backup(self.runtime, job)

    def test_invalid_published_archive_without_job_receipt_becomes_explicit_blocker(self):
        feature, assignment, job = self.isolated()
        self.ledger(job)
        archive = capture_backup(self.runtime, job)
        # Simulate archive publication before the job receipt, then corruption.
        Path(archive['path']).write_bytes(b'not a zip')
        with patch.object(self.runtime, '_launch') as launch:
            self.assertFalse(self.runtime.reliability.recover(job, {}))
        launch.assert_not_called()
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'blocked')
        self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 0)

    def test_corrupt_archive_blocks_successor_instead_of_claiming_preserved_work(self):
        feature, assignment, job = self.isolated()
        self.ledger(job)
        with patch.object(self.runtime, '_launch'):
            self.assertFalse(self.runtime.reliability.recover(job, {}))
        Path(job['recovery_backup']['path']).write_bytes(b'corrupt archive')
        job['recovery_safe_to_continue'] = True
        with patch.object(self.runtime, '_prepare_recovery_brief', return_value=True):
            self.assertFalse(self.runtime.reliability.recover(job, {}))
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'blocked')
        self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 0)

    def test_unchanged_progress_cannot_renew_the_same_wait_forever(self):
        feature, assignment, job = self.worker()
        params = {'summary':'Waiting for build', 'next_action':'Read result', 'evidence':'Build phase unchanged', 'wait_seconds':3600}
        now = time.time()
        with patch('herdr_harness.first_mate_store.time.time', return_value=now):
            original = self.runtime._tool(job, 'fm_progress', params, 'wait-one')
        with patch('herdr_harness.first_mate_store.time.time', return_value=now+3500):
            repeated = self.runtime._tool(job, 'fm_progress', params, 'wait-two')
        self.assertEqual(repeated['wait_until_epoch'], original['wait_until_epoch'])

    def test_progress_receipt_is_bounded_scoped_and_does_not_extend_lease_on_retry(self):
        feature, assignment, job = self.worker()
        params = {'summary':'Checkpoint', 'next_action':'Run tests', 'evidence':'Changed two files', 'wait_seconds':60}
        first = self.runtime._tool(job, 'fm_progress', params, 'progress')
        duplicate = self.runtime._tool(job, 'fm_progress', params, 'progress')
        self.assertEqual(first, duplicate)
        for wait in (3601, -1, True):
            with self.assertRaises(FirstMateError):
                self.runtime._tool(job, 'fm_progress', {**params, 'wait_seconds':wait}, 'bad-wait')
        self.assertEqual(self.store.get_assignment(assignment['id'])['metadata']['progress'], first)


if __name__ == '__main__':
    unittest.main()
