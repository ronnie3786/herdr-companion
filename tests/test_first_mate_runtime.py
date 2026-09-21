"""Real detached process/RPC/spool tests with a deterministic synthetic provider.

The fake executable substitutes only model decisions, preserving process locks,
Pi JSONL framing, scoped requests, persisted sessions, manager restarts and DB
transactions. No provider credentials or production data are needed.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from herdr_harness.first_mate_runtime import (COORDINATOR_PROMPT, COORDINATOR_TOOLS,
    WORKER_PROMPT, FirstMateRuntime, _coordinator_state, _ledger_event, _locked,
    _pi_command, _read_json, _records, _write_json)
from herdr_harness.first_mate_store import FirstMateStore, FirstMateError

FAKE_PI = r'''#!PYTHON
import hashlib,json,os,sys,time,uuid
from pathlib import Path
root=Path(os.environ['HERDR_FIRST_MATE_JOB_DIR'])
job=json.loads((root/'job.json').read_text())
(root/'argv.json').write_text(json.dumps(sys.argv))
session=Path(job['session_file'])
session.parent.mkdir(parents=True,exist_ok=True)
if session.exists() and session.stat().st_size:
 sid=json.loads(session.read_text().splitlines()[0])['id']
else:
 sid=str(uuid.uuid4())
 session.write_text(json.dumps({'type':'session','id':sid,'version':3,'cwd':job['cwd'],'timestamp':'2026-01-01T00:00:00Z'})+'\n')
def emit(value): print(json.dumps(value),flush=True)
def save(role,text):
 with session.open('a') as f:f.write(json.dumps({'type':'message','id':uuid.uuid4().hex,'message':{'role':role,'content':[{'type':'text','text':text}]}})+'\n')
def tool(action,params,key):
 rid=hashlib.sha256((job['id']+'\0'+key).encode()).hexdigest()
 (root/'requests').mkdir(exist_ok=True)
 (root/'responses').mkdir(exist_ok=True)
 target=root/'requests'/(rid+'.json')
 value={'request_id':rid,'action':action,'params':params,'native_session_id':sid,'session_file':str(session)}
 target.write_text(json.dumps(value))
 output=root/'responses'/(rid+'.json')
 limit=time.time()+25
 while not output.exists():
  if time.time()>limit:raise RuntimeError('request timeout '+action)
  time.sleep(.03)
 reply=json.loads(output.read_text())
 if not reply['ok']:raise RuntimeError(reply['error'])
 return reply['result']
for line in sys.stdin:
 command=json.loads(line)
 name=command['type']
 if name=='get_state':
  emit({'type':'response','command':name,'success':True,'id':command.get('id'),'data':{'sessionId':sid,'sessionFile':str(session)}})
 elif name=='prompt':
  emit({'type':'response','command':name,'success':True,'id':command.get('id')})
  save('user',command['message'])
  if job['kind']=='coordinator':
   snapshot=tool('fm_status',{},'status')
   if job['claim']['role']=='user':
    if 'revise direction' in job['claim']['text']:
     tool('fm_revise',{'goal':'Changed synthetic goal','reason':'Human changed direction'},'revise')
    elif snapshot['feature']['status'] in ['ready','awaiting_direction']:
     tool('fm_begin_stage',{'stage_key':'planning','title':'Plan synthetic feature'},'begin')
     for index in range(7 if 'seven reviews' in job['claim']['text'] else 1):
      tool('fm_delegate',{'title':'Synthetic specialist '+str(index),'role':'reviewer' if 'seven reviews' in job['claim']['text'] else 'planner','prompt':job['claim']['text'],'workspace_mode':'read_only'},'delegate'+str(index))
    response='Planning is running. Follow it in the sidebar.'
   else:
    if snapshot['feature']['status']=='running' and all(a['status']=='completed' for a in snapshot['assignments']):
     tool('fm_complete_stage',{'summary':'Plan inspected and complete','recommendation':'Review the plan and choose implementation'},'complete')
    response='Awaiting your direction.'
  elif job['kind']=='worker':
   if 'slow' in job['prompt']:
    time.sleep(1)
   if 'nested review' in job['prompt'] and not job['claim'].get('metadata',{}).get('parent_assignment_id') and not job.get('parent_job_id'):
    for index in range(2): tool('fm_delegate',{'title':'Child reviewer '+str(index),'role':'reviewer','prompt':'Inspect the synthetic baseline and report evidence','workspace_mode':'read_only'},'child'+str(index))
    tool('fm_wait_for_children',{'summary':'Two specialists delegated. Inspect their findings and produce the final plan.'},'wait-children')
    response='Children delegated. Yielding until their reports.'
   elif 'missing outcome' in job['prompt']:
    response='I stopped without the required contract.'
   elif 'handoff sample' in job['prompt'] and not job.get('handoff_id'):
    tool('fm_handoff',{'summary':'Inspected requirements. Remaining: produce the final plan. Workspace unchanged.'},'handoff')
    response='Checkpoint ready.'
   else:
    parent=job['claim'].get('metadata',{}).get('parent_assignment_id')
    if parent and 'nested review' in job['prompt']:
     # This scenario verifies yielding/resuming, not the legitimate fast-child
     # rejection. Hold synthetic children until the parent's yield is recorded.
     limit=time.monotonic()+25
     while True:
      parents=[json.loads(p.read_text()) for p in root.parent.glob('*/job.json')]
      if any(p['claim'].get('id')==parent and p.get('waiting_children') for p in parents):break
      if time.monotonic()>limit:raise RuntimeError('parent did not record its yield')
      time.sleep(.03)
    if job.get('handoff_id'):
     tool('fm_acknowledge_handoff',{'summary':'Workspace verified; continue the remaining plan'},'ack')
    emit({'type':'tool_execution_start','toolName':'read','toolCallId':'read1','args':{'path':'README.md'}})
    tool('fm_outcome',{'verdict':'success','summary':'Requirements verified; plan written','documents':[{'title':'Synthetic plan','content':'# Plan\nImplement and verify the synthetic flow.'}]},'outcome')
    response='Plan ready.'
  else:
   if job.get('recovery_mode'): tool('fm_recovery_brief',{'summary':'Prior task inspected README. Verify current state before continuing.'},'brief')
   else: tool('fm_advice',{'decision':'continue','reason':'The observed activity is expected'},'advice')
   response='Continue.'
  save('assistant',response)
  emit({'type':'message_end','message':{'role':'assistant','content':[{'type':'text','text':response}]}})
  emit({'type':'agent_end'})
 elif name=='abort':
  emit({'type':'response','command':name,'success':True})
  emit({'type':'agent_end'})
 else:emit({'type':'response','command':name,'success':True})
'''


class FirstMateRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.cwd = self.root / 'project'
        self.cwd.mkdir()
        (self.cwd / 'README.md').write_text('Synthetic project\n')
        for args in (['init'], ['config', 'user.email', 'test@example.invalid'], ['config', 'user.name', 'Test'], ['add', '.'], ['commit', '-m', 'Synthetic baseline']):
            subprocess.run(['git', '-C', str(self.cwd), *args], capture_output=True, check=True)
        self.fake = self.root / 'pi'
        self.fake.write_text(FAKE_PI.replace('#!PYTHON', '#!' + sys.executable, 1))
        self.fake.chmod(0o700)
        self.store = FirstMateStore(self.root / 'store.sqlite3')
        self.environ = {'HERDR_HARNESS_AGENT_PI_BIN': str(self.fake), 'PATH': os.environ.get('PATH','')}
        self.runtime = FirstMateRuntime(self.store, environ=self.environ, runtime_root=self.root / 'runtime')
        self.managers = [self.runtime]
        self.children = []
        popen = subprocess.Popen

        def record_supervisor(*args, **kwargs):
            child = popen(*args, **kwargs)
            directory = kwargs.get('env', {}).get('HERDR_FIRST_MATE_JOB_DIR')
            if directory and Path(directory).is_relative_to(self.root):
                self.children.append((child, Path(directory)))
            return child

        self.spawn_patch = patch('herdr_harness.first_mate_runtime.subprocess.Popen', side_effect=record_supervisor)
        self.spawn_patch.start()
        self.addCleanup(self.spawn_patch.stop)

    def tearDown(self):
        for manager in self.managers:
            manager.stop()
        # A final reconciliation can launch a coordinator just before a test's
        # predicate succeeds. Track actual Popen handles (not just status files,
        # which may not exist yet) and wait for writers before removing storage.
        for child, directory in self.children:
            if child.poll() is None:
                _write_json(directory / 'controls' / 'test-stop.json', {'action': 'abort'})
        deadline = time.monotonic() + 1
        while any(child.poll() is None for child, _ in self.children) and time.monotonic() < deadline:
            time.sleep(.03)
        for child, directory in self.children:
            if child.poll() is None:
                state = _read_json(directory / 'status.json', {})
                if state.get('pid') == child.pid and state.get('pi_pid'):
                    try: os.kill(state['pi_pid'], 15)
                    except ProcessLookupError: pass
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.terminate()
                    child.wait(timeout=2)
        self.store.close()
        self.temp.cleanup()

    def feature(self, goal='Plan the synthetic feature'):
        return self.store.create_feature({'title':'Synthetic feature','goal':goal,'cwd':str(self.cwd),'request_id':'create'})

    def until(self, predicate, timeout=12):
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.runtime.reconcile()
            if predicate(): return
            time.sleep(.08)
        errors = {str(p): p.read_text() for p in (self.root / 'runtime').rglob('*error*.json')}
        statuses = {str(p): p.read_text() for p in (self.root / 'runtime').rglob('status.json')}
        self.fail(f'Condition not reached. Errors: {errors}; status: {statuses}')

    def test_selected_model_and_effort_reach_pi_without_overriding_workers(self):
        feature = self.feature()
        self.store.set_model_settings(feature['id'], {'model': 'synthetic/reasoner', 'thinking': 'high', 'expected_settings_revision': 0, 'request_id': 'select-model'})
        self.until(lambda: self.store.get_feature(feature['id'])['status']=='awaiting_direction')
        for job in self.runtime._jobs():
            argv = json.loads((self.runtime._job_dir(job) / 'argv.json').read_text())
            if job['kind'] == 'coordinator':
                self.assertEqual(argv[argv.index('--model') + 1], 'synthetic/reasoner')
                self.assertEqual(argv[argv.index('--thinking') + 1], 'high')
            else:
                self.assertNotIn('--model', argv)
                self.assertNotIn('--thinking', argv)

    def test_coordinator_uses_replacement_charter_and_exact_tool_allowlist(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='coordinator', prompt='Hello', claim=claim)
        job['charter'] = 'stale persisted coordinator charter'
        command = _pi_command(job)
        self.assertEqual(command[command.index('--system-prompt') + 1], COORDINATOR_PROMPT)
        self.assertNotIn('--append-system-prompt', command)
        tools = command[command.index('--tools') + 1].split(',')
        self.assertEqual(tools, list(COORDINATOR_TOOLS))
        self.assertNotIn('fm_read_document', tools)
        self.assertNotIn('fm_read_session', tools)

    def test_worker_launch_keeps_evidence_tools_and_worker_charter(self):
        job = {'kind':'worker','pi_bin':'pi','session_file':'/tmp/synthetic-session.jsonl',
               'claim':{'title':'Synthetic worker'},'extension':'/tmp/first-mate.ts',
               'workspace_mode':'read_only','charter':'stale persisted worker charter'}
        command = _pi_command(job)
        self.assertEqual(command[command.index('--append-system-prompt') + 1], WORKER_PROMPT)
        self.assertNotIn('--system-prompt', command)
        tools = command[command.index('--tools') + 1].split(',')
        self.assertIn('fm_read_document', tools)
        self.assertIn('fm_read_session', tools)
        self.assertIn('fm_delegate', tools)

    def test_coordinator_input_is_current_scope_and_reference_oriented(self):
        snapshot = {
            'feature': {'id':'feature','title':'Synthetic','goal':'Ship it','status':'running',
                        'revision':3,'current_visit_id':'visit-current','cwd':'/private/project',
                        'session_file':'/private/session'},
            'visits': [
                {'id':'visit-old','stage_key':'plan','title':'Plan','status':'completed','revision':2,
                 'summary':'Old detailed result'},
                {'id':'visit-current','stage_key':'review','title':'Review','status':'running','revision':3,
                 'summary':'','recommendation':''},
            ],
            'memberships': [
                {'visit_id':'visit-old','assignment_id':'old','revision':2,'authorization_message_id':'human-old'},
                {'visit_id':'visit-current','assignment_id':'current','revision':3,
                 'authorization_message_id':'human-current','carried_from_visit_id':None},
            ],
            'assignments': [
                {'id':'old','visit_id':'visit-old','title':'Old','role':'planner','status':'completed',
                 'summary':'Historical details','prompt':'old secret prompt','metadata':{'worktree_path':'/private/old'}},
                {'id':'current','visit_id':'visit-current','title':'Current','role':'reviewer','status':'paused',
                 'verdict':'blocked','generation':2,'input_revision':3,'summary':'Awaiting a choice',
                 'prompt':'current secret prompt','native_session_id':'native-current',
                 'metadata':{'worktree_path':'/private/current','human_gate':{'status':'pending','reason':'Choose A or B'}}},
            ],
            'documents': [
                {'id':'doc-old','visit_id':'visit-old','assignment_id':'old','title':'Old plan'},
                {'id':'doc-current','visit_id':'visit-current','assignment_id':'current','title':'Review evidence',
                 'content_hash':'abc','generation':2,'input_revision':3},
            ],
            'handoffs': [],
        }
        claim = {'id':'update','role':'system','text':'Current worker needs a choice.',
                 'metadata':{'assignment_id':'current','human_gate':{'status':'pending'}}}
        state = _coordinator_state(snapshot, claim)
        self.assertEqual([a['id'] for a in state['assignments']], ['current'])
        self.assertEqual(state['assignments'][0]['operational']['human_gate']['reason'], 'Choose A or B')
        self.assertEqual([d['id'] for d in state['document_references']], ['doc-current'])
        rendered = self.runtime._coordinator_input(snapshot, claim)
        self.assertNotIn('secret prompt', rendered)
        self.assertNotIn('/private/current', rendered)
        self.assertIn('doc-current', rendered)

    def test_coordinator_cannot_open_detailed_evidence_directly(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = {'feature_id':feature['id'],'kind':'coordinator','claim':claim}
        with self.assertRaisesRegex(ValueError, 'tracked worker'):
            self.runtime._tool(job, 'fm_read_document', {'document_id':'synthetic'}, 'read-document')
        with self.assertRaisesRegex(ValueError, 'tracked worker'):
            self.runtime._tool(job, 'fm_read_session', {'native_session_id':'synthetic'}, 'read-session')

    def test_rotation_retains_coordinator_question_with_terse_human_answer(self):
        feature = self.feature()
        first = self.store.claim_message(feature['id'], self.runtime.owner)
        first_job = self.runtime._new_job(feature, kind='coordinator', prompt='Initial direction', claim=first)
        self.runtime._bind(first_job, 'synthetic-coordinator', first_job['session_file'])
        self.store.finish_message(first['id'], self.runtime.owner, 'The release is ready. Should I publish it?')
        self.store.append_human_message(feature['id'], 'Yes, go ahead.', 'approve')
        second = self.store.claim_message(feature['id'], self.runtime.owner)
        second_job = self.runtime._new_job(self.store.get_feature(feature['id']), kind='coordinator',
                                           prompt='Approval', claim=second)
        self.runtime._bind(second_job, 'synthetic-coordinator', second_job['session_file'])
        telemetry = self.runtime._job_dir(second_job) / 'telemetry.jsonl'
        telemetry.write_text(json.dumps({'type':'context_usage',
                                         'payload':{'tokens':160000,'contextWindow':200000}})+'\n')
        self.runtime._finish(second_job, {'ended':True,'response':'Publishing is authorized.'})
        checkpoint = _read_json(self.runtime.root / 'checkpoints' / (feature['id']+'.json'))
        recent = [(message['role'], message['text']) for message in checkpoint['recent_conversation']]
        self.assertIn(('assistant', 'The release is ready. Should I publish it?'), recent)
        self.assertIn(('user', 'Yes, go ahead.'), recent)

    def test_real_process_plans_reports_and_parks_at_human_gate(self):
        feature = self.feature()
        self.until(lambda: self.store.get_feature(feature['id'])['status']=='awaiting_direction')
        snapshot = self.store.snapshot(feature['id'])
        self.assertEqual(len(snapshot['visits']), 1)
        self.assertEqual(snapshot['assignments'][0]['verdict'], 'success')
        self.assertEqual(len(snapshot['documents']), 1)
        native = snapshot['assignments'][0]['native_session_id']
        self.assertIn('Plan ready.', str(self.runtime.session(native)['messages']))
        self.assertTrue(snapshot['feature']['native_session_id'])
        for _ in range(5): self.runtime.reconcile()
        self.assertEqual(len(self.store.snapshot(feature['id'])['visits']), 1)

    def test_nested_workers_yield_and_resume_exact_parent_session_without_polling(self):
        feature = self.feature('Plan nested review of the synthetic feature')
        self.until(lambda: self.store.get_feature(feature['id'])['status']=='awaiting_direction', timeout=20)
        assignments = self.store.snapshot(feature['id'])['assignments']
        self.assertEqual(len(assignments), 3)
        parent = next(a for a in assignments if not a['metadata'].get('parent_assignment_id'))
        children = [a for a in assignments if a['metadata'].get('parent_assignment_id') == parent['id']]
        self.assertEqual(len(children), 2)
        self.assertEqual(parent['generation'], 1)
        self.assertEqual(len({a['native_session_id'] for a in assignments}), 3)
        history = self.runtime.session(parent['native_session_id'])['messages']
        self.assertIn('Children delegated', str(history))
        self.assertIn('Plan ready.', str(history))
        self.assertTrue(all(a['status']=='completed' for a in assignments))
        snapshot = self.store.snapshot(feature['id'])
        outcome_messages = [m for m in snapshot['messages'] if m['role']=='system' and m['metadata'].get('assignment_id')]
        self.assertEqual([m['metadata']['assignment_id'] for m in outcome_messages], [parent['id']])
        self.assertEqual({d['assignment_id'] for d in snapshot['documents']}, {a['id'] for a in assignments})
        outcome_events = [e for e in snapshot['events'] if e['type']=='assignment.outcome']
        self.assertEqual({e['payload']['assignment_id'] for e in outcome_events}, {a['id'] for a in assignments})

    def test_seven_independent_reviewers_retain_exact_documents_and_sessions(self):
        feature = self.feature('Plan seven reviews of the synthetic baseline')
        self.until(lambda: self.store.get_feature(feature['id'])['status']=='awaiting_direction', timeout=20)
        snapshot = self.store.snapshot(feature['id'])
        self.assertEqual(len(snapshot['assignments']), 7)
        sessions = {a['native_session_id'] for a in snapshot['assignments']}
        self.assertEqual(len(sessions), 7)
        self.assertEqual({d['native_session_id'] for d in snapshot['documents']}, sessions)
        self.assertEqual(len({a['metadata']['expected_code_revision'] for a in snapshot['assignments']}), 1)
        self.assertTrue(all(a['verdict']=='success' for a in snapshot['assignments']))

    def test_manager_restart_reattaches_same_dispatch_and_conversation(self):
        feature = self.feature('Plan slow synthetic task')
        self.until(lambda: any(a['status']=='running' for a in self.store.snapshot(feature['id'])['assignments']))
        original = self.store.snapshot(feature['id'])['assignments'][0]
        self.runtime.stop()
        replacement = FirstMateRuntime(self.store, environ=self.environ, runtime_root=self.root / 'runtime')
        self.managers.append(replacement)
        self.runtime = replacement
        self.until(lambda: self.store.get_feature(feature['id'])['status']=='awaiting_direction')
        final = self.store.snapshot(feature['id'])['assignments'][0]
        self.assertEqual(final['generation'], 1)
        self.assertEqual(final['dispatch_id'], original['dispatch_id'])
        self.assertEqual(final['native_session_id'], original['native_session_id'])

    def test_fresh_handoff_acknowledges_successor_and_retains_both_sessions(self):
        feature = self.feature('Plan handoff sample')
        self.until(lambda: self.store.get_feature(feature['id'])['status']=='awaiting_direction')
        assignment = self.store.snapshot(feature['id'])['assignments'][0]
        attempts = self.store.list_attempts(assignment['id'])
        self.assertEqual([a['status'] for a in attempts], ['handed_off','completed'])
        self.assertEqual(assignment['generation'], 2)
        self.assertNotEqual(attempts[0]['native_session_id'], attempts[1]['native_session_id'])
        self.assertEqual(self.store.get_session(attempts[0]['native_session_id'])['status'], 'retained')
        self.assertTrue(self.runtime.session(attempts[0]['native_session_id'])['messages'])
        self.assertTrue(any(e['type']=='handoff.acknowledged' for e in self.store.get_events(feature['id'])['events']))

    def test_missing_outcome_never_success_and_recovery_is_bounded(self):
        feature = self.feature('Plan missing outcome')
        self.until(lambda: self.store.get_feature(feature['id'])['status']=='blocked', timeout=18)
        assignment = self.store.snapshot(feature['id'])['assignments'][0]
        self.assertEqual(assignment['status'], 'blocked')
        self.assertEqual(assignment['generation'], 3)
        self.assertEqual(assignment['recovery_count'], 3)
        self.assertEqual(len(self.store.snapshot(feature['id'])['documents']), 0)

    def test_completion_between_status_read_and_lock_check_is_not_unknown(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='coordinator', prompt='Synthetic completion', claim=claim)
        directory = self.runtime._job_dir(job)
        _write_json(directory / 'started.json', {'pid': 123})
        final_state = {'ended': True, 'response': 'Completed before the lock check'}
        for publish_receipt in (True, False):
            with self.subTest(publish_receipt=publish_receipt):
                _write_json(directory / 'status.json', {'ended': False})

                def unlock(_path):
                    if publish_receipt:
                        _write_json(directory / 'status.json', final_state)
                    return False

                with patch('herdr_harness.first_mate_runtime._locked', side_effect=unlock), \
                     patch.object(self.runtime, '_observe'), patch.object(self.runtime, '_requests'), \
                     patch.object(self.runtime, '_actions'), patch.object(self.runtime, '_watch'), \
                     patch.object(self.runtime, 'capabilities', return_value={'available': False}), \
                     patch.object(self.runtime, '_finish') as finish, patch.object(self.runtime, '_unknown') as unknown:
                    self.runtime.reconcile()
                if publish_receipt:
                    finish.assert_called_once_with(job, final_state)
                    unknown.assert_not_called()
                else:
                    finish.assert_not_called()
                    unknown.assert_called_once_with(job)

    def test_scoped_worker_cannot_begin_stage_or_read_another_feature(self):
        feature = self.feature()
        other = self.store.create_feature({'title':'Other','goal':'Other goal','cwd':str(self.cwd),'request_id':'other'})
        job = {'feature_id':feature['id'],'kind':'worker','claim':{}}
        with self.assertRaises(ValueError): self.runtime._tool(job,'fm_begin_stage',{'title':'Bad','stage_key':'bad'},'bad')
        self.assertNotEqual(feature['id'], other['id'])

    def test_read_only_parent_cannot_escalate_child_to_writable_worktree(self):
        feature = self.feature()
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        visit = self.store.start_visit(feature['id'],'planning','Planning','stage',1,human['id'])
        parent = self.store.create_assignment(visit['id'],{'title':'Lead','role':'planner','prompt':'Read only','request_id':'parent','input_revision':1})
        claim = self.store.claim_assignment(parent['id'],self.runtime.owner)
        self.store.bind_session(parent['id'],claim['generation'],self.runtime.owner,'parent-native',str(self.root/'parent.jsonl'))
        job = {'feature_id':feature['id'],'kind':'worker','claim':claim,'native_session_id':'parent-native','workspace_mode':'read_only'}
        with self.assertRaises(FirstMateError):
            self.runtime._tool(job,'fm_delegate',{'title':'Writer','role':'coder','prompt':'Write code','workspace_mode':'isolated'},'child')
        self.assertEqual(len(self.store.snapshot(feature['id'])['assignments']),1)
        self.assertFalse((self.runtime.root/'worktrees').exists())

    def test_duplicate_request_receipt_does_not_repeat_delegation(self):
        feature = self.feature()
        message = self.store.claim_message(feature['id'], 'owner')
        job = {'feature_id':feature['id'],'kind':'coordinator','claim':message}
        self.runtime._tool(job,'fm_begin_stage',{'title':'Plan','stage_key':'planning'},'stage')
        params = {'title':'Planner','role':'planner','prompt':'Plan','workspace_mode':'read_only'}
        first = self.runtime._tool(job,'fm_delegate',params,'delegate')
        second = self.runtime._tool(job,'fm_delegate',params,'delegate')
        self.assertEqual(first['id'], second['id'])
        self.assertEqual(len(self.store.snapshot(feature['id'])['assignments']), 1)

    def test_system_completion_cannot_authorize_another_stage(self):
        feature = self.feature()
        job = {'feature_id':feature['id'],'kind':'coordinator','claim':{'role':'system','id':'not-human'}}
        with self.assertRaises(ValueError): self.runtime._tool(job,'fm_begin_stage',{'title':'Bad','stage_key':'bad'},'bad')

    def test_isolated_workspace_keeps_feature_checkout_untouched(self):
        feature = self.feature()
        metadata = self.runtime._workspace(feature, {'workspace_mode':'isolated'}, 'new-worktree')
        self.assertNotEqual(metadata['worktree_path'], str(self.cwd))
        self.assertTrue(metadata['branch'].startswith('codex/first-mate-'))
        self.assertEqual(self.runtime._git(str(self.cwd),'status','--porcelain'), '')
        again = self.runtime._workspace(feature, {'workspace_mode':'isolated'}, 'new-worktree')
        self.assertEqual(metadata, again)

    def test_repeated_status_reads_do_not_embed_prior_results_or_grow_recursively(self):
        feature = self.feature()
        job = {'feature_id':feature['id'],'kind':'coordinator','claim':{'role':'system'}}
        lengths = []
        for index in range(40):
            status = self.runtime._tool(job, 'fm_status', {}, 'status-'+str(index))
            self.assertNotIn('events', status)
            self.assertNotIn('messages', status)
            event = _ledger_event({'type':'tool_execution_end','toolName':'fm_status','result':status})
            self.assertNotIn('result', event)
            self.assertIn('result_reference', event)
            self.store.append_event(feature['id'],'pi.tool_execution_end','Status read',{'event':event},request_id='read-'+str(index))
            lengths.append(len(json.dumps(status)))
        self.assertLess(max(lengths), 15000)
        self.assertLess(abs(lengths[-1]-lengths[-10]), 200)

    def test_native_history_pages_without_injecting_unbounded_transcripts(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = self.runtime._new_job(feature,kind='coordinator',prompt='Hello',claim=claim)
        job['native_session_id'] = 'synthetic-native-id'
        self.runtime._save_job(job)
        rows = [{'type':'session','id':job['native_session_id']}]
        rows += [{'type':'message','message':{'role':'user','content':[{'type':'text','text':str(index)}]}} for index in range(205)]
        Path(job['session_file']).write_text(''.join(json.dumps(row)+'\n' for row in rows))
        latest = self.runtime.session(job['native_session_id'])
        self.assertEqual(latest['total_messages'], 205)
        self.assertEqual(len(latest['messages']), 100)
        self.assertEqual(latest['next_before'], 105)
        older = self.runtime.session(job['native_session_id'], before=latest['next_before'])
        self.assertEqual(older['messages'][0]['text'], '5')
        self.assertEqual(older['next_before'], 5)

    def test_record_reader_preserves_partial_lines(self):
        path = self.root / 'stream.jsonl'
        path.write_bytes(b'{"type":"one"}\n{"type":')
        rows, offset = _records(path)
        self.assertEqual(rows,[{'type':'one'}])
        with path.open('ab') as output: output.write(b'"two"}\n')
        self.assertEqual(_records(path,offset)[0],[{'type':'two'}])

    def test_child_environment_does_not_receive_companion_control_token(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = self.runtime._new_job(feature,kind='coordinator',prompt='Hello',claim=claim)
        self.runtime.environ['HERDR_HARNESS_API_TOKEN']='synthetic-control-token'
        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(job)
        child = spawn.call_args.kwargs['env']
        self.assertNotIn('HERDR_HARNESS_API_TOKEN', child)
        self.assertEqual(child['HERDR_FIRST_MATE_ROLE'],'coordinator')

if __name__ == '__main__': unittest.main()
