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

from herdr_harness.first_mate_runtime import (COORDINATOR_PROMPT, WORKER_PROMPT,
    FirstMateRuntime, _architect_startup_error, _coordinator_state, _ledger_event, _locked,
    _pi_command, _read_json, _records, _write_json, run_detached)
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
  state={'sessionId':sid,'sessionFile':str(session)}
  if job.get('model') and 'missing initial model' not in job['prompt']:
   provider,model=job['model'].split('/',1)
   if 'runtime mismatch' in job['prompt']:model='mismatched-architect'
   state['model']={'provider':provider,'id':model}
  if job.get('thinking') and 'missing initial thinking' not in job['prompt']:
   state['thinkingLevel']=job['thinking']
  if 'initial state timeout' in job['prompt']:
   continue
  if 'unrelated initial state' in job['prompt']:
   emit({'type':'response','command':name,'success':True,'id':'unrelated-request','data':state})
   continue
  if 'initial state rejected' in job['prompt']:
   emit({'type':'response','command':name,'success':False,'id':command.get('id'),'error':'synthetic get_state rejection','data':state})
  elif 'malformed initial state' in job['prompt']:
   emit({'type':'response','command':name,'success':True,'id':command.get('id'),'data':['malformed']})
  else:
   emit({'type':'response','command':name,'success':True,'id':command.get('id'),'data':state})
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
      delegation={'title':'Synthetic specialist '+str(index),'role':'reviewer' if 'seven reviews' in job['claim']['text'] else 'planner','prompt':job['claim']['text'],'workspace_mode':'read_only'}
      if 'architecture review' in job['claim']['text']:delegation['model_profile']='architect'
      tool('fm_delegate',delegation,'delegate'+str(index))
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

    def test_archived_nonterminal_feature_remains_in_internal_reconciliation(self):
        feature = self.feature()
        self.store.set_archived(feature['id'], True, {'request_id': 'archive-running'})
        self.assertEqual(self.runtime.list_features(), [])
        self.assertEqual([item['id'] for item in self.runtime.list_features('all')], [feature['id']])
        launched = []
        with patch.object(self.runtime, '_launch', side_effect=launched.append), \
             patch.object(self.runtime, 'capabilities', return_value={'available': True}):
            self.runtime.reconcile()
        self.assertEqual([job['feature_id'] for job in launched], [feature['id']])
        self.assertEqual(launched[0]['kind'], 'coordinator')

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

    def test_coordinator_uses_replacement_charter_with_normal_pi_resources(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='coordinator', prompt='Hello', claim=claim)
        job['charter'] = 'stale persisted coordinator charter'
        command = _pi_command(job)
        self.assertEqual(command[command.index('--system-prompt') + 1], COORDINATOR_PROMPT)
        self.assertNotIn('--append-system-prompt', command)
        self.assertIn('one to three sentences', COORDINATOR_PROMPT)
        self.assertIn('adapt it to fm_delegate', COORDINATOR_PROMPT)
        self.assertIn('second opinion on an', COORDINATOR_PROMPT)
        self.assertIn('Give me an', COORDINATOR_PROMPT)
        self.assertIn('architect review', COORDINATOR_PROMPT)
        self.assertIn('routine code review', COORDINATOR_PROMPT)
        self.assertIn('model name or worker title alone', COORDINATOR_PROMPT)
        self.assertIn('NEVER re-route', COORDINATOR_PROMPT)
        self.assertIn('model_selection', COORDINATOR_PROMPT)
        for flag in ('--tools', '--exclude-tools', '--no-tools', '--no-builtin-tools',
                     '--no-extensions', '--no-skills', '--no-context-files',
                     '--no-prompt-templates'):
            self.assertNotIn(flag, command)
        self.assertEqual(command[command.index('--extension') + 1], job['extension'])

    def test_worker_launch_keeps_evidence_tools_and_worker_charter(self):
        job = {'kind':'worker','pi_bin':'pi','session_file':'/tmp/synthetic-session.jsonl',
               'claim':{'title':'Synthetic worker'},'extension':'/tmp/first-mate.ts',
               'workspace_mode':'read_only','charter':'stale persisted worker charter'}
        command = _pi_command(job)
        self.assertEqual(command[command.index('--append-system-prompt') + 1], WORKER_PROMPT)
        self.assertNotIn('--system-prompt', command)
        self.assertIn('second opinion on an', WORKER_PROMPT)
        self.assertIn('architect review', WORKER_PROMPT)
        self.assertIn('routine code review', WORKER_PROMPT)
        self.assertIn('NEVER re-route', WORKER_PROMPT)
        for flag in ('--tools', '--exclude-tools', '--no-tools', '--no-builtin-tools',
                     '--no-extensions', '--no-skills', '--no-context-files',
                     '--no-prompt-templates'):
            self.assertNotIn(flag, command)

    def test_every_role_and_workspace_mode_uses_normal_pi_tool_and_resource_profile(self):
        base = {'pi_bin':'pi','session_file':'/tmp/synthetic-session.jsonl',
                'claim':{'title':'Synthetic assignment'},'extension':'/tmp/first-mate.ts'}
        jobs = [
            {**base, 'kind':'coordinator'},
            {**base, 'kind':'worker', 'workspace_mode':'read_only'},
            {**base, 'kind':'worker', 'workspace_mode':'isolated'},
            {**base, 'kind':'advisor'},
        ]
        for job in jobs:
            with self.subTest(kind=job['kind'], workspace_mode=job.get('workspace_mode')):
                command = _pi_command(job)
                for flag in ('--tools', '--exclude-tools', '--no-tools', '--no-builtin-tools',
                             '--no-extensions', '--no-skills', '--no-context-files',
                             '--no-prompt-templates'):
                    self.assertNotIn(flag, command)

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

    def test_coordinator_evidence_readers_are_paginated_and_feature_scoped(self):
        def evidence(feature, suffix):
            human = self.store.claim_message(feature['id'], 'owner-' + suffix)
            visit = self.store.start_visit(feature['id'], 'planning', 'Planning', 'stage-' + suffix, 1, human['id'])
            assignment = self.store.create_assignment(visit['id'], {
                'title':'Evidence '+suffix, 'role':'reviewer', 'prompt':'Inspect',
                'request_id':'assignment-'+suffix, 'input_revision':1})
            claim = self.store.claim_assignment(assignment['id'], 'worker-' + suffix)
            worker = self.runtime._new_job(feature, kind='worker', prompt='Inspect', claim=claim)
            native = 'native-' + suffix
            self.runtime._bind(worker, native, worker['session_file'])
            assignment = self.store.get_assignment(assignment['id'])
            document = self.store._document(assignment, 'Long evidence', suffix * 1300)
            rows = [{'type':'session','id':native}]
            rows.append({'type':'message','message':{'role':'assistant','content':[{'type':'text','text':suffix * 1300}]}})
            Path(worker['session_file']).write_text(''.join(json.dumps(row)+'\n' for row in rows))
            return human, document, native

        feature = self.feature()
        claim, document, native = evidence(feature, 'a')
        other = self.store.create_feature({'title':'Other','goal':'Other evidence','cwd':str(self.cwd),'request_id':'other-evidence'})
        _, other_document, other_native = evidence(other, 'b')
        job = {'feature_id':feature['id'],'kind':'coordinator','claim':claim}

        page = self.runtime._tool(job, 'fm_read_document', {'document_id':document['id'], 'length':1000}, 'read-document')
        self.assertEqual(len(page['content']), 1000)
        self.assertEqual(page['next_offset'], 1000)
        session = self.runtime._tool(job, 'fm_read_session', {
            'native_session_id':native, 'message_index':0, 'text_length':1000}, 'read-session')
        self.assertEqual(len(session['messages'][0]['text']), 1000)
        self.assertEqual(session['messages'][0]['next_text_offset'], 1000)
        with self.assertRaisesRegex(FirstMateError, 'another feature'):
            self.runtime._tool(job, 'fm_read_document', {'document_id':other_document['id']}, 'cross-document')
        with self.assertRaisesRegex(FirstMateError, 'another feature'):
            self.runtime._tool(job, 'fm_read_session', {'native_session_id':other_native}, 'cross-session')

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
        configured_path = '/synthetic/cli/bin:/usr/bin:/bin'
        self.runtime.environ['PATH'] = configured_path
        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(job)
        child = spawn.call_args.kwargs['env']
        self.assertNotIn('HERDR_HARNESS_API_TOKEN', child)
        self.assertNotIn('HERDR_FIRST_MATE_ROLE', child)
        self.assertEqual(child['HERDR_FIRST_MATE_MANAGED_ROLE'],'coordinator')
        self.assertEqual(
            Path(spawn.call_args.kwargs['cwd']).resolve(),
            Path(feature['cwd']).resolve(),
        )
        self.assertEqual(child['PATH'].split(os.pathsep)[0], str(self.fake.parent))
        self.assertTrue(child['PATH'].endswith(configured_path))

    def test_unstarted_persisted_job_refreshes_extension_before_launch(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='coordinator', prompt='Hello', claim=claim)
        current = self.root / 'current-first-mate.ts'
        current.write_text('// synthetic current extension\n')
        self.runtime.extension = current
        job['extension'] = '/private/old-package/extensions/first-mate.ts'
        self.runtime._save_job(job)

        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(job)
        self.assertTrue(spawn.called)
        persisted = _read_json(self.runtime._job_dir(job) / 'job.json')
        self.assertEqual(persisted['extension'], str(current))
        self.assertEqual(persisted['previous_extension'], '/private/old-package/extensions/first-mate.ts')
        self.assertIn('extension_selected_at', persisted)

    def test_unstarted_policy_refreshes_but_started_policy_stays_frozen(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        self.runtime.environ['HERDR_FIRST_MATE_MODEL'] = 'synthetic/before'
        job = self.runtime._new_job(feature, kind='coordinator', prompt='Hello', claim=claim)
        self.runtime.environ['HERDR_FIRST_MATE_MODEL'] = 'synthetic/after'
        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(job)
        persisted = _read_json(self.runtime._job_dir(job) / 'job.json')
        self.assertEqual(persisted['model_selection']['requested_model'], 'synthetic/after')
        self.assertEqual(persisted['previous_model_selection']['requested_model'], 'synthetic/before')

        _write_json(self.runtime._job_dir(job) / 'started.json', {'pid': 123})
        self.runtime.environ['HERDR_FIRST_MATE_MODEL'] = 'synthetic/later'
        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(persisted)
        spawn.assert_not_called()
        self.assertEqual(_read_json(self.runtime._job_dir(job) / 'job.json')['model'], 'synthetic/after')

    def test_explicit_and_stage_default_profiles_persist_for_nested_routing(self):
        feature = self.feature()
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        self.store.start_visit(feature['id'], 'planning', 'Planning', 'start-profile', 1, human['id'])
        coordinator = {'feature_id': feature['id'], 'kind': 'coordinator', 'claim': human}
        planned = self.runtime._tool(coordinator, 'fm_delegate', {
            'title': 'Plan', 'role': 'planner', 'prompt': 'Plan', 'workspace_mode': 'read_only'}, 'plan-profile')
        explicit = self.runtime._tool(coordinator, 'fm_delegate', {
            'title': 'Execute', 'role': 'implementer', 'prompt': 'Execute',
            'model_profile': 'execution', 'workspace_mode': 'read_only'}, 'execution-profile')
        self.assertEqual(planned['metadata']['model_profile'], 'planning')
        self.assertEqual(explicit['metadata']['model_profile'], 'execution')
        with self.assertRaisesRegex(ValueError, 'planning, execution, or architect'):
            self.runtime._tool(coordinator, 'fm_delegate', {
                'title': 'Bad', 'role': 'reviewer', 'prompt': 'Inspect',
                'model_profile': {'invalid': True}, 'workspace_mode': 'read_only'}, 'bad-profile')

    def test_architect_delegation_requires_pin_before_workspace_or_assignment(self):
        feature = self.feature()
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        self.store.start_visit(feature['id'], 'planning', 'Planning', 'start-architect-missing', 1, human['id'])
        coordinator = {'feature_id': feature['id'], 'kind': 'coordinator', 'claim': human}
        self.runtime.environ['HERDR_FIRST_MATE_MODEL'] = 'synthetic/legacy-must-not-fallback'
        with self.assertRaisesRegex(ValueError, 'architect_model'):
            self.runtime._tool(coordinator, 'fm_delegate', {
                'title': 'Architecture review', 'role': 'architect', 'prompt': 'Review the design',
                'model': 'synthetic/assignment-must-not-fallback',
                'model_profile': 'architect', 'workspace_mode': 'read_only'}, 'architect-missing')
        self.assertEqual(self.store.snapshot(feature['id'])['assignments'], [])
        self.assertFalse((self.runtime.root / 'workspace-plans').exists())

    def test_architect_profile_and_requested_selection_persist_for_coordinator_and_nested_delegation(self):
        feature = self.feature()
        self.runtime.environ.update({
            'HERDR_FIRST_MATE_ARCHITECT_MODEL': 'synthetic/architect',
            'HERDR_FIRST_MATE_ARCHITECT_THINKING': 'xhigh',
        })
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        self.store.start_visit(feature['id'], 'planning', 'Planning', 'start-architect', 1, human['id'])
        coordinator = {'feature_id': feature['id'], 'kind': 'coordinator', 'claim': human}
        parent = self.runtime._tool(coordinator, 'fm_delegate', {
            'title': 'Lead', 'role': 'planner', 'prompt': 'Coordinate the review',
            'workspace_mode': 'read_only'}, 'architect-parent')
        parent_claim = self.store.claim_assignment(parent['id'], self.runtime.owner)
        parent_job = self.runtime._new_job(feature, kind='worker', prompt='Coordinate', claim=parent_claim)
        self.runtime._bind(parent_job, 'native-architect-parent', parent_job['session_file'])
        child = self.runtime._tool(parent_job, 'fm_delegate', {
            'title': 'Independent architecture audit', 'role': 'architect',
            'prompt': 'Audit the implementation architecture', 'model_profile': 'architect',
            'model': 'synthetic/ignored-assignment', 'workspace_mode': 'read_only'}, 'architect-child')
        self.assertEqual(child['metadata']['model_profile'], 'architect')
        self.assertEqual(child['metadata']['parent_assignment_id'], parent['id'])
        self.assertEqual(child['model_selection'], {
            'profile': 'architect', 'requested_model': 'synthetic/architect',
            'requested_thinking': 'xhigh', 'actual_model': None,
            'actual_thinking': None, 'source': 'host_policy'})
        status = self.runtime._tool(coordinator, 'fm_status', {}, 'architect-status')
        projected = next(item for item in status['assignments'] if item['id'] == child['id'])
        self.assertEqual(projected['operational']['model_profile'], 'architect')
        self.assertEqual(projected['model_selection']['requested_model'], 'synthetic/architect')
        self.assertIsNone(projected['model_selection']['actual_model'])

    def test_architect_retry_continuation_and_handoff_dispatches_resolve_current_pin(self):
        feature = self.feature()
        claim = {'id': 'synthetic-architect-assignment', 'generation': 1,
                 'dispatch_id': 'architect-first', 'title': 'Architect',
                 'metadata': {'model_profile': 'architect', 'workspace_mode': 'read_only'}}
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect-a'
        first = self.runtime._new_job(feature, kind='worker', prompt='Audit', claim=claim)
        self.assertEqual(first['model'], 'synthetic/architect-a')
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect-b'
        dispatches = [
            self.runtime._new_job(feature, kind='worker', prompt='Retry',
                                  claim={**claim, 'generation': 2, 'dispatch_id': 'architect-retry'}),
            self.runtime._new_job(feature, kind='worker', prompt='Continue children',
                                  claim={**claim, 'dispatch_id': 'children:architect'}, parent_job=first),
            self.runtime._new_job(feature, kind='worker', prompt='Continue handoff',
                                  claim={**claim, 'generation': 2, 'dispatch_id': 'handoff:architect'},
                                  parent_job=first, handoff_id='synthetic-handoff'),
        ]
        self.assertTrue(all(job['model'] == 'synthetic/architect-b' for job in dispatches))
        self.assertTrue(all(job['model_selection']['profile'] == 'architect' for job in dispatches))

    def test_unstarted_architect_refresh_blocks_on_removed_pin_but_started_dispatch_is_immutable(self):
        feature = self.feature()
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect'
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        self.store.start_visit(feature['id'], 'planning', 'Planning', 'start-refresh', 1, human['id'])
        coordinator = {'feature_id': feature['id'], 'kind': 'coordinator', 'claim': human}
        assignments = [self.runtime._tool(coordinator, 'fm_delegate', {
            'title': 'Architect ' + str(index), 'role': 'architect', 'prompt': 'Audit',
            'model_profile': 'architect', 'workspace_mode': 'read_only'}, 'architect-refresh-' + str(index))
            for index in range(2)]
        claims = [self.store.claim_assignment(assignment['id'], self.runtime.owner)
                  for assignment in assignments]
        jobs = [self.runtime._new_job(feature, kind='worker', prompt='Audit', claim=claim)
                for claim in claims]
        _write_json(self.runtime._job_dir(jobs[1]) / 'started.json', {'pid': 123})
        self.runtime.environ.pop('HERDR_FIRST_MATE_ARCHITECT_MODEL')

        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(jobs[0])
            self.runtime._launch(jobs[1])
        spawn.assert_not_called()
        blocked = self.store.get_assignment(assignments[0]['id'])
        immutable = self.store.get_assignment(assignments[1]['id'])
        self.assertEqual(blocked['status'], 'blocked')
        self.assertIn('no fallback is allowed', blocked['summary'])
        self.assertTrue((self.runtime._job_dir(jobs[0]) / 'finalized.json').exists())
        visible = next(item for item in self.runtime.snapshot(feature['id'])['assignments']
                       if item['id'] == assignments[0]['id'])
        self.assertEqual(visible['model_selection']['requested_model'], 'synthetic/architect')
        self.assertIsNone(visible['model_selection']['actual_model'])
        self.assertEqual(immutable['status'], 'dispatching')
        self.assertEqual(_read_json(self.runtime._job_dir(jobs[1]) / 'job.json')['model'],
                         'synthetic/architect')

    def test_architect_initial_state_mismatch_blocks_before_task_prompt_and_retains_evidence(self):
        feature = self.feature()
        self.runtime.environ.update({
            'HERDR_FIRST_MATE_ARCHITECT_MODEL': 'synthetic/architect',
            'HERDR_FIRST_MATE_ARCHITECT_THINKING': 'high',
        })
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        self.store.start_visit(feature['id'], 'planning', 'Planning', 'start-runtime-mismatch', 1, human['id'])
        coordinator = {'feature_id': feature['id'], 'kind': 'coordinator', 'claim': human}
        assignment = self.runtime._tool(coordinator, 'fm_delegate', {
            'title': 'Architecture audit', 'role': 'architect',
            'prompt': 'architecture review runtime mismatch', 'model_profile': 'architect',
            'workspace_mode': 'read_only'}, 'runtime-mismatch')
        self.store.finish_message(human['id'], self.runtime.owner, 'Architecture audit queued.')
        claim = self.store.claim_assignment(assignment['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='worker',
                                    prompt=self.runtime._worker_input(feature, claim), claim=claim)
        self.runtime._launch(job)
        self.until(lambda: self.store.get_assignment(assignment['id'])['status'] == 'blocked')

        directory = self.runtime._job_dir(job)
        status = _read_json(directory / 'status.json')
        self.assertTrue(status['startup_validation_failed'])
        self.assertEqual(status['startup_observation']['actual_model'], 'synthetic/mismatched-architect')
        events, _ = _records(directory / 'events.jsonl')
        self.assertFalse(any(event.get('command') == 'prompt' for event in events))
        session_rows, _ = _records(Path(job['session_file']))
        self.assertEqual([row.get('type') for row in session_rows], ['session'])
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/new-host-policy'
        selection = self.runtime.snapshot(feature['id'])['assignments'][0]['model_selection']
        self.assertEqual(selection['requested_model'], 'synthetic/architect')
        self.assertEqual(selection['actual_model'], 'synthetic/mismatched-architect')

    def test_architect_initial_state_requires_observed_model_and_configured_effort(self):
        job = {'model_selection': {'profile': 'architect',
                                   'requested_model': 'synthetic/architect',
                                   'requested_thinking': 'high'}}
        self.assertIn('provider-qualified model', _architect_startup_error(job, {}) or '')
        self.assertIn('thinking effort', _architect_startup_error(job, {
            'model': {'provider': 'synthetic', 'id': 'architect'}}) or '')
        self.assertIn("reported 'low'", _architect_startup_error(job, {
            'model': {'provider': 'synthetic', 'id': 'architect'},
            'thinkingLevel': 'low'}) or '')
        self.assertIsNone(_architect_startup_error(job, {
            'model': {'provider': 'synthetic', 'id': 'architect'},
            'thinkingLevel': 'high'}))

    def test_delegation_replay_freezes_coordinator_and_nested_requested_selection(self):
        feature = self.feature()
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        self.store.start_visit(feature['id'], 'planning', 'Planning', 'start-replay', 1, human['id'])
        coordinator = {'feature_id': feature['id'], 'kind': 'coordinator', 'claim': human}
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect-a'
        params = {'title': 'Architecture review', 'role': 'reviewer',
                  'prompt': 'Give me an architect review', 'model_profile': 'architect',
                  'workspace_mode': 'isolated'}
        first = self.runtime._tool(coordinator, 'fm_delegate', params, 'coordinator-replay')
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect-b'
        second = self.runtime._tool(coordinator, 'fm_delegate', params, 'coordinator-replay')
        self.runtime.environ.pop('HERDR_FIRST_MATE_ARCHITECT_MODEL')
        third = self.runtime._tool(coordinator, 'fm_delegate', params, 'coordinator-replay')
        self.assertEqual({first['id'], second['id'], third['id']}, {first['id']})
        self.assertTrue(all(item['model_selection']['requested_model'] == 'synthetic/architect-a'
                            for item in (first, second, third)))
        self.assertEqual(len(list((self.runtime.root / 'worktrees').glob('*'))), 1)
        with self.assertRaisesRegex(FirstMateError, 'changed instructions'):
            self.runtime._tool(coordinator, 'fm_delegate', {**params, 'prompt': 'Changed'},
                               'coordinator-replay')

        legacy_input = {'title': 'Legacy planner', 'role': 'planner', 'prompt': 'Plan',
                        'workspace_mode': 'read_only'}
        legacy_parameters = {**legacy_input, 'model_profile': 'planning'}
        legacy_token = hashlib.sha256((feature['id'] + 'legacy-replay').encode()).hexdigest()[:20]
        legacy_workspace = {'workspace_mode': 'read_only', 'worktree_path': str(self.cwd),
                            'source_assignment_id': None,
                            'base_revision': self.runtime._git(str(self.cwd), 'rev-parse', 'HEAD')}
        _write_json(self.runtime.root / 'workspace-plans' / (legacy_token + '.json'), {
            'params': legacy_parameters, 'source': str(self.cwd),
            'metadata': legacy_workspace})
        # The pre-upgrade coordinator added model_profile after reading its old
        # workspace plan, before persisting the assignment receipt.
        legacy_receipt = self.store.create_assignment(feature['current_visit_id'], {
            **legacy_parameters, 'metadata': {**legacy_workspace, 'model_profile': 'planning'},
            'request_id': 'legacy-replay', 'input_revision': feature['revision']})
        legacy_first = self.runtime._tool(coordinator, 'fm_delegate', legacy_input, 'legacy-replay')
        self.runtime.environ['HERDR_FIRST_MATE_PLANNER_MODEL'] = 'synthetic/new-planner'
        legacy_second = self.runtime._tool(coordinator, 'fm_delegate', legacy_input, 'legacy-replay')
        self.assertEqual({legacy_receipt['id'], legacy_first['id'], legacy_second['id']},
                         {legacy_receipt['id']})
        self.assertEqual(legacy_first['metadata']['model_profile'], 'planning')
        self.assertNotIn('model_selection', legacy_first)
        self.assertNotIn('model_selection', legacy_first['metadata'])

        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/nested-a'
        parent = self.runtime._tool(coordinator, 'fm_delegate', {
            'title': 'Lead', 'role': 'planner', 'prompt': 'Lead',
            'model_profile': 'planning', 'workspace_mode': 'read_only'}, 'nested-parent-replay')
        parent_claim = self.store.claim_assignment(parent['id'], self.runtime.owner)
        parent_job = self.runtime._new_job(feature, kind='worker', prompt='Lead', claim=parent_claim)
        self.runtime._bind(parent_job, 'nested-replay-parent', parent_job['session_file'])
        child_params = {'title': 'Second opinion', 'role': 'reviewer',
                        'prompt': 'Second opinion on the implementation',
                        'model_profile': 'architect', 'workspace_mode': 'read_only'}
        child_first = self.runtime._tool(parent_job, 'fm_delegate', child_params, 'nested-replay')
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/nested-b'
        child_second = self.runtime._tool(parent_job, 'fm_delegate', child_params, 'nested-replay')
        self.runtime.environ.pop('HERDR_FIRST_MATE_ARCHITECT_MODEL')
        child_third = self.runtime._tool(parent_job, 'fm_delegate', child_params, 'nested-replay')
        self.assertEqual({child_first['id'], child_second['id'], child_third['id']}, {child_first['id']})
        self.assertTrue(all(item['model_selection']['requested_model'] == 'synthetic/nested-a'
                            for item in (child_first, child_second, child_third)))
        with self.assertRaisesRegex(FirstMateError, 'changed instructions'):
            self.runtime._tool(parent_job, 'fm_delegate', {**child_params, 'title': 'Changed'},
                               'nested-replay')

    def test_configuration_rejection_is_finalized_under_writer_lock_and_delayed_runner_refuses_it(self):
        feature = self.feature()
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect'
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        self.store.start_visit(feature['id'], 'planning', 'Planning', 'start-lock-rejection', 1, human['id'])
        coordinator = {'feature_id': feature['id'], 'kind': 'coordinator', 'claim': human}
        assignment = self.runtime._tool(coordinator, 'fm_delegate', {
            'title': 'Architect', 'role': 'reviewer', 'prompt': 'Review',
            'model_profile': 'architect', 'workspace_mode': 'read_only'}, 'lock-rejection')
        claim = self.store.claim_assignment(assignment['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='worker', prompt='Review', claim=claim)
        directory = self.runtime._job_dir(job)
        self.runtime.environ.pop('HERDR_FIRST_MATE_ARCHITECT_MODEL')
        observed = []
        reject = self.runtime._reject_unstarted_job

        def reject_while_locked(candidate, error):
            observed.append(_locked(directory / 'writer.lock'))
            return reject(candidate, error)

        with patch.object(self.runtime, '_reject_unstarted_job', side_effect=reject_while_locked), \
             patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(job)
        spawn.assert_not_called()
        self.assertEqual(observed, [True])
        self.assertTrue(_read_json(directory / 'finalized.json')['configuration_blocked'])
        self.assertEqual(run_detached(directory), 0)
        self.assertFalse((directory / 'started.json').exists())

    def test_unstarted_configuration_rejection_acknowledges_concurrent_human_pause(self):
        feature = self.feature()
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect'
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        self.store.start_visit(feature['id'], 'planning', 'Planning',
                               'start-paused-rejection', 1, human['id'])
        coordinator = {'feature_id': feature['id'], 'kind': 'coordinator', 'claim': human}
        assignment = self.runtime._tool(coordinator, 'fm_delegate', {
            'title': 'Architect', 'role': 'reviewer', 'prompt': 'Review',
            'model_profile': 'architect', 'workspace_mode': 'read_only'},
            'paused-rejection')
        claim = self.store.claim_assignment(assignment['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='worker', prompt='Review', claim=claim)
        self.runtime.environ.pop('HERDR_FIRST_MATE_ARCHITECT_MODEL')
        self.store.feature_action(feature['id'], 'pause', 'human-pause-before-launch')

        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(job)
        spawn.assert_not_called()
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'paused')
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'paused')
        self.assertTrue((self.runtime._job_dir(job) / 'finalized.json').exists())
        self.assertFalse((self.runtime._job_dir(job) / 'started.json').exists())

        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/repaired-architect'
        resumed = self.store.feature_action(feature['id'], 'resume', 'human-resume-after-repair')
        self.assertEqual(resumed['status'], 'running')
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'queued')
        successor_claim = self.store.claim_assignment(assignment['id'], self.runtime.owner)
        successor = self.runtime._new_job(feature, kind='worker', prompt='Review',
                                          claim=successor_claim)
        self.assertEqual(successor_claim['generation'], claim['generation'] + 1)
        self.assertEqual(successor['model'], 'synthetic/repaired-architect')
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'dispatching')

    def test_startup_validation_preserves_concurrent_pause_and_superseded_scope(self):
        def running_architect(feature, suffix):
            self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect'
            human = self.store.claim_message(feature['id'], self.runtime.owner)
            self.store.start_visit(feature['id'], 'planning', 'Planning', 'stage-' + suffix,
                                   feature['revision'], human['id'])
            coordinator = {'feature_id': feature['id'], 'kind': 'coordinator', 'claim': human}
            assignment = self.runtime._tool(coordinator, 'fm_delegate', {
                'title': 'Architect', 'role': 'reviewer', 'prompt': 'Review',
                'model_profile': 'architect', 'workspace_mode': 'read_only'}, 'delegate-' + suffix)
            claim = self.store.claim_assignment(assignment['id'], self.runtime.owner)
            job = self.runtime._new_job(feature, kind='worker', prompt='Review', claim=claim)
            self.runtime._bind(job, 'native-' + suffix, job['session_file'])
            return assignment, claim, job

        feature = self.feature()
        assignment, claim, job = running_architect(feature, 'paused')
        self.store.feature_action(feature['id'], 'pause', 'human-pause')
        self.runtime._finish(job, {'ended': True, 'startup_validation_failed': True,
                                   'error': 'Architect startup blocked: mismatch'})
        self.assertEqual(self.store.get_feature(feature['id'])['status'], 'paused')
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'paused')

        revised = self.store.create_feature({'title': 'Revised synthetic feature', 'goal': 'Review',
            'cwd': str(self.cwd), 'request_id': 'create-revised-startup'})
        assignment, claim, job = running_architect(revised, 'revised')
        self.store.finish_message(self.store.pending_messages(revised['id'])[0]['id'],
                                  self.runtime.owner, 'Stage started')
        self.store.append_human_message(revised['id'], 'Revise scope', 'revise-direction')
        direction = self.store.claim_message(revised['id'], self.runtime.owner)
        self.store.revise_feature(revised['id'], 'Changed scope', 1, 'revise-startup',
                                  direction['id'], verified_stopped=True)
        self.runtime._finish(job, {'ended': True, 'startup_validation_failed': True,
                                   'error': 'Architect startup blocked: mismatch'})
        self.assertEqual(self.store.get_feature(revised['id'])['status'], 'awaiting_direction')
        self.assertEqual(self.store.get_assignment(assignment['id'])['status'], 'superseded')
        self.assertTrue((self.runtime._job_dir(job) / 'finalized.json').exists())

    def test_architect_negative_malformed_timeout_and_unrelated_initial_state_never_prompt(self):
        variants = ('initial state rejected', 'malformed initial state',
                    'initial state timeout', 'unrelated initial state')
        for index, variant in enumerate(variants):
            with self.subTest(variant=variant):
                directory = self.root / ('startup-' + str(index))
                directory.mkdir()
                session = directory / 'session.jsonl'
                job = {'id': 'startup-' + str(index), 'kind': 'worker',
                       'feature_id': 'synthetic-feature', 'cwd': str(self.cwd),
                       'session_file': str(session), 'prompt': variant,
                       'claim': {'title': 'Architect'}, 'pi_bin': str(self.fake),
                       'extension': str(self.root / 'synthetic-extension.ts'),
                       'model': 'synthetic/architect', 'thinking': 'high',
                       'startup_timeout_seconds': 1,
                       'model_selection': {'profile': 'architect',
                           'requested_model': 'synthetic/architect',
                           'requested_thinking': 'high'}}
                _write_json(directory / 'job.json', job)
                with patch.dict(os.environ, {'HERDR_FIRST_MATE_JOB_DIR': str(directory)}):
                    self.assertEqual(run_detached(directory), 1)
                status = _read_json(directory / 'status.json')
                self.assertTrue(status['startup_validation_failed'])
                events, _ = _records(directory / 'events.jsonl')
                self.assertFalse(any(event.get('command') == 'prompt' for event in events))
                if variant == 'initial state rejected':
                    self.assertEqual(status['startup_observation']['actual_model'],
                                     'synthetic/architect')
                else:
                    self.assertIsNone(status['startup_observation']['actual_model'])

    def test_pin_removal_blocks_real_child_continuation_handoff_and_claim_gap_without_wedging(self):
        feature = self.feature()
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect'
        human = self.store.claim_message(feature['id'], self.runtime.owner)
        visit = self.store.start_visit(feature['id'], 'planning', 'Planning', 'start-real-continuation', 1, human['id'])
        parent = self.store.create_assignment(visit['id'], {
            'title': 'Architect lead', 'role': 'reviewer', 'prompt': 'Lead',
            'metadata': {'model_profile': 'architect', 'workspace_mode': 'read_only'},
            'request_id': 'real-parent', 'input_revision': 1})
        parent_claim = self.store.claim_assignment(parent['id'], self.runtime.owner)
        parent_job = self.runtime._new_job(feature, kind='worker', prompt='Lead', claim=parent_claim)
        self.runtime._bind(parent_job, 'real-parent-native', parent_job['session_file'])
        child = self.runtime._tool(parent_job, 'fm_delegate', {
            'title': 'Child', 'role': 'reviewer', 'prompt': 'Inspect',
            'workspace_mode': 'read_only'}, 'real-child')
        self.store.wait_for_children(parent['id'], parent_claim['generation'],
                                     'real-parent-native', 'Await child', 'real-wait')
        child_claim = self.store.claim_assignment(child['id'], self.runtime.owner)
        child_job = self.runtime._new_job(feature, kind='worker', prompt='Inspect', claim=child_claim)
        self.runtime._bind(child_job, 'real-child-native', child_job['session_file'])
        self.store.record_outcome(child['id'], child_claim['generation'], 'real-child-native', 1,
                                  'success', 'Inspected', 'real-child-outcome')
        parent_job['waiting_children'] = 'Await child'
        self.runtime.environ.pop('HERDR_FIRST_MATE_ARCHITECT_MODEL')
        jobs_before = {job['id'] for job in self.runtime._jobs()}
        self.assertTrue(self.runtime._continue_children(parent_job))
        self.assertEqual(self.store.get_assignment(parent['id'])['status'], 'blocked')
        self.assertEqual({job['id'] for job in self.runtime._jobs()}, jobs_before)

        # A real claim/spool crash gap is blocked, then a repaired pin and retry
        # can reconcile normally instead of leaving the feature wedged.
        gap_feature = self.store.create_feature({'title': 'Claim gap', 'goal': 'Review',
            'cwd': str(self.cwd), 'request_id': 'create-claim-gap'})
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect'
        gap_human = self.store.claim_message(gap_feature['id'], self.runtime.owner)
        gap_visit = self.store.start_visit(gap_feature['id'], 'planning', 'Planning',
                                           'gap-stage', 1, gap_human['id'])
        gap = self.store.create_assignment(gap_visit['id'], {
            'title': 'Gap architect', 'role': 'reviewer', 'prompt': 'Review',
            'metadata': {'model_profile': 'architect', 'workspace_mode': 'read_only'},
            'request_id': 'gap-assignment', 'input_revision': 1})
        gap_claim = self.store.claim_assignment(gap['id'], self.runtime.owner)
        self.runtime.environ.pop('HERDR_FIRST_MATE_ARCHITECT_MODEL')
        self.runtime._recover_claim_gaps()
        self.assertEqual(self.store.get_assignment(gap['id'])['status'], 'blocked')
        self.runtime.environ['HERDR_FIRST_MATE_ARCHITECT_MODEL'] = 'synthetic/architect-repaired'
        self.store.feature_action(gap_feature['id'], 'resume', 'resume-gap')
        metadata = dict(self.store.get_assignment(gap['id'])['metadata'])
        metadata['model_selection'] = self.runtime._policy(
            self.store.get_feature(gap_feature['id']), kind='worker',
            claim={**self.store.get_assignment(gap['id']), 'metadata': metadata}).selection()
        self.store.retry_assignment(gap['id'], 'Retry review', 'retry-gap',
                                    metadata=metadata, verified_stopped=True)
        launched = []
        with patch.object(self.runtime, '_launch', side_effect=launched.append), \
             patch.object(self.runtime, 'capabilities', return_value={'available': True}):
            self.runtime.reconcile()
        self.assertTrue(any(job['claim']['id'] == gap['id'] for job in launched))
        self.assertEqual(self.store.get_assignment(gap['id'])['status'], 'dispatching')

        handoff_feature = self.store.create_feature({'title': 'Handoff', 'goal': 'Review',
            'cwd': str(self.cwd), 'request_id': 'create-real-handoff'})
        handoff_human = self.store.claim_message(handoff_feature['id'], self.runtime.owner)
        handoff_visit = self.store.start_visit(handoff_feature['id'], 'planning', 'Planning',
                                               'handoff-stage', 1, handoff_human['id'])
        handoff_assignment = self.store.create_assignment(handoff_visit['id'], {
            'title': 'Handoff architect', 'role': 'reviewer', 'prompt': 'Review',
            'metadata': {'model_profile': 'architect', 'workspace_mode': 'read_only'},
            'request_id': 'handoff-assignment', 'input_revision': 1})
        handoff_claim = self.store.claim_assignment(handoff_assignment['id'], self.runtime.owner)
        handoff_job = self.runtime._new_job(handoff_feature, kind='worker', prompt='Review', claim=handoff_claim)
        self.runtime._bind(handoff_job, 'handoff-native', handoff_job['session_file'])
        handoff = self.store.begin_handoff(handoff_assignment['id'], handoff_claim['generation'],
                                           'begin-real-handoff', 'Continue review')
        handoff_job['pending_handoff'] = handoff
        self.runtime.environ.pop('HERDR_FIRST_MATE_ARCHITECT_MODEL')
        handoff_jobs_before = {job['id'] for job in self.runtime._jobs()}
        self.assertTrue(self.runtime._continue_handoff(handoff_job))
        self.assertEqual(self.store.get_assignment(handoff_assignment['id'])['status'], 'blocked')
        self.assertEqual({job['id'] for job in self.runtime._jobs()}, handoff_jobs_before)

    def test_started_or_locked_job_keeps_recorded_extension(self):
        feature = self.feature()
        claim = self.store.claim_message(feature['id'], self.runtime.owner)
        job = self.runtime._new_job(feature, kind='coordinator', prompt='Hello', claim=claim)
        current = self.root / 'current-first-mate.ts'
        current.write_text('// synthetic current extension\n')
        self.runtime.extension = current
        job['extension'] = '/private/running-package/extensions/first-mate.ts'
        self.runtime._save_job(job)
        directory = self.runtime._job_dir(job)

        _write_json(directory / 'started.json', {'pid': 123, 'extension': job['extension']})
        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(job)
        spawn.assert_not_called()
        self.assertEqual(_read_json(directory / 'job.json')['extension'], job['extension'])

        (directory / 'started.json').unlink()
        lock = (directory / 'writer.lock').open('a')
        import fcntl
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with patch('herdr_harness.first_mate_runtime.subprocess.Popen') as spawn:
            self.runtime._launch(job)
        spawn.assert_not_called()
        self.assertEqual(_read_json(directory / 'job.json')['extension'], job['extension'])
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()

if __name__ == '__main__': unittest.main()
