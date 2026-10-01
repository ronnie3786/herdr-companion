"""Feature continuity, deliberate forks, and real process workspace exclusion."""
import fcntl
import json
from pathlib import Path
import time
from unittest import TestCase
from unittest.mock import patch

from herdr_harness.first_mate_runtime import FirstMateRuntime, _agent_assignment, _read_json, _write_json, run_detached
from herdr_harness.first_mate_backup import BackupUnavailable
from herdr_harness.first_mate_store import FirstMateError
from herdr_harness.first_mate_workspaces import lock_path
from tests import test_first_mate_runtime as harness


class FeatureWorkspaceTests(TestCase):
    setUp = harness.FirstMateRuntimeTests.setUp
    tearDown = harness.FirstMateRuntimeTests.tearDown
    feature = harness.FirstMateRuntimeTests.feature

    def begin(self, followups=None):
        self.current = self.feature()
        self.human = self.store.claim_message(self.current['id'], self.runtime.owner)
        self.coordinator = {'id': 'fmj_synthetic_router', 'feature_id': self.current['id'], 'kind': 'coordinator', 'claim': self.human,
                            'owner': self.runtime.owner}
        self.visit = self.runtime._tool(self.coordinator, 'fm_begin_stage', {
            'stage_key': 'build', 'title': 'Build', 'followup_stages': followups or []}, 'begin')
        self.store.finish_message(self.human['id'], self.runtime.owner)

    def delegate(self, key, **params):
        return self.runtime._tool(self.coordinator, 'fm_delegate', {
            'title': 'Synthetic ' + key, 'role': 'coder', 'prompt': 'Perform the synthetic task',
            'workspace_mode': 'isolated', **params}, key)

    def finish(self, assignment, verdict='success'):
        claim = self.store.claim_assignment(assignment['id'], self.runtime.owner)
        native = 'synthetic-' + claim['dispatch_id']
        self.store.bind_session(claim['id'], claim['generation'], self.runtime.owner, native,
                                str(self.root / (native + '.jsonl')))
        job = {'feature_id': self.current['id'], 'kind': 'worker', 'claim': claim, 'native_session_id': native,
               'cwd': assignment['metadata']['worktree_path'], 'workspace_mode': assignment['metadata']['workspace_mode']}
        return self.runtime._tool(job, 'fm_outcome', {'verdict': verdict, 'summary': 'Synthetic result'}, 'outcome-' + native)

    def commit(self, path, name, text='Synthetic change\n'):
        (Path(path) / name).write_text(text)
        self.runtime._git(path, 'add', '--', name)
        self.runtime._git(path, 'commit', '-m', 'Synthetic change')
        return self.runtime._git(path, 'rev-parse', 'HEAD')

    def job(self, assignment):
        claim = self.store.claim_assignment(assignment['id'], self.runtime.owner)
        return self.runtime._new_job(self.store.get_feature(self.current['id']), kind='worker',
                                     prompt=assignment['prompt'], claim=claim)

    def pump(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.runtime.reconcile()
            if predicate():
                return
            time.sleep(.03)
        self.fail('Synthetic execution did not reach the expected boundary')

    def trees(self):
        return list((self.runtime.root / 'worktrees').glob('*'))

    def independent(self, key, **params):
        return self.delegate(key, workspace_mode='independent',
                             independence_reason='Uses supplied references and external APIs; needs no live checkout or unfinished code.', **params)

    def test_research_and_pr_body_workers_overlap_code_without_extra_worktrees(self):
        self.begin()
        writer = self.delegate('code', prompt='hold for concurrency check')
        second_writer = self.delegate('follow-up code')
        review = self.delegate('review', workspace_mode='read_only')
        research = self.independent('research', prompt='hold for concurrency check')
        description = self.independent('PR body', prompt='hold for concurrency check')
        parallel = (writer, research, description)
        try:
            self.pump(lambda: all(self.store.get_assignment(a['id'])['status'] == 'running' for a in parallel))
            self.assertEqual(self.store.get_assignment(second_writer['id'])['status'], 'queued')
            self.assertEqual(self.store.get_assignment(review['id'])['status'], 'queued')
            jobs = [j for j in self.runtime._jobs() if j['kind'] == 'worker']
            self.assertEqual(len(jobs), 3)
            self.assertEqual(len({j['cwd'] for j in jobs}), 3)
            self.assertEqual(len(self.trees()), 1)
            self.assertEqual(set(self.runtime._verification_workspace_scope(self.current)['workspaces'].values()),
                             {writer['metadata']['worktree_path']})
        finally:
            (self.runtime.root / 'release-concurrency-check').touch()
        self.pump(lambda: all(a['status'] == 'completed' for a in self.store.list_assignments(feature_id=self.current['id'])), timeout=30)

    def test_independent_work_still_respects_host_worker_limit(self):
        self.begin()
        self.runtime.max_workers = 1
        writer = self.delegate('code', prompt='hold for concurrency check')
        self.pump(lambda: self.store.get_assignment(writer['id'])['status'] == 'running')
        research = self.independent('research')
        try:
            self.runtime.reconcile()
            self.assertEqual(self.store.get_assignment(research['id'])['status'], 'queued')
        finally:
            (self.runtime.root / 'release-concurrency-check').touch()
        self.pump(lambda: self.store.get_assignment(research['id'])['status'] == 'completed', timeout=30)

    def test_independent_work_needs_no_git_and_replay_preserves_scratch_and_routing(self):
        self.begin()
        with patch.object(self.runtime, '_git', side_effect=AssertionError('Independent work must not touch Git')):
            first = self.independent('research')
            scratch = Path(first['metadata']['execution_path'])
            (scratch / 'notes.txt').write_text('Retained research')
            self.runtime.environ['HERDR_FIRST_MATE_WORKER_MODEL'] = 'synthetic/new-default'
            replay = self.independent('research')
        self.assertEqual(first['id'], replay['id'])
        self.assertEqual(first['metadata'], replay['metadata'])
        self.assertEqual((scratch / 'notes.txt').read_text(), 'Retained research')
        self.assertNotIn('worktree_path', first['metadata'])
        self.assertFalse(self.runtime.workspaces.record_path(self.current).exists())
        self.assertEqual(self.trees(), [])
        self.assertEqual(self.runtime._verification_workspace_scope(self.current)['workspaces'], {})
        self.assertEqual(_agent_assignment(first)['operational']['workspace_mode'], 'independent')
        with self.assertRaises(FirstMateError):
            self.independent('research', prompt='Changed instructions')

    def test_independent_work_rejects_ambiguous_scope_before_allocating(self):
        self.begin()
        for params in ({}, {'independence_reason': ' '}, {'independence_reason': 'x', 'workspace_strategy': 'feature'},
                       {'independence_reason': 'x', 'workspace_strategy': 'fork', 'fork_reason': 'x'},
                       {'independence_reason': 'x', 'source_assignment_id': 'synthetic-source'}):
            with self.subTest(params=params), self.assertRaises(FirstMateError):
                self.delegate('bad', workspace_mode='independent', **params)
        self.assertFalse((self.runtime.root / 'independent-workspaces').exists())
        self.assertEqual(self.store.list_assignments(feature_id=self.current['id']), [])
        with self.assertRaises(FirstMateError):
            self.delegate('bad-code', independence_reason='Independent')

    def test_independent_children_do_not_inherit_checkout_or_grant_one(self):
        self.begin()
        parent = self.delegate('code')
        parent_job = self.job(parent)
        self.runtime._bind(parent_job, 'synthetic-code-parent', parent_job['session_file'])
        params = {'title': 'External research', 'role': 'researcher', 'prompt': 'Use supplied sources',
                  'workspace_mode': 'independent', 'independence_reason': 'No checkout or unfinished result needed'}
        child = self.runtime._tool(parent_job, 'fm_delegate', params, 'external-child')
        self.assertEqual(child['metadata']['parent_assignment_id'], parent['id'])
        self.assertNotIn('source_assignment_id', child['metadata'])
        child_job = self.job(child)
        self.assertNotEqual(child_job['cwd'], parent_job['cwd'])
        self.runtime._bind(child_job, 'synthetic-independent-parent', child_job['session_file'])
        nested = self.runtime._tool(child_job, 'fm_delegate', params, 'external-grandchild')
        self.assertNotEqual(nested['metadata']['execution_path'], child_job['cwd'])
        for mode in ('read_only', 'isolated'):
            with self.subTest(mode=mode), self.assertRaises(FirstMateError):
                self.runtime._tool(child_job, 'fm_delegate', {**params, 'workspace_mode': mode}, 'forbidden-'+mode)
        with self.assertRaises(FirstMateError):
            self.delegate('code-from-research', source_assignment_id=child['id'])

    def test_independent_retry_preserves_scratch_and_missing_directory_blocks_launch(self):
        self.begin()
        assignment = self.independent('research')
        job = self.job(assignment)
        self.runtime._bind(job, 'synthetic-research-retry', job['session_file'])
        scratch = Path(job['cwd'])
        (scratch / 'notes.txt').write_text('Retained findings')
        self.runtime._tool(job, 'fm_outcome', {'verdict': 'needs_changes', 'summary': 'Another source needed'}, 'outcome')
        retry = self.runtime._tool(self.coordinator, 'fm_retry', {'assignment_id': assignment['id'], 'prompt': 'Check the extra source'}, 'retry')
        next_job = self.job(retry)
        self.assertEqual(next_job['cwd'], str(scratch))
        self.assertEqual((scratch / 'notes.txt').read_text(), 'Retained findings')
        (scratch / 'notes.txt').unlink()
        scratch.rmdir()
        with self.assertRaises(FirstMateError), patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(next_job)
        spawn.assert_not_called()
        with self.assertRaises(FirstMateError):
            self.independent('research')

    def test_independent_workspace_redirection_is_rejected_before_dispatch(self):
        self.begin()
        assignment = self.independent('research')
        job = self.job(assignment)
        scratch = Path(job['cwd'])
        scratch.rmdir()
        scratch.symlink_to(self.cwd, target_is_directory=True)
        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            with self.assertRaises(FirstMateError):
                self.runtime._launch(job)
            with self.assertRaises(FirstMateError):
                run_detached(self.runtime._job_dir(job))
        spawn.assert_not_called()
        with self.assertRaises(FirstMateError):
            self.independent('research')
        scratch.unlink()
        scratch.parent.rmdir()
        scratch.parent.symlink_to(self.cwd, target_is_directory=True)
        with self.assertRaises(FirstMateError):
            self.independent('other research')

    def test_independent_recovery_does_not_replay_external_effects_or_assume_scratch_backup(self):
        self.begin()
        job = self.job(self.independent('research'))
        directory = self.runtime._job_dir(job)
        with self.assertRaises(BackupUnavailable):
            self.runtime.reliability._preserve(job)
        ready = {'type': 'ledger_ready', 'version': 1, 'job_id': job['id']}
        start = {'type': 'start', 'id': 'external', 'tool': 'bash', 'scope': 'external', 'command': 'gh pr edit 42 --repo synthetic/project --body text'}
        for rows in ([ready, start], [ready, start, {'type': 'end', 'id': 'external', 'is_error': True}],
                     [ready, start, {'type': 'end', 'id': 'external', 'is_error': False}]):
            (directory / 'effects.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
            with self.subTest(rows=rows), self.assertRaises(BackupUnavailable):
                self.runtime.reliability._preserve(job)
        (directory / 'effects.jsonl').write_text(json.dumps(ready)+'\n')
        self.runtime.reliability._preserve(job)
        self.assertEqual(job['recovery_backup']['status'], 'not_needed')

    def test_twenty_three_sequential_stages_keep_one_branch_worktree_and_build_cache(self):
        self.begin()
        original = self.runtime._git(str(self.cwd), 'rev-parse', 'HEAD')
        paths, branches = set(), set()
        for number in range(23):
            if number:
                self.store.append_human_message(self.current['id'], 'Apply the next synthetic feedback round', f'human-{number}')
                human = self.store.claim_message(self.current['id'], self.runtime.owner)
                self.coordinator['claim'] = human
                self.store.start_visit(self.current['id'], f'round-{number}', 'Feedback round', f'stage-{number}', 1, human['id'])
                self.store.finish_message(human['id'], self.runtime.owner)
            assignment = self.delegate(f'edit-{number}')
            path = assignment['metadata']['worktree_path']
            paths.add(path)
            branches.add(self.runtime._git(path, 'branch', '--show-current'))
            if number == 0:
                self.commit(path, '.gitignore', '.build/\n')
                (Path(path) / '.build').mkdir()
                (Path(path) / '.build/cache').write_text('Retained synthetic build cache')
            self.commit(path, f'change-{number}.txt')
            self.finish(assignment)
            self.runtime._tool(self.coordinator, 'fm_complete_stage', {
                'summary': 'Change committed', 'recommendation': 'Continue the authorized sequence'}, f'complete-{number}')
        self.assertEqual(len(paths), 1)
        self.assertEqual(len(branches), 1)
        self.assertEqual(len(self.trees()), 1)
        path = Path(next(iter(paths)))
        self.assertEqual(len(list(path.glob('change-*.txt'))), 23)
        self.assertEqual((path / '.build/cache').read_text(), 'Retained synthetic build cache')
        self.assertEqual(self.runtime._git(str(self.cwd), 'rev-parse', 'HEAD'), original)
        self.assertFalse(list(self.cwd.glob('change-*.txt')))

    def test_restart_feedback_preserves_dirty_staged_untracked_files_and_branch_rename(self):
        self.begin()
        first = self.delegate('first')
        path = first['metadata']['worktree_path']
        self.finish(first)
        self.runtime._git(path, 'branch', '-m', 'feature/synthetic-delivery')
        (Path(path) / 'README.md').write_text('Staged work\n')
        self.runtime._git(path, 'add', 'README.md')
        (Path(path) / 'README.md').write_text('Unstaged continuation\n')
        (Path(path) / 'new.txt').write_text('Untracked work\n')
        before = self.runtime._git(path, 'status', '--porcelain')
        self.runtime = FirstMateRuntime(self.store, environ=self.environ, runtime_root=self.root / 'runtime')
        self.managers.append(self.runtime)
        followup = self.delegate('feedback')
        self.assertEqual(followup['metadata']['worktree_path'], path)
        self.assertEqual(followup['metadata']['branch'], 'feature/synthetic-delivery')
        self.assertEqual(followup['metadata']['source_assignment_id'], first['id'])
        self.assertEqual(self.runtime._git(path, 'status', '--porcelain'), before)
        self.assertEqual(self.runtime._git(path, 'show', ':README.md'), 'Staged work')
        self.assertEqual((Path(path) / 'README.md').read_text(), 'Unstaged continuation\n')
        self.assertEqual((Path(path) / 'new.txt').read_text(), 'Untracked work\n')
        self.assertEqual(self.delegate('first')['metadata'], first['metadata'])
        self.assertEqual(len(self.trees()), 1)

    def test_explicit_fork_is_idempotent_and_does_not_replace_primary(self):
        self.begin()
        first = self.delegate('first')
        self.commit(first['metadata']['worktree_path'], 'feature.txt')
        fork = self.delegate('parallel', workspace_strategy='fork', fork_reason='Independent implementation experiment')
        again = self.delegate('parallel', workspace_strategy='fork', fork_reason='Independent implementation experiment')
        next_work = self.delegate('continue')
        self.assertEqual(fork['id'], again['id'])
        self.assertNotEqual(fork['metadata']['worktree_path'], first['metadata']['worktree_path'])
        self.assertEqual(next_work['metadata']['worktree_path'], first['metadata']['worktree_path'])
        self.assertTrue((Path(fork['metadata']['worktree_path']) / 'feature.txt').exists())
        self.assertEqual(len(self.trees()), 2)
        scope = self.runtime._verification_workspace_scope(self.store.get_feature(self.current['id']))
        self.assertIn(first['metadata']['worktree_path'], scope['workspaces'].values())
        self.assertIn(fork['metadata']['worktree_path'], scope['workspaces'].values())

    def test_invalid_delegation_or_fork_does_not_allocate_a_worktree(self):
        self.begin()
        for params in ({'title': ''}, {'workspace_strategy': 'fork'},
                       {'workspace_strategy': 'fork', 'fork_reason': '  '}, {'workspace_strategy': 'unknown'}):
            with self.subTest(params=params), self.assertRaises(FirstMateError):
                self.delegate('invalid', **params)
        self.assertEqual(self.trees(), [])

    def test_merged_settled_fork_is_evidence_history_and_its_source_is_retained(self):
        self.begin()
        primary = self.delegate('primary')
        self.finish(primary)
        fork = self.delegate('fork', workspace_strategy='fork', fork_reason='Independent change')
        fork_path = fork['metadata']['worktree_path']
        tip = self.commit(fork_path, 'independent.txt')
        self.finish(fork)
        primary_path = primary['metadata']['worktree_path']
        before = self.runtime._verification_workspace_scope(self.store.get_feature(self.current['id']))
        self.assertIn(fork_path, before['workspaces'].values())
        self.runtime._git(primary_path, 'merge', '--ff-only', tip)
        after = self.runtime._verification_workspace_scope(self.store.get_feature(self.current['id']))
        self.assertIn(primary_path, after['workspaces'].values())
        self.assertNotIn(fork_path, after['workspaces'].values())
        self.assertTrue((Path(fork_path) / 'independent.txt').exists())
        (Path(fork_path) / 'unfinished.txt').write_text('Do not retire dirty work')
        dirty = self.runtime._verification_workspace_scope(self.store.get_feature(self.current['id']))
        self.assertIn(fork_path, dirty['workspaces'].values())

    def test_corrupt_primary_record_cannot_allocate_a_replacement(self):
        self.begin()
        first = self.delegate('first')
        self.runtime.workspaces.record_path(self.current).write_text('incomplete')
        with self.assertRaises(FirstMateError) as error:
            self.delegate('replacement')
        self.assertEqual(error.exception.code, 'workspace_identity_mismatch')
        self.assertTrue(Path(first['metadata']['worktree_path']).exists())
        self.assertEqual(len(self.trees()), 1)

    def test_fork_rejects_dirty_source_without_losing_any_edits(self):
        self.begin()
        first = self.delegate('first')
        path = Path(first['metadata']['worktree_path'])
        (path / 'unfinished.txt').write_text('Keep this')
        with self.assertRaisesRegex(FirstMateError, 'Commit the source'):
            self.delegate('fork', workspace_strategy='fork', fork_reason='Parallel work')
        self.assertEqual((path / 'unfinished.txt').read_text(), 'Keep this')
        self.assertEqual(len(self.trees()), 1)

    def legacy(self, key, source=None):
        path = self.runtime.root / 'worktrees' / key
        path.parent.mkdir(exist_ok=True)
        baseline = self.runtime._git(str(self.cwd), 'rev-parse', 'HEAD')
        self.runtime._git(str(self.cwd), 'worktree', 'add', '-b', 'legacy-' + key, str(path), baseline)
        return self.store.create_assignment(self.visit['id'], {
            'title': key, 'role': 'coder', 'prompt': 'Synthetic legacy work', 'request_id': key,
            'metadata': {'workspace_mode': 'isolated', 'worktree_path': str(path), 'base_revision': baseline,
                         'branch': 'legacy-' + key, 'source_assignment_id': source}})

    def test_legacy_lineage_adopts_its_single_leaf_and_keeps_old_checkouts(self):
        self.begin()
        first = self.legacy('old-a')
        second = self.legacy('old-b', first['id'])
        leaf = self.legacy('old-c', second['id'])
        self.commit(leaf['metadata']['worktree_path'], 'deliverable.txt')
        continued = self.delegate('adopt')
        self.assertEqual(continued['metadata']['worktree_path'], str(Path(leaf['metadata']['worktree_path']).resolve()))
        self.assertEqual(continued['metadata']['source_assignment_id'], leaf['id'])
        self.assertEqual(len(self.trees()), 3)

    def test_ambiguous_legacy_branches_require_exact_selection_then_continue_it(self):
        self.begin()
        self.legacy('independent-a')
        selected = self.legacy('independent-b')
        with self.assertRaises(FirstMateError) as error:
            self.delegate('ambiguous')
        self.assertEqual(error.exception.code, 'workspace_selection_required')
        self.assertEqual(len(self.trees()), 2)
        explicit = self.delegate('explicit', source_assignment_id=selected['id'])
        automatic = self.delegate('automatic')
        self.assertEqual(explicit['metadata']['worktree_path'], automatic['metadata']['worktree_path'])
        self.assertEqual(len(self.trees()), 2)

    def test_missing_primary_is_not_replaced_with_a_fresh_worktree(self):
        self.begin()
        assignment = self.delegate('first')
        path = Path(assignment['metadata']['worktree_path'])
        moved = path.with_name(path.name + '-retained')
        path.rename(moved)
        for key in ('first', 'replacement'):
            with self.subTest(key=key), self.assertRaises(FirstMateError) as error:
                self.delegate(key)
            self.assertEqual(error.exception.code, 'workspace_missing')
        self.assertEqual(self.trees(), [moved])

    def test_unrelated_features_get_separate_worktrees(self):
        self.begin()
        first = self.delegate('first')
        other = self.store.create_feature({'title': 'Another feature', 'goal': 'Independent work',
                                          'cwd': str(self.cwd), 'request_id': 'other'})
        metadata = self.runtime._workspace(other, {'workspace_mode': 'isolated'}, 'first')
        self.assertNotEqual(first['metadata']['worktree_path'], metadata['worktree_path'])
        with self.assertRaisesRegex(FirstMateError, 'another feature'):
            self.runtime._workspace(other, {'workspace_mode': 'isolated', 'source_assignment_id': first['id']}, 'foreign')
        self.assertEqual(len(self.trees()), 2)

    def test_retry_and_unknown_recovery_reuse_original_workspace(self):
        self.begin()
        assignment = self.delegate('work')
        self.finish(assignment, verdict='failed')
        retry = self.runtime._tool(self.coordinator, 'fm_retry', {
            'assignment_id': assignment['id'], 'prompt': 'Repair the bounded failure'}, 'retry')
        self.assertEqual(retry['metadata']['worktree_path'], assignment['metadata']['worktree_path'])
        claim = self.store.claim_assignment(retry['id'], self.runtime.owner)
        self.store.mark_dispatch_unknown(claim['id'], claim['generation'], 'Synthetic interruption', 'unknown')
        recovered = self.runtime._tool(self.coordinator, 'fm_recover', {
            'assignment_id': claim['id'], 'reason': 'Synthetic stopped execution has no external effects'}, 'recover')
        self.assertEqual(recovered['id'], assignment['id'])
        self.assertEqual(recovered['metadata']['worktree_path'], assignment['metadata']['worktree_path'])
        self.assertEqual(len(self.trees()), 1)

    def test_review_fix_refresh_records_new_revision_without_another_worktree(self):
        self.begin()
        implementation = self.delegate('implementation')
        self.finish(implementation)
        review = self.delegate('review', workspace_mode='read_only', role='reviewer')
        self.assertEqual(review['metadata']['worktree_path'], implementation['metadata']['worktree_path'])
        self.finish(review)
        fix = self.delegate('fix')
        revision = self.commit(fix['metadata']['worktree_path'], 'fix.txt')
        self.finish(fix)
        with self.assertRaisesRegex(FirstMateError, 'Reviewed code changed'):
            self.runtime._tool(self.coordinator, 'fm_complete_stage', {'summary': 'Complete', 'recommendation': 'Done'}, 'stale')
        refreshed = self.runtime._tool(self.coordinator, 'fm_retry', {
            'assignment_id': review['id'], 'prompt': 'Review the changed source'}, 'refresh')
        self.assertEqual(refreshed['metadata']['expected_code_revision'], revision)
        self.assertEqual(refreshed['metadata']['repair_count'], 0)
        self.finish(refreshed)
        self.runtime._tool(self.coordinator, 'fm_complete_stage', {'summary': 'Reviewed', 'recommendation': 'Done'}, 'complete')
        self.assertEqual(len(self.trees()), 1)

    def test_supervisor_waits_for_workspace_lock_without_starting_an_attempt(self):
        self.begin()
        assignment = self.delegate('work')
        job = self.job(assignment)
        directory = self.runtime._job_dir(job)
        path = lock_path(self.runtime.root, job['cwd'])
        path.parent.mkdir(exist_ok=True)
        with path.open('a') as holder:
            fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
                self.assertEqual(run_detached(directory), 0)
                spawn.assert_not_called()
            self.assertFalse((directory / 'started.json').exists())
        self.runtime._launch(job)
        self.pump(lambda: self.store.get_assignment(assignment['id'])['status'] == 'completed')
        self.assertEqual(self.store.get_assignment(assignment['id'])['attempt'], 1)

    def test_queued_review_of_a_changed_revision_never_sends_a_prompt(self):
        self.begin()
        first = self.delegate('first')
        self.finish(first)
        review = self.delegate('review', workspace_mode='read_only', role='reviewer')
        job = self.job(review)
        self.commit(first['metadata']['worktree_path'], 'later.txt')
        self.assertEqual(run_detached(self.runtime._job_dir(job)), 1)
        self.assertFalse((self.runtime._job_dir(job) / 'argv.json').exists())
        state = _read_json(self.runtime._job_dir(job) / 'status.json')
        self.assertFalse(state['prompt_sent'])
        self.assertIn('review source changed', state['error'])

    def test_real_writers_serialize_while_explicit_fork_runs_independently(self):
        self.begin()
        first = self.delegate('first', prompt='slow synthetic writer')
        second = self.delegate('second', prompt='slow synthetic writer')
        fork = self.delegate('parallel', prompt='slow synthetic writer', workspace_strategy='fork', fork_reason='Independent parallel implementation')
        first_job, fork_job = self.job(first), self.job(fork)
        self.runtime._launch(first_job)
        self.runtime._launch(fork_job)
        self.pump(lambda: all((_read_json(self.runtime._job_dir(job) / 'status.json', {}).get('accepted')) for job in (first_job, fork_job)))
        self.assertEqual(self.store.get_assignment(second['id'])['status'], 'queued')
        self.pump(lambda: all(self.store.get_assignment(a['id'])['status'] == 'completed' for a in (first, second, fork)))
        second_job = next(j for j in self.runtime._jobs() if j['kind'] == 'worker' and j['claim']['id'] == second['id'])
        first_end = _read_json(self.runtime._job_dir(first_job) / 'status.json')['ended_at']
        second_start = _read_json(self.runtime._job_dir(second_job) / 'started.json')['at']
        self.assertGreaterEqual(second_start, first_end)
        self.assertEqual(len(self.trees()), 2)

    def test_nested_children_share_workspace_after_parent_yields_and_resume_same_session(self):
        self.begin()
        parent = self.delegate('parent', prompt='nested review')
        job = self.job(parent)
        self.runtime._launch(job)
        self.pump(lambda: self.store.get_assignment(parent['id'])['status'] == 'completed')
        children = [a for a in self.store.list_assignments(feature_id=self.current['id']) if a['id'] != parent['id']]
        self.assertEqual(len(children), 2)
        self.assertTrue(all(a['status'] == 'completed' for a in children))
        self.assertEqual({a['metadata']['worktree_path'] for a in children}, {parent['metadata']['worktree_path']})
        parent_jobs = [j for j in self.runtime._jobs() if j['kind'] == 'worker' and j['claim']['id'] == parent['id']]
        self.assertEqual(len(parent_jobs), 2)
        self.assertEqual(len({j['session_file'] for j in parent_jobs}), 1)
        self.assertEqual(len(self.trees()), 1)

    def test_legacy_writer_lock_fences_new_assignment_even_after_outcome(self):
        self.begin()
        first = self.delegate('first')
        job = self.job(first)
        claim = job['claim']
        self.store.bind_session(claim['id'], claim['generation'], self.runtime.owner, 'native-legacy',
                                str(self.root / 'legacy-session.jsonl'))
        self.store.record_outcome(claim['id'], claim['generation'], 'native-legacy', claim['input_revision'],
                                  'success', 'Completed', 'legacy-outcome',
                                  code_revision=self.runtime._git(job['cwd'], 'rev-parse', 'HEAD'))
        directory = self.runtime._job_dir(job)
        _write_json(directory / 'started.json', {'pid': 1})
        _write_json(directory / 'status.json', {'ended': True})
        _write_json(directory / 'finalized.json', {'at': 'synthetic'})
        with (directory / 'writer.lock').open('a') as holder:
            fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertTrue(self.runtime._workspace_busy(job['cwd'], 'isolated'))
        self.assertFalse(self.runtime._workspace_busy(job['cwd'], 'isolated'))

    def test_stopped_worker_keeps_workspace_reserved_until_recovery_settles(self):
        self.begin()
        first = self.delegate('interrupted')
        second = self.delegate('queued')
        job = self.job(first)
        directory = self.runtime._job_dir(job)
        _write_json(directory / 'started.json', {'pid': 1})
        _write_json(directory / 'status.json', {'ended': True, 'error': 'Synthetic interrupted write'})
        self.assertTrue(self.runtime._workspace_busy(job['cwd'], 'isolated', assignment_id=second['id']))

        self.store.mark_dispatch_unknown(first['id'], job['claim']['generation'], 'Inspect source and effects', 'unknown')
        _write_json(directory / 'finalized.json', {'at': 'synthetic'})
        self.assertTrue(self.runtime._workspace_busy(job['cwd'], 'isolated', assignment_id=second['id']))
        self.store.recover_assignment(first['id'], job['claim']['generation'], 'Verified stopped synthetic worker',
                                      'recover', verified_stopped=True)
        self.assertFalse(self.runtime._workspace_busy(job['cwd'], 'isolated', assignment_id=first['id']))
        self.assertTrue(self.runtime._workspace_busy(job['cwd'], 'isolated', assignment_id=second['id']))

    def test_reconstructed_pending_dispatches_do_not_deadlock_each_other(self):
        self.begin()
        first, second = self.delegate('first'), self.delegate('second')
        jobs = sorted((self.job(first), self.job(second)), key=lambda j: (j['created_at'], j['id']))
        self.assertFalse(self.runtime._workspace_busy(jobs[0]['cwd'], 'isolated', job=jobs[0]))
        self.assertTrue(self.runtime._workspace_busy(jobs[1]['cwd'], 'isolated', job=jobs[1]))
