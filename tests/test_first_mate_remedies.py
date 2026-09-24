"""Synthetic recovery remedies retain authorization, outcomes, and human edits."""
import fcntl
import json
import time
import unittest
from unittest.mock import patch

from herdr_harness.first_mate_runtime import DeferredOperation, _coordinator_state, _read_json, _write_json
from herdr_harness.first_mate_store import FirstMateError
from tests import test_first_mate_recovery as fixtures


class FirstMateRemedyTests(unittest.TestCase):
    setUp = fixtures.FirstMateRecoveryTests.setUp
    tearDown = fixtures.FirstMateRecoveryTests.tearDown
    feature = fixtures.FirstMateRecoveryTests.feature
    coordinator = fixtures.FirstMateRecoveryTests.coordinator
    worker = fixtures.FirstMateRecoveryTests.worker
    recovery_coordinator = fixtures.FirstMateRecoveryTests.recovery_coordinator

    def exhaust(self, assignment):
        for i in range(3):
            result = self.store.recover_assignment(assignment['id'], assignment['generation'], 'Stopped without an outcome', f'recover-{i}', verified_stopped=True)
            if i < 2:
                assignment = self.store.claim_assignment(result['id'], f'owner-{i}')
                assignment = self.store.bind_session(assignment['id'], assignment['generation'], f'owner-{i}', f'native-{i}', f'/tmp/synthetic-session-{i}.jsonl', f'run-{i}')
        return result

    def test_exhaustion_stops_incrementing_and_returns_a_real_remedy(self):
        feature, assignment, _ = self.worker()
        result = self.exhaust(assignment)
        self.assertEqual(result['recovery_count'], 2)
        self.assertEqual(result['status'], 'blocked')
        coordinator = self.recovery_coordinator(feature)
        for request in ('repeat-one', 'repeat-two'):
            with self.assertRaises(FirstMateError) as error:
                self.runtime._tool(coordinator, 'fm_recover', {'assignment_id': assignment['id'], 'reason': 'Try again'}, request)
            self.assertEqual(error.exception.code, 'recovery_exhausted')
            self.assertTrue(error.exception.next_permitted_actions[0]['reset_budget'])
        self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 2)
        state = self.runtime._tool(coordinator, 'fm_status', {}, 'status')
        projected = next(a for a in state['assignments'] if a['id'] == assignment['id'])
        self.assertEqual(projected['recovery_remaining'], 0)
        self.assertEqual(projected['recovery_limit'], 2)

    def test_human_reset_is_idempotent_audited_and_bounded_per_direction(self):
        feature, assignment, _ = self.worker()
        exhausted = self.exhaust(assignment)
        coordinator = self.recovery_coordinator(feature)
        params = {'assignment_id': assignment['id'], 'reason': 'Inspected external effects; use the retained checkpoint', 'reset_budget': True}
        result = self.runtime._tool(coordinator, 'fm_recover', params, 'reset')
        self.assertEqual(result, self.runtime._tool(coordinator, 'fm_recover', params, 'reset'))
        self.assertEqual((result['status'], result['recovery_count']), ('queued', 1))
        self.assertEqual(result['metadata']['reliability_reset_generation'], exhausted['generation'])
        events = [e for e in self.store.snapshot(feature['id'])['events'] if e['type'] == 'assignment.recovery_reset']
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['payload']['authorization_message_id'], coordinator['claim']['id'])
        self.store.claim_assignment(assignment['id'], 'new-owner')
        with self.assertRaisesRegex(FirstMateError, 'already reset'):
            self.runtime._tool(coordinator, 'fm_recover', params, 'reset-again')

    def test_lost_recovery_response_never_stops_its_running_successor(self):
        feature, assignment, worker = self.worker()
        coordinator = self.recovery_coordinator(feature)
        directory = self.runtime._job_dir(worker)
        _write_json(directory / 'status.json', {'ended': True})
        params = {'assignment_id': assignment['id'], 'reason': 'Stop and continue', 'stop_running': True}
        result = self.runtime._tool(coordinator, 'fm_recover', params, 'stop-replay')
        successor = self.store.claim_assignment(assignment['id'], 'successor-owner')
        self.store.bind_session(assignment['id'], successor['generation'], 'successor-owner', 'successor-native', '/tmp/synthetic-successor.jsonl', 'successor-run')
        with patch.object(self.runtime, '_quiesce') as stop:
            self.assertEqual(result, self.runtime._tool(coordinator, 'fm_recover', params, 'stop-replay'))
            stop.assert_not_called()
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'running')

    def test_system_reset_and_human_gate_bypass_are_rejected(self):
        feature, assignment, worker = self.worker()
        coordinator = self.recovery_coordinator(feature)
        params = {'assignment_id': assignment['id'], 'reason': 'Continue', 'reset_budget': True}
        coordinator['claim']['role'] = 'system'
        with self.assertRaisesRegex(FirstMateError, 'requires human direction'):
            self.runtime._tool(coordinator, 'fm_recover', params, 'system-reset')
        coordinator['claim']['role'] = 'user'
        self.store.request_human_gate(assignment['id'], 1, worker['native_session_id'], 'Approval required', 'gate')
        with self.assertRaises(FirstMateError):
            self.runtime._tool(coordinator, 'fm_recover', {**params, 'stop_running': True}, 'gate-reset')
        self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 0)

    def test_human_stop_bypasses_wait_lease_but_waits_for_writer(self):
        feature, assignment, worker = self.worker()
        self.store.record_progress(assignment['id'], 1, worker['native_session_id'], 'Build running', 'Inspect build', 'Known build process', 3600, 'lease')
        coordinator = self.recovery_coordinator(feature)
        params = {'assignment_id': assignment['id'], 'reason': 'Stop this worker and continue', 'stop_running': True}
        directory = self.runtime._job_dir(worker)
        with (directory / 'writer.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with self.assertRaises(DeferredOperation):
                self.runtime._tool(coordinator, 'fm_recover', params, 'stop')
            self.assertEqual(self.store.get_assignment(assignment['id'])['recovery_count'], 0)
            controls = [_read_json(p) for p in (directory / 'controls').glob('*.json')]
            self.assertTrue(any(c['action'] == 'abort' for c in controls))
        _write_json(directory / 'status.json', {'ended': True})
        result = self.runtime._tool(coordinator, 'fm_recover', params, 'stop')
        self.assertEqual(result['status'], 'queued')
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'running')
        successor = self.store.claim_assignment(assignment['id'], 'replacement-owner')
        replacement = self.runtime._new_job(self.store.get_feature(feature['id']), kind='worker', claim=successor, prompt=successor['prompt'])
        self.assertTrue(replacement['requires_recovery_ack'])
        self.assertTrue(replacement['requires_recovery_inspection'])
        self.assertEqual(replacement['recovery_source_job_id'], worker['id'])
        with self.assertRaisesRegex(FirstMateError, 'acknowledge recovery'):
            self.runtime._tool(replacement, 'fm_progress', {}, 'premature-progress')

    def test_configuration_block_without_delivery_has_no_outcome(self):
        feature, assignment, _ = self.worker()
        result = self.store.block_dispatch_configuration(assignment['id'], 1, 'Provider unavailable', 'configuration', verified_stopped=True)
        self.assertEqual(result['status'], 'blocked')
        self.assertFalse(result['has_outcome'])

    def test_completed_outcome_survives_late_configuration_failure(self):
        feature, assignment, worker = self.worker()
        self.store.record_outcome(assignment['id'], 1, worker['native_session_id'], 1, 'passed', 'Review findings', 'outcome', documents=[{'title': 'Review', 'content': 'No defects found'}])
        result = self.store.block_dispatch_configuration(assignment['id'], 1, 'Late configuration observation', 'late', verified_stopped=True)
        self.assertEqual(result['status'], 'completed')
        self.assertTrue(result['has_outcome'])
        self.runtime._finish(worker, {'ended': True, 'exit_code': 143})
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'completed')

    def test_readonly_carry_preserves_dirty_human_checkout_and_delegable_visit(self):
        feature, assignment, worker = self.worker()
        revision = self.runtime._git(str(self.cwd), 'rev-parse', 'HEAD')
        self.store.record_outcome(assignment['id'], 1, worker['native_session_id'], 1, 'success', 'Review complete', 'result', code_revision=revision)
        human_file = self.cwd / 'README.md'
        human_file.write_text('Uncommitted human requirements\n')
        coordinator = self.recovery_coordinator(feature)
        with patch.object(self.runtime, '_quiesce', return_value=True):
            result = self.runtime._tool(coordinator, 'fm_revise', {'goal': 'Keep findings and add follow-up work', 'reason': 'New human direction', 'affected_assignment_ids': []}, 'revise')
        self.assertEqual(result['status'], 'running')
        self.assertEqual(human_file.read_text(), 'Uncommitted human requirements\n')
        delegated = self.runtime._tool(coordinator, 'fm_delegate', {'title': 'Follow-up', 'role': 'planner', 'prompt': 'Follow the new direction', 'workspace_mode': 'read_only'}, 'follow-up')
        self.assertEqual(delegated['status'], 'queued')

    def test_no_stage_error_names_permitted_action(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], 'coordinator')
        job = self.runtime._new_job(feature, kind='coordinator', claim=claim, prompt=claim['text'])
        with self.assertRaises(FirstMateError) as error:
            self.runtime._tool(job, 'fm_delegate', {}, 'no-stage')
        self.assertEqual(error.exception.code, 'no_active_stage')
        self.assertEqual(error.exception.next_permitted_actions[0]['tool'], 'fm_begin_stage')

    def test_interrupted_coordinator_reports_committed_and_unknown_operations(self):
        feature, message, job, _ = self.coordinator()
        self.assertEqual(job['timeout_seconds'], 600)
        directory = self.runtime._job_dir(job)
        _write_json(directory / 'requests' / 'done.json', {'action': 'fm_begin_stage'})
        _write_json(directory / 'responses' / 'done.json', {'ok': True})
        _write_json(directory / 'requests' / 'unknown.json', {'action': 'fm_delegate'})
        self.runtime._finish(job, {'ended': True, 'error': 'Execution exceeded its bounded supervisor deadline'})
        snapshot = self.store.snapshot(feature['id'])
        event = next(e for e in snapshot['events'] if e['type'] == 'coordinator.interrupted')
        self.assertEqual([op['status'] for op in event['payload']['operations']], ['completed', 'unconfirmed'])
        reply = snapshot['messages'][-1]['text']
        self.assertIn('fm_begin_stage', reply)
        self.assertIn('Unconfirmed tools: fm_delegate', reply)


if __name__ == '__main__':
    unittest.main()
