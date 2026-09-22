"""Independent regressions for interrupted First Mate control transitions."""
import json
import fcntl
import unittest
from unittest.mock import patch

from tests import test_first_mate_runtime as fixtures
from herdr_harness.first_mate_runtime import _write_json, _read_json


class FirstMateAcceptanceTests(unittest.TestCase):
    setUp = fixtures.FirstMateRuntimeTests.setUp
    tearDown = fixtures.FirstMateRuntimeTests.tearDown
    feature = fixtures.FirstMateRuntimeTests.feature
    until = fixtures.FirstMateRuntimeTests.until

    def coordinator(self):
        feature = self.feature()
        message = self.store.claim_message(feature['id'], 'original-coordinator-owner')
        job = self.runtime._new_job(feature, kind='coordinator', claim=message, prompt=message['text'])
        visit = self.store.start_visit(feature['id'], 'planning', 'Planning', 'stage', 1, message['id'])
        return feature, message, job, visit

    def worker(self):
        feature, message, coordinator, visit = self.coordinator()
        self.store.finish_message(message['id'], 'original-coordinator-owner')
        _write_json(self.runtime._job_dir(coordinator) / 'finalized.json', {'at':'test'})
        assignment = self.store.create_assignment(visit['id'], {'title':'Planner','role':'planner','prompt':'Plan garden work','request_id':'planner'})
        assignment = self.store.claim_assignment(assignment['id'], 'worker-owner')
        job = self.runtime._new_job(feature, kind='worker', claim=assignment, prompt=assignment['prompt'])
        session_file = job['session_file']
        self.runtime._bind(job, 'synthetic-worker-native', session_file)
        assignment = self.store.get_assignment(assignment['id'])
        return feature, assignment, job

    def test_orphan_message_claim_is_rebuilt_with_original_owner_once(self):
        feature = self.feature()
        message = self.store.claim_message(feature['id'], 'prior-manager')
        self.runtime._recover_claim_gaps()
        self.runtime._recover_claim_gaps()
        jobs = self.runtime._jobs()
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]['claim']['id'], message['id'])
        self.assertEqual(jobs[0]['owner'], 'prior-manager')
        self.assertEqual(self.store.get_feature(feature['id'])['coordinator_owner'], 'prior-manager')

    def test_orphan_worker_dispatch_is_rebuilt_without_new_generation(self):
        feature, message, coordinator, visit = self.coordinator()
        self.store.finish_message(message['id'], 'original-coordinator-owner')
        _write_json(self.runtime._job_dir(coordinator) / 'finalized.json', {'at':'test'})
        assignment = self.store.create_assignment(visit['id'], {'title':'Planner','role':'planner','prompt':'Plan','request_id':'assignment'})
        claim = self.store.claim_assignment(assignment['id'], 'prior-worker-owner')
        self.runtime._recover_claim_gaps()
        self.runtime._recover_claim_gaps()
        workers = [job for job in self.runtime._jobs() if job['kind']=='worker']
        self.assertEqual(len(workers), 1)
        self.assertEqual(workers[0]['owner'], 'prior-worker-owner')
        self.assertEqual(workers[0]['claim']['dispatch_id'], claim['dispatch_id'])
        self.assertEqual(self.store.get_assignment(claim['id'])['generation'], 1)

    def test_handoff_pause_keeps_checkpoint_pending_until_resumed(self):
        feature, assignment, job = self.worker()
        handoff = self.store.begin_handoff(assignment['id'], 1, 'handoff', 'Plan checkpoint with next action')
        job['pending_handoff'] = handoff
        self.runtime._save_job(job)
        _write_json(self.runtime._job_dir(job) / 'status.json', {'ended':True})
        self.store.feature_action(feature['id'], 'pause', 'pause')
        with patch.object(self.runtime, '_launch') as launch:
            self.runtime._finish(job, {'ended':True})
            launch.assert_not_called()
        self.assertFalse((self.runtime._job_dir(job) / 'finalized.json').exists())
        self.store.feature_action(feature['id'], 'resume', 'resume')
        with patch.object(self.runtime, '_launch') as launch:
            self.runtime._finish(job, {'ended':True})
            self.assertEqual(launch.call_count, 1)
        successors = [j for j in self.runtime._jobs() if j.get('handoff_id')==handoff['id']]
        self.assertEqual(len(successors), 1)
        self.assertTrue((self.runtime._job_dir(job) / 'finalized.json').exists())

    def test_cancel_during_handoff_closes_without_starting_successor(self):
        feature, assignment, job = self.worker()
        handoff = self.store.begin_handoff(assignment['id'], 1, 'handoff', 'Retained checkpoint')
        job['pending_handoff'] = handoff
        self.runtime._save_job(job)
        _write_json(self.runtime._job_dir(job) / 'status.json', {'ended':True})
        self.runtime.action(feature['id'], 'cancel', 'cancel')
        with patch.object(self.runtime, '_launch') as launch:
            self.runtime._finish(job, {'ended':True})
            self.runtime._actions()
            launch.assert_not_called()
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'cancelled')
        self.assertEqual(self.store.get_session(assignment['native_session_id'])['status'], 'retained')
        self.assertEqual(self.store.get_document(handoff['document_id'])['content'], 'Retained checkpoint')

    def test_planning_can_report_success_on_existing_dirty_checkout(self):
        (self.cwd / 'README.md').write_text('Uncommitted product requirements\n')
        feature = self.feature()
        metadata = self.runtime._workspace(feature, {'workspace_mode':'read_only','role':'planner'}, 'planning')
        self.assertNotIn('expected_code_revision', metadata)
        self.until(lambda: self.store.get_feature(feature['id'])['status']=='awaiting_direction')
        self.assertTrue(self.runtime._git(str(self.cwd), 'status', '--porcelain'))

    def test_delegation_retry_after_head_change_reuses_original_prepared_metadata(self):
        feature, message, job, visit = self.coordinator()
        params = {'title':'Reviewer','role':'reviewer','prompt':'Review the recorded baseline','workspace_mode':'read_only'}
        first = self.runtime._tool(job, 'fm_delegate', params, 'delegate')
        original_revision = first['metadata']['expected_code_revision']
        (self.cwd / 'another.txt').write_text('A newer independent change\n')
        self.runtime._git(str(self.cwd), 'add', 'another.txt')
        self.runtime._git(str(self.cwd), 'commit', '-m', 'Advance synthetic baseline')
        second = self.runtime._tool(job, 'fm_delegate', params, 'delegate')
        self.assertEqual(first['id'], second['id'])
        self.assertEqual(second['metadata']['expected_code_revision'], original_revision)


    def test_waiting_human_preempts_background_then_claims_before_requeued_update(self):
        feature = self.feature()
        initial = self.store.claim_message(feature['id'], 'owner')
        self.store.finish_message(initial['id'], 'owner')
        background = self.store.queue_system_message(feature['id'], 'Reviewer finished', 'background')
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='coordinator', claim=claim, prompt='Review outcome')
        directory = self.runtime._job_dir(job)
        _write_json(directory / 'started.json', {'pid':0})
        _write_json(directory / 'status.json', {'ended':False, 'accepted':True})
        human = self.store.append_human_message(feature['id'], 'I need to discuss the direction now', 'human')
        with (directory / 'writer.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with patch.object(self.runtime, 'capabilities', return_value={'available':False}):
                self.runtime.reconcile()
            updated = _read_json(directory / 'job.json')
            self.assertTrue(updated['preempt_requested'])
            controls = [_read_json(path) for path in (directory / 'controls').glob('*.json')]
            self.assertEqual([c['action'] for c in controls], ['abort'])
        self.runtime._finish(updated, {'ended':True,'interrupted':True})
        next_message = self.store.claim_message(feature['id'], 'new-owner')
        self.assertEqual(next_message['id'], human['id'])
        self.assertTrue(any(m['id']==background['id'] and m['status']=='queued' for m in self.store.pending_messages()))

    def test_preemption_finish_replay_does_not_release_new_human_writer(self):
        feature = self.feature()
        initial = self.store.claim_message(feature['id'], 'owner')
        self.store.finish_message(initial['id'], 'owner')
        self.store.queue_system_message(feature['id'], 'Background update', 'background')
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='coordinator', claim=claim, prompt='Review update')
        job['preempt_requested'] = True
        self.runtime._finish(job, {'ended':True})
        human = self.store.append_human_message(feature['id'], 'Human direction', 'human')
        self.store.claim_message(feature['id'], 'human-owner')
        # Simulate a process restart before finalization receipt is observed.
        (self.runtime._job_dir(job) / 'finalized.json').unlink()
        self.runtime._finish(job, {'ended':True})
        self.assertEqual(self.store.get_feature(feature['id'])['coordinator_owner'], 'human-owner')
        self.assertEqual(next(m for m in self.store.pending_messages() if m['id']==human['id'])['status'], 'processing')


    def test_selective_runtime_revision_leaves_unaffected_execution_running(self):
        feature, affected, affected_job = self.worker()
        visit_id = affected['visit_id']
        unaffected = self.store.create_assignment(visit_id, {'title':'Unaffected planner','role':'planner','prompt':'Continue scheduling research','request_id':'unaffected'})
        unaffected = self.store.claim_assignment(unaffected['id'], 'unaffected-owner')
        unaffected_job = self.runtime._new_job(feature, kind='worker', claim=unaffected, prompt=unaffected['prompt'])
        self.runtime._bind(unaffected_job, 'unaffected-native', unaffected_job['session_file'])
        _write_json(self.runtime._job_dir(affected_job) / 'status.json', {'ended':True})
        _write_json(self.runtime._job_dir(unaffected_job) / 'status.json', {'ended':False})
        direction = self.store.append_human_message(feature['id'], 'Change only reminders; continue scheduling research', 'direction')
        claim = self.store.claim_message(feature['id'], 'coordinator-new')
        coordinator = self.runtime._new_job(self.store.get_feature(feature['id']), kind='coordinator', claim=claim, prompt=direction['text'])
        with (self.runtime._job_dir(unaffected_job) / 'writer.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            revised = self.runtime._tool(coordinator, 'fm_revise', {'goal':'Revised reminder scope','reason':'Human adjusted one assignment','affected_assignment_ids':[affected['id']]}, 'revise')
            self.assertFalse((_read_json(self.runtime._job_dir(unaffected_job) / 'job.json')).get('cancel_requested',False))
        self.assertEqual(revised['revision'], 2)
        self.assertEqual(self.store.get_assignment(unaffected['id'])['status'], 'running')
        self.assertEqual(self.store.get_assignment(affected['id'])['status'], 'superseded')
        result = self.runtime._tool(unaffected_job, 'fm_outcome', {'verdict':'success','summary':'Unchanged research completed','documents':[{'title':'Research','content':'Scheduling evidence'}]}, 'outcome')
        self.assertEqual(result['status'], 'completed')
        self.runtime._tool(coordinator, 'fm_complete_stage', {'summary':'Updated research stage complete','recommendation':'Choose the next stage'}, 'complete')
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'awaiting_direction')

    def test_coordinator_rotation_retains_old_human_constraints(self):
        feature = self.feature()
        message = self.store.claim_message(feature['id'], 'coordinator')
        self.store.finish_message(message['id'], 'coordinator')
        for index in range(35):
            text = 'Keep the legacy public API intact throughout this feature.' if index == 0 else 'Status request '+str(index)
            message = self.store.append_human_message(feature['id'], text, 'message-'+str(index))
            claim = self.store.claim_message(feature['id'], 'coordinator')
            if index < 34:
                self.store.finish_message(claim['id'], 'coordinator', 'Recorded.')
        job = self.runtime._new_job(self.store.get_feature(feature['id']), kind='coordinator', claim=claim, prompt='Status')
        self.runtime._bind(job, 'synthetic-coordinator-native', job['session_file'])
        telemetry = self.runtime._job_dir(job) / 'telemetry.jsonl'
        telemetry.write_text(json.dumps({'type':'context_usage','native_session_id':'synthetic-coordinator-native',
                                         'time':'2026-09-22T12:00:00Z',
                                         'payload':{'tokens':160000,'contextWindow':200000}})+'\n')
        self.runtime._finish(job, {'ended':True,'response':'Latest status recorded.'})
        checkpoint = _read_json(self.runtime.root / 'checkpoints' / (feature['id']+'.json'))
        self.assertTrue('Keep the legacy public API intact' in json.dumps(checkpoint), 'Coordinator checkpoint dropped an earlier human constraint')
        self.assertEqual(self.store.get_session('synthetic-coordinator-native')['status'], 'retained')
        self.assertIsNone(self.store.get_feature(feature['id'])['native_session_id'])


if __name__ == '__main__':
    unittest.main()
