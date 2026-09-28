"""Coordinator activity, absolute bounds, and real detached supervisor regressions."""
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

from herdr_harness.first_mate_runtime import _ExecutionBudget, _read_json, _write_json


class ExecutionBudgetTests(unittest.TestCase):
    def budget(self):
        return _ExecutionBudget({'kind': 'coordinator', 'idle_timeout_seconds': 600,
                                 'timeout_seconds': 3600}, 0)

    def test_completed_inspection_keeps_turn_alive_past_ten_minutes(self):
        budget = self.budget()
        for index, moment in enumerate((120, 260, 370, 480, 495)):
            budget.observe({'type': 'tool_execution_end', 'toolCallId': f'probe-{index}'}, moment)
        self.assertIsNone(budget.error(601))
        self.assertIn('inactivity timeout', budget.error(1095))

    def test_streamed_thinking_is_activity_but_empty_deltas_are_not(self):
        budget = self.budget()
        for kind in ('thinking_delta', 'text_delta', 'toolcall_delta'):
            self.assertTrue(budget.observe({'type': 'message_update',
                'assistantMessageEvent': {'type': kind, 'delta': 'new content'}}, 599))
        self.assertIsNone(budget.error(601))
        self.assertFalse(budget.observe({'type': 'message_update',
            'assistantMessageEvent': {'type': 'thinking_delta', 'delta': ''}}, 1190))
        self.assertIn('inactivity timeout', budget.error(1199))

    def test_telemetry_acknowledgments_and_duplicate_receipts_cannot_renew_budget(self):
        budget = self.budget()
        budget.observe({'type': 'tool_execution_end', 'toolCallId': 'once'}, 10)
        for event in ({'type': 'context_usage'}, {'type': 'response', 'command': 'get_state'},
                      {'type': 'tool_execution_start', 'toolCallId': 'new'},
                      {'type': 'tool_execution_end', 'toolCallId': 'once'}):
            self.assertFalse(budget.observe(event, 609))
        self.assertIn('inactivity timeout', budget.error(610))

    def test_continuous_activity_cannot_extend_absolute_ceiling(self):
        budget = self.budget()
        budget.observe({'type': 'message_update', 'assistantMessageEvent':
                        {'type': 'text_delta', 'delta': 'working'}}, 3599)
        self.assertIn('supervisor deadline', budget.error(3600))
        self.assertFalse(budget.nudge_due(599))
        self.assertTrue(budget.nudge_due(600))
        self.assertFalse(budget.nudge_due(1800))

    def test_old_dispatches_and_other_roles_keep_their_persisted_hard_limit(self):
        for role in ('coordinator', 'worker', 'advisor'):
            budget = _ExecutionBudget({'kind': role, 'timeout_seconds': 600}, 0)
            budget.observe({'type': 'tool_execution_end', 'toolCallId': 'probe'}, 599)
            self.assertIn('supervisor deadline', budget.error(600))
            self.assertFalse(budget.nudge_due(599))


PROVIDER = r'''#!PYTHON
import json,sys,time
for line in sys.stdin:
 command=json.loads(line)
 if command['type']=='get_state':
  print(json.dumps({'type':'response','command':'get_state','id':command['id'],'success':True,'data':{}}),flush=True)
 elif command['type']=='prompt':
  print(json.dumps({'type':'response','command':'prompt','id':command['id'],'success':True}),flush=True)
  start=time.monotonic()
  while time.monotonic()-start < 2.2:
   event={'type':'message_update','assistantMessageEvent':{'type':'thinking_delta','delta':'working'}} if command['message']=='active' else {'type':'response','command':'get_state','success':True}
   print(json.dumps(event),flush=True)
   time.sleep(.1)
  print(json.dumps({'type':'message_end','message':{'role':'assistant','content':[{'type':'text','text':'Inspection complete.'}]}}),flush=True)
  print(json.dumps({'type':'agent_end'}),flush=True)
'''


class DetachedDeadlineTests(unittest.TestCase):
    def run_provider(self, prompt, maximum=8):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            provider = root / 'synthetic-pi'
            provider.write_text(PROVIDER.replace('PYTHON', sys.executable))
            provider.chmod(0o700)
            job = {'id': 'synthetic-budget', 'kind': 'coordinator', 'cwd': tmp,
                   'session_file': str(root / 'session.jsonl'), 'pi_bin': str(provider),
                   'extension': str(root / 'synthetic-extension.ts'), 'prompt': prompt,
                   'claim': {}, 'timeout_seconds': maximum, 'idle_timeout_seconds': 1.5}
            _write_json(root / 'job.json', job)
            result = subprocess.run([sys.executable, '-m', 'herdr_harness.first_mate_runtime',
                '--runner', tmp], env={**os.environ, 'HERDR_FIRST_MATE_JOB_DIR': tmp},
                capture_output=True, text=True, timeout=15)
            self.assertTrue((root / 'status.json').exists(), result.stderr)
            return result.returncode, _read_json(root / 'status.json')

    def test_real_supervisor_finishes_active_turn_after_initial_budget(self):
        result, state = self.run_provider('active')
        self.assertEqual(result, 0, state)
        self.assertEqual(state['response'], 'Inspection complete.')
        self.assertTrue(state['budget_nudge_sent'])

    def test_real_supervisor_stops_quiet_model_despite_rpc_heartbeats(self):
        result, state = self.run_provider('quiet')
        self.assertEqual(result, 1)
        self.assertIn('inactivity timeout', state['error'])

    def test_real_supervisor_stops_continuous_output_at_absolute_ceiling(self):
        result, state = self.run_provider('active', maximum=1)
        self.assertEqual(result, 1)
        self.assertIn('supervisor deadline', state['error'])
