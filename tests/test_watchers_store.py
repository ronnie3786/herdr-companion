from __future__ import annotations

import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from herdr_harness.watchers.errors import WatchersError
from herdr_harness.watchers.store import WatchersStore, iso


def definition(**changes):
    value = {'name': 'Synthetic check', 'timezone': 'UTC', 'schedule': {'kind': 'interval', 'every_minutes': 5},
             'summary': '{time}, I run {script:check.sh}.',
             'steps': [{'id': 'check', 'kind': 'script', 'title': 'Check synthetic data', 'file': 'check.sh', 'interpreter': '/bin/bash'}]}
    value.update(changes)
    return value


class WatcherStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.now = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
        self.store = WatchersStore(self.base / 'watchers.sqlite3', self.base / 'watchers', {'id': 'synthetic', 'name': 'Test machine'}, clock=lambda: self.now)

    def create(self, **changes):
        return self.store.create(definition(**changes), scripts={'check': 'printf original'})

    def test_request_replay_conflict_and_private_files(self):
        first = self.store.create(definition(), scripts={'check': 'printf original'}, request_id='create-1')
        self.assertEqual(first, self.store.create(definition(), scripts={'check': 'printf original'}, request_id='create-1'))
        with self.assertRaises(WatchersError) as caught:
            self.store.create(definition(name='Different'), request_id='create-1')
        self.assertEqual(caught.exception.code, 'idempotency_conflict')
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        for path in self.store.root.rglob('*'):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700 if path.is_dir() else 0o600)
        for key in ('state', 'avatar', 'machine', 'kind', 'summary', 'next_fire_at', 'live', 'attention', 'runs_count'):
            self.assertIn(key, first)
        self.assertEqual(first['machine']['id'], 'synthetic')

    def test_atomic_patch_revision_conflict_and_frozen_script(self):
        watcher = self.create()
        run = self.store.create_run(watcher['id'], 'manual')
        edited = self.store.patch(watcher['id'], {'name': 'New name'}, 1, scripts={'check': 'printf new'}, request_id='patch-1')
        self.assertEqual(edited['revision'], 2)
        frozen = self.store.root / watcher['id'] / 'runs' / run['id'] / 'scripts' / 'check.sh'
        self.assertEqual(frozen.read_text(), 'printf original')
        self.assertEqual(self.store.get_script(watcher['id'], 'check')['content'], 'printf new')
        with self.assertRaises(WatchersError) as caught:
            self.store.patch(watcher['id'], {'name': 'Old revision'}, 1)
        self.assertEqual(caught.exception.code, 'revision_conflict')
        self.assertEqual(caught.exception.status, 409)

    def test_activation_confirmation_resume_and_next_from_now(self):
        watcher = self.create()
        with self.assertRaises(WatchersError):
            self.store.transition(watcher['id'], 'active')
        active = self.store.transition(watcher['id'], 'active', confirmed_by='user', activated_via='test')
        self.assertEqual(active['activated_by'], 'user')
        self.assertEqual(active['next_fire_at'], '2026-01-01T12:05:00Z')
        self.store.transition(watcher['id'], 'paused')
        self.now += timedelta(hours=6)
        resumed = self.store.transition(watcher['id'], 'active')
        self.assertEqual(resumed['next_fire_at'], '2026-01-01T18:05:00Z')

    def test_incomplete_draft_cannot_activate(self):
        watcher = self.store.create(definition())
        with self.assertRaises(WatchersError) as caught:
            self.store.transition(watcher['id'], 'active', confirmed_by='user')
        self.assertEqual(caught.exception.code, 'script_missing')

    def test_batch_import_validation_is_atomic_and_source_idempotent(self):
        entries = [{'definition': definition(name=f'Job {i}', source={'kind': 'cronboard', 'job_id': f'job-{i}'}),
                    'scripts': {'check': 'true'}, 'state': 'draft'} for i in range(10)]
        invalid = json.loads(json.dumps(entries))
        invalid[-1]['definition']['schedule']['every_minutes'] = 0
        with self.assertRaises(WatchersError):
            self.store.batch_create(invalid)
        self.assertEqual(self.store.list(), [])
        result = self.store.batch_create(entries)
        replay = self.store.batch_create(entries)
        self.assertEqual([w['id'] for w in result], [w['id'] for w in replay])
        self.assertEqual(len(self.store.list(source='cronboard')), 10)

    def test_source_transitions_replay_and_do_not_activate_drafts(self):
        entries = [{'definition': definition(name=f'Job {i}', source={'kind': 'cronboard', 'job_id': f'job-{i}'},
                    activated_by='user', activated_via='cronboard-import'), 'scripts': {'check': 'true'},
                    'state': 'paused' if i else 'draft'} for i in range(3)]
        self.store.batch_create(entries)
        first = self.store.transition_source('cronboard', 'active', request_id='resume-source')
        self.assertEqual(len(first), 2)
        self.assertEqual(first, self.store.transition_source('cronboard', 'active', request_id='resume-source'))
        self.assertEqual(len(self.store.list(state='draft')), 1)
        self.assertNotIn('activated_by', self.store.list(state='draft')[0])
        paused = self.store.transition_source('cronboard', 'paused', request_id='pause-source')
        self.assertEqual(len(paused), 2)

    def test_retention_keeps_two_hundred_or_thirty_days_and_inbox_ninety(self):
        watcher = self.create()
        with self.store.connection(write=True) as db:
            for i in range(205):
                date = self.now - timedelta(days=40, seconds=i)
                db.execute('INSERT INTO runs(id,watcher_id,revision,trigger,started_at,status,snapshot_json) VALUES(?,?,?,?,?,?,?)',
                           (f'run_{i}', watcher['id'], 1, 'manual', iso(date), 'finished', json.dumps(definition())))
                path = self.store.root / watcher['id'] / 'runs' / f'run_{i}'
                path.mkdir(parents=True)
                (path / 'log').write_text('synthetic')
            db.execute('INSERT INTO inbox_items VALUES(?,?,?,?,?,?,NULL)', ('old', watcher['id'], None, 'Old', '', iso(self.now - timedelta(days=91))))
        result = self.store.prune()
        self.assertEqual(result, {'runs': 5, 'inbox_items': 1})
        self.assertEqual(len(self.store.runs(watcher['id'], limit=1000)), 200)
        self.assertFalse((self.store.root / watcher['id'] / 'runs' / 'run_204').exists())
        self.assertTrue((self.store.root / watcher['id'] / 'runs' / 'run_199').exists())
        self.now -= timedelta(days=20)
        self.assertEqual(self.store.prune()['runs'], 0)

    def test_running_run_prevents_forced_delete(self):
        watcher = self.create()
        run = self.store.create_run(watcher['id'], 'manual')
        with self.assertRaises(WatchersError):
            self.store.delete(watcher['id'], force=True)
        self.store.complete_run(run['id'], 'stopped', 'Stopped.')
        self.store.delete(watcher['id'], force=True)
        self.assertEqual(self.store.list(), [])

    def test_once_completion_does_not_overwrite_newer_revision(self):
        watcher = self.create(schedule={'kind': 'once', 'at': '2026-01-01T13:00:00Z'})
        run = self.store.create_run(watcher['id'], 'manual')
        self.store.patch(watcher['id'], {'schedule': {'kind': 'interval', 'every_minutes': 5}}, watcher['revision'])
        self.store.complete_run(run['id'], 'finished', 'Finished.')
        self.assertEqual(self.store.get(watcher['id'])['state'], 'draft')

    def test_active_patch_rejects_unsupported_and_missing_scripts(self):
        watcher = self.create()
        watcher = self.store.transition(watcher['id'], 'active', confirmed_by='user')
        scripts = watcher['steps'] + [{'id': 'missing', 'kind': 'script', 'file': 'missing.sh', 'title': 'Missing'}]
        with self.assertRaises(WatchersError) as caught:
            self.store.patch(watcher['id'], {'steps': scripts}, watcher['revision'])
        self.assertEqual(caught.exception.code, 'script_missing')
        agent = {'id': 'agent', 'kind': 'agent', 'model': 'synthetic/model', 'instructions': 'Summarize synthetic data'}
        with self.assertRaises(WatchersError) as caught:
            self.store.patch(watcher['id'], {'steps': watcher['steps'] + [agent]}, watcher['revision'])
        self.assertEqual(caught.exception.code, 'step_kind_unsupported')
        self.assertEqual(self.store.get(watcher['id'])['revision'], watcher['revision'])

    def test_edit_draft_preserves_live_original_until_confirmed_save(self):
        watcher = self.create(source={'kind': 'cronboard', 'job_id': 'synthetic-original'})
        watcher = self.store.transition(watcher['id'], 'active', confirmed_by='user')
        draft = self.store.create_edit_draft(watcher['id'], 'builder-test', request_id='stage-edit')
        self.assertNotIn('source', draft)
        self.assertEqual(draft['edit_target_id'], watcher['id'])
        self.assertEqual(draft['state'], 'draft')
        self.assertEqual(self.store.get_script(draft['id'], 'check')['content'], 'printf original')
        self.store.patch(draft['id'], {'name': 'Edited watcher'}, draft['revision'], scripts={'check': 'printf edited'})
        self.assertEqual(self.store.get(watcher['id'])['name'], watcher['name'])
        self.assertEqual(self.store.get_script(watcher['id'], 'check')['content'], 'printf original')
        with self.assertRaises(WatchersError):
            self.store.apply_edit_draft(draft['id'])
        with self.assertRaises(WatchersError):
            self.store.transition(draft['id'], 'active', confirmed_by='user')
        saved = self.store.apply_edit_draft(draft['id'], confirmed_by='user', request_id='save-edit')
        self.assertEqual(saved['id'], watcher['id'])
        self.assertEqual(saved['revision'], watcher['revision'] + 1)
        self.assertEqual(saved['state'], 'active')
        self.assertEqual(saved['source']['job_id'], 'synthetic-original')
        self.assertEqual(saved['name'], 'Edited watcher')
        self.assertEqual(self.store.get_script(watcher['id'], 'check')['content'], 'printf edited')
        self.assertEqual(self.store.get(draft['id'])['state'], 'done')
        self.assertEqual(len(self.store.list(state='active')), 1)
        self.assertEqual(saved, self.store.apply_edit_draft(draft['id'], confirmed_by='user', request_id='save-edit'))

    def test_edit_draft_conflict_preserves_both_definitions(self):
        watcher = self.create()
        draft = self.store.create_edit_draft(watcher['id'], 'builder-test')
        self.store.patch(watcher['id'], {'name': 'Another edit'}, watcher['revision'])
        with self.assertRaises(WatchersError) as caught:
            self.store.apply_edit_draft(draft['id'], confirmed_by='user')
        self.assertEqual(caught.exception.code, 'revision_conflict')
        self.assertEqual(self.store.get(draft['id'])['state'], 'draft')
        self.assertEqual(self.store.get(watcher['id'])['name'], 'Another edit')

    def test_claim_due_does_not_advance_if_run_creation_fails(self):
        from unittest.mock import patch
        watcher = self.create()
        watcher = self.store.transition(watcher['id'], 'active', confirmed_by='user')
        self.now += timedelta(minutes=5)
        with patch.object(self.store, '_create_run', side_effect=OSError('Synthetic disk failure')):
            with self.assertRaises(OSError):
                self.store.claim_due(watcher['id'], watcher['next_fire_at'], 'scheduled', self.now + timedelta(minutes=5))
        self.assertEqual(self.store.get(watcher['id'])['next_fire_at'], watcher['next_fire_at'])
        self.assertEqual(self.store.runs(), [])

    def test_once_projection_refreshes_time_phrase(self):
        watcher = self.create(schedule={'kind': 'once', 'at': '2026-01-02T13:00:00Z'})
        self.assertIn('tomorrow', watcher['schedule']['summary'])
        self.now += timedelta(days=1)
        projection = self.store.get(watcher['id'])
        self.assertIn('today', projection['schedule']['summary'])
        self.assertIn('today', projection['summary_text'].lower())

    def test_inbox_and_stop_receipts_replay_and_reject_different_payloads(self):
        watcher = self.create()
        run = self.store.create_run(watcher['id'], 'manual')
        self.store.deliver_inbox(run['id'], 'post', {'kind': 'inbox'}, 'Result', 'Synthetic')
        item = self.store.inbox()[0]
        self.assertEqual(self.store.unread_count(), 1)
        first = self.store.mark_inbox_read(item['id'], request_id='read-item')
        self.assertEqual(first, self.store.mark_inbox_read(item['id'], request_id='read-item'))
        self.assertEqual(self.store.unread_count(), 0)
        with self.assertRaises(WatchersError) as caught:
            self.store.mark_inbox_read('another-item', request_id='read-item')
        self.assertEqual(caught.exception.code, 'idempotency_conflict')
        stopped = self.store.request_stop(run['id'], request_id='stop-run')
        self.assertEqual(stopped, self.store.request_stop(run['id'], request_id='stop-run'))
        with self.assertRaises(WatchersError) as caught:
            self.store.request_stop('another-run', request_id='stop-run')
        self.assertEqual(caught.exception.code, 'idempotency_conflict')
        self.assertEqual(self.store.get_run(run['id'])['stop_requested'], 1)
        result = self.store.mark_all_inbox_read(request_id='read-all')
        self.assertEqual(result, self.store.mark_all_inbox_read(request_id='read-all'))
