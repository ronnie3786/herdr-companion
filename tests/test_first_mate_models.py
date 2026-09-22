import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

from herdr_harness.first_mate_models import read_model_catalog
from herdr_harness.first_mate_runtime import FirstMateRuntime, _pi_command
from herdr_harness.first_mate_store import FirstMateStore, FirstMateError, SCHEMA


class ModelSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / 'ledger.sqlite3'
        self.store = FirstMateStore(self.path)
        self.feature = self.store.create_feature({'title': 'Timer', 'goal': 'Plan only', 'cwd': self.temp.name, 'request_id': 'create'})

    def tearDown(self):
        self.store.close()
        self.temp.cleanup()

    def settings(self, **overrides):
        return {'model': 'synthetic/reasoner', 'thinking': 'high', 'expected_settings_revision': 0, 'request_id': 'model-1', **overrides}

    def test_settings_survive_restart_without_changing_work_or_queue(self):
        before = self.store.snapshot(self.feature['id'])
        body = self.settings()
        feature = self.store.set_model_settings(self.feature['id'], body)
        self.assertEqual(self.store.set_model_settings(self.feature['id'], body), feature)
        self.store.close()
        self.store = FirstMateStore(self.path)
        after = self.store.snapshot(self.feature['id'])
        self.assertEqual(after['feature']['coordinator_model'], body['model'])
        self.assertEqual(after['feature']['model_settings_revision'], 1)
        for field in ('revision', 'status', 'current_visit_id'):
            self.assertEqual(after['feature'][field], before['feature'][field])
        for field in ('messages', 'assignments', 'visits'):
            self.assertEqual(after[field], before[field])
        self.assertEqual(sum(e['type'] == 'feature.model_settings_changed' for e in after['events']), 1)
        with self.assertRaises(FirstMateError):
            self.store.set_model_settings(self.feature['id'], self.settings(thinking='low'))
        with self.assertRaises(FirstMateError) as conflict:
            self.store.set_model_settings(self.feature['id'], self.settings(request_id='stale'))
        self.assertEqual(conflict.exception.code, 'stale_model_settings')

    def test_invalid_input_does_not_write_or_cancel_work(self):
        for change in ({'thinking': 'ultra'}, {'model': 'unqualified'}, {'model': 'test/bad\n'},
                       {'expected_settings_revision': True}, {'extra': 'value'}, {'model': None}):
            with self.subTest(change=change), self.assertRaises(FirstMateError):
                self.store.set_model_settings(self.feature['id'], self.settings(**change))
        self.assertEqual(self.store.get_feature(self.feature['id'])['model_settings_revision'], 0)

    def test_existing_database_migrates_without_losing_feature(self):
        path = Path(self.temp.name) / 'old.sqlite3'
        db = sqlite3.connect(path)
        old_schema = SCHEMA.replace(' archived_at TEXT, archive_reason TEXT, created_at', ' created_at')
        db.executescript(old_schema)
        db.execute("INSERT INTO fm_features(id,title,goal,cwd,status,revision,created_at,updated_at) VALUES('old','Old','Retain','/tmp','ready',1,'now','now')")
        db.commit(); db.close()
        migrated = FirstMateStore(path)
        self.assertEqual(migrated.get_feature('old')['model_settings_revision'], 0)
        self.assertEqual(migrated.get_feature('old')['goal'], 'Retain')
        self.assertIsNone(migrated.get_feature('old')['archived_at'])
        self.assertEqual([item['id'] for item in migrated.list_features()], ['old'])
        self.assertIsNotNone(migrated._db.execute('SELECT 1 FROM fm_schema WHERE version=4').fetchone())
        migrated.close()

    def test_new_coordinator_turn_captures_settings_but_workers_and_existing_job_do_not_change(self):
        runtime = FirstMateRuntime(self.store, environ={'PATH': os.environ['PATH'], 'HERDR_FIRST_MATE_MODEL': 'synthetic/host'}, runtime_root=Path(self.temp.name) / 'runs')
        # No launch: these are durable dispatch records, just as after a process restart.
        claim = self.store.claim_message(self.feature['id'], runtime.owner)
        old = runtime._new_job(self.feature, kind='coordinator', prompt='Original', claim=claim)
        self.store.finish_message(claim['id'], runtime.owner)
        self.store.set_model_settings(self.feature['id'], self.settings())
        same = runtime._new_job(self.feature, kind='coordinator', prompt='Retry', claim=claim)
        self.assertEqual(same['model'], 'synthetic/host')
        self.assertEqual(same['id'], old['id'])
        new = runtime._new_job(self.feature, kind='coordinator', prompt='Next', claim={**claim, 'id': 'next-turn'})
        self.assertEqual((new['model'], new['thinking'], new['model_settings_revision']), ('synthetic/reasoner', 'high', 1))
        worker = runtime._new_job(self.feature, kind='worker', prompt='Work', claim={'id': 'worker', 'generation': 1})
        self.assertEqual(worker['model'], 'synthetic/host')
        self.assertEqual(worker['thinking'], '')
        self.assertNotIn('--thinking', _pi_command(worker))
        self.store.set_model_settings(self.feature['id'], self.settings(model='', thinking='', expected_settings_revision=1, request_id='reset'))
        reset = runtime._new_job(self.feature, kind='coordinator', prompt='Reset', claim={**claim, 'id': 'reset-turn'})
        self.assertEqual(reset['model'], 'synthetic/host')
        self.assertEqual(reset['thinking'], '')

    def test_claimed_dispatch_is_busy_but_initial_queued_direction_allows_preclaim_selection(self):
        # Feature creation queues its initial direction. Before it is claimed,
        # old clients can still choose the initial coordinator model.
        selected = self.store.set_model_settings(self.feature['id'], self.settings())
        self.assertEqual(selected['model_settings_revision'], 1)
        claim = self.store.claim_message(self.feature['id'], 'coordinator-owner')
        with self.assertRaises(FirstMateError) as conflict:
            self.store.set_model_settings(self.feature['id'], self.settings(
                model='synthetic/other', expected_settings_revision=1, request_id='busy'))
        self.assertEqual(conflict.exception.code, 'coordinator_busy')
        self.assertEqual(self.store.get_feature(self.feature['id'])['model_settings_revision'], 1)
        self.store.release_message(claim['id'], 'coordinator-owner', 'synthetic stop', verified_stopped=True)

    def test_established_session_requires_confirmation_exact_identity_and_idle_queue(self):
        claim = self.store.claim_message(self.feature['id'], 'coordinator-owner')
        session_file = str(Path(self.temp.name) / 'coordinator-session.jsonl')
        self.store.bind_coordinator_session(
            self.feature['id'], 'coordinator-owner', 'native-current', session_file)
        self.store.finish_message(claim['id'], 'coordinator-owner')

        with self.assertRaises(FirstMateError) as confirmation:
            self.store.set_model_settings(self.feature['id'], self.settings(request_id='confirm-required'))
        self.assertEqual(confirmation.exception.code, 'model_change_confirmation_required')
        with self.assertRaises(FirstMateError) as stale:
            self.store.set_model_settings(self.feature['id'], self.settings(
                request_id='stale-session', expected_session_id='native-old',
                confirm_session_model_change=True))
        self.assertEqual(stale.exception.code, 'stale_coordinator_session')

        body = self.settings(request_id='confirmed', expected_session_id='native-current',
                             confirm_session_model_change=True)
        changed = self.store.set_model_settings(self.feature['id'], body)
        self.assertEqual(changed['model_settings_revision'], 1)
        self.store.append_human_message(self.feature['id'], 'Continue safely', 'queued-work')
        with self.assertRaises(FirstMateError) as busy:
            self.store.set_model_settings(self.feature['id'], self.settings(
                model='synthetic/other', expected_settings_revision=1,
                request_id='queued-busy', expected_session_id='native-current',
                confirm_session_model_change=True))
        self.assertEqual(busy.exception.code, 'coordinator_busy')
        queued = self.store.claim_message(self.feature['id'], 'next-turn-owner')
        self.store.finish_message(queued['id'], 'next-turn-owner')

        # An idle no-op never mutates, dispatches, or asks for a redundant confirmation.
        no_op = self.store.set_model_settings(self.feature['id'], self.settings(
            expected_settings_revision=1, request_id='no-op'))
        self.assertEqual(no_op['model_settings_revision'], 1)
        events = self.store.get_events(self.feature['id'])['events']
        self.assertEqual(sum(event['type'] == 'feature.model_settings_changed' for event in events), 1)

    def test_confirmation_is_stale_after_rotation_to_nil_or_a_successor(self):
        claim = self.store.claim_message(self.feature['id'], 'coordinator-owner')
        old_file = str(Path(self.temp.name) / 'coordinator-old.jsonl')
        self.store.bind_coordinator_session(
            self.feature['id'], 'coordinator-owner', 'native-old', old_file)
        self.store.finish_message(claim['id'], 'coordinator-owner')
        self.store.rotate_coordinator_session(
            self.feature['id'], 'native-old', 'rotate-old', verified_stopped=True)

        with self.assertRaises(FirstMateError) as stale:
            self.store.set_model_settings(self.feature['id'], self.settings(
                request_id='stale-after-nil', expected_session_id='native-old',
                confirm_session_model_change=True))
        self.assertEqual(stale.exception.code, 'stale_coordinator_session')
        self.assertEqual(self.store.get_feature(self.feature['id'])['model_settings_revision'], 0)

        self.store.append_human_message(self.feature['id'], 'Continue', 'successor-turn')
        successor_claim = self.store.claim_message(self.feature['id'], 'successor-owner')
        successor_file = str(Path(self.temp.name) / 'coordinator-successor.jsonl')
        self.store.bind_coordinator_session(
            self.feature['id'], 'successor-owner', 'native-successor', successor_file)
        self.store.finish_message(successor_claim['id'], 'successor-owner')
        with self.assertRaises(FirstMateError) as stale:
            self.store.set_model_settings(self.feature['id'], self.settings(
                request_id='stale-after-successor', expected_session_id='native-old',
                confirm_session_model_change=True))
        self.assertEqual(stale.exception.code, 'stale_coordinator_session')
        self.assertEqual(self.store.get_feature(self.feature['id'])['model_settings_revision'], 0)

    def test_identical_confirmed_receipt_replays_after_session_rotation(self):
        claim = self.store.claim_message(self.feature['id'], 'coordinator-owner')
        session_file = str(Path(self.temp.name) / 'coordinator-session.jsonl')
        self.store.bind_coordinator_session(
            self.feature['id'], 'coordinator-owner', 'native-current', session_file)
        self.store.finish_message(claim['id'], 'coordinator-owner')
        body = self.settings(expected_session_id='native-current',
                             confirm_session_model_change=True)
        receipt = self.store.set_model_settings(self.feature['id'], body)
        self.store.rotate_coordinator_session(
            self.feature['id'], 'native-current', 'rotate', verified_stopped=True)
        self.assertIsNone(self.store.get_feature(self.feature['id'])['native_session_id'])
        self.assertEqual(self.store.set_model_settings(self.feature['id'], body), receipt)

    def test_optional_safety_fields_are_strictly_typed(self):
        for change in ({'expected_session_id': None}, {'expected_session_id': ''},
                       {'confirm_session_model_change': 1},
                       {'confirm_session_model_change': 'true'}):
            with self.subTest(change=change), self.assertRaises(FirstMateError) as failure:
                self.store.set_model_settings(self.feature['id'], self.settings(**change))
            self.assertEqual(failure.exception.code, 'invalid_request')

    def test_catalog_runs_no_prompt_and_excludes_sensitive_model_fields(self):
        executable = Path(self.temp.name) / 'pi'
        executable.write_text('#!' + sys.executable + '\n' + '''import json,sys
request=json.loads(sys.stdin.readline())
assert request['type']=='get_available_models'
assert '--no-session' in sys.argv and '--no-extensions' in sys.argv
print(json.dumps({'id':'catalog','success':True,'data':{'models':[{'provider':'synthetic','id':'model','name':'Test Model','reasoning':True,'apiKey':'not-for-clients','baseUrl':'https://private.example.invalid','headers':{'x-private':'secret'}}]}}),flush=True)
sys.stdin.read()
''')
        executable.chmod(0o700)
        catalog = read_model_catalog(str(executable), {
            'PATH': os.environ['PATH'], 'HERDR_FIRST_MATE_MODEL': 'synthetic/host',
            'HERDR_FIRST_MATE_COORDINATOR_THINKING': 'low',
            'HERDR_FIRST_MATE_PLANNER_THINKING': 'high',
            'HERDR_FIRST_MATE_WORKER_MODEL': 'synthetic/worker',
            'HERDR_FIRST_MATE_ARCHITECT_MODEL': 'synthetic/architect',
            'HERDR_FIRST_MATE_ARCHITECT_THINKING': 'xhigh'}, self.temp.name)
        self.assertEqual(catalog['models'], [{'id': 'synthetic/model', 'name': 'Test Model', 'provider': 'synthetic', 'reasoning': True}])
        self.assertEqual(catalog['routing'], {
            'coordinator': {'model': 'synthetic/host', 'thinking': 'low'},
            'planning': {'model': 'synthetic/host', 'thinking': 'high'},
            'execution': {'model': 'synthetic/worker', 'thinking': ''},
            'architect': {'model': 'synthetic/architect', 'thinking': 'xhigh', 'configured': True}})
        self.assertNotIn('private', json.dumps(catalog))

        unset = read_model_catalog(str(executable), {'PATH': os.environ['PATH']}, self.temp.name)
        self.assertEqual(unset['routing']['architect'], {
            'model': '', 'thinking': '', 'configured': False})

if __name__ == '__main__': unittest.main()
