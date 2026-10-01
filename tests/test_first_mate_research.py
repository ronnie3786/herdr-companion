"""Synthetic specialist instructions and saved-transcript contracts."""
import tempfile
import unittest
from pathlib import Path

from herdr_harness.first_mate_research import read_research_instructions
from herdr_harness.first_mate_routing import ResearchScoutConfigurationError, resolve_dispatch_policy
from herdr_harness.first_mate_runtime import _architect_startup_error, _pi_command
from herdr_harness.first_mate_transcript import session_messages


class ResearchScoutTests(unittest.TestCase):
    def test_explicit_pin_and_private_instructions_are_required_without_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'instructions.md'
            path.write_text('Synthetic platform research reference.')
            environment = {'HERDR_FIRST_MATE_RESEARCH_SCOUT_MODEL': 'synthetic/research',
                           'HERDR_FIRST_MATE_RESEARCH_SCOUT_THINKING': 'high',
                           'HERDR_FIRST_MATE_RESEARCH_SCOUT_INSTRUCTIONS_FILE': str(path)}
            claim = {'model': 'synthetic/do-not-use', 'metadata': {'model_profile': 'research_scout'}}
            policy = resolve_dispatch_policy(kind='worker', feature={}, claim=claim, environ=environment)
            self.assertEqual((policy.profile, policy.requested_model, policy.requested_thinking),
                             ('research_scout', 'synthetic/research', 'high'))
            for missing in ['MODEL', 'INSTRUCTIONS_FILE']:
                incomplete = {key: value for key, value in environment.items()
                              if key != 'HERDR_FIRST_MATE_RESEARCH_SCOUT_' + missing}
                incomplete['HERDR_FIRST_MATE_WORKER_MODEL'] = 'synthetic/no-fallback'
                with self.assertRaises(ResearchScoutConfigurationError):
                    resolve_dispatch_policy(kind='worker', feature={}, claim=claim, environ=incomplete)
            for invalid in ['', 'x' * (256 * 1024 + 1)]:
                path.write_text(invalid)
                with self.assertRaises(ResearchScoutConfigurationError):
                    read_research_instructions(environment)

    def test_private_charter_uses_file_and_startup_checks_actual_model(self):
        with tempfile.TemporaryDirectory() as directory:
            job = {'kind': 'worker', 'pi_bin': 'pi', 'session_file': str(Path(directory) / 'session.jsonl'),
                   'extension': '/synthetic/first-mate.ts', 'claim': {'title': 'Research Scout'},
                   'research_scout_instructions': 'Synthetic private API lookup instructions.',
                   'model_selection': {'profile': 'research_scout', 'requested_model': 'synthetic/research'}}
            command = _pi_command(job)
            self.assertNotIn('Synthetic private', str(command))
            prompt = Path(command[command.index('--append-system-prompt') + 1]).read_text()
            self.assertIn('Synthetic private API lookup instructions.', prompt)
            self.assertIn('fm_outcome', prompt)
            self.assertIsNone(_architect_startup_error(job, {'model': {'provider': 'synthetic', 'id': 'research'}}))
            self.assertIn('Research Scout startup blocked', _architect_startup_error(
                job, {'model': {'provider': 'synthetic', 'id': 'wrong'}}))


class SavedTranscriptTests(unittest.TestCase):
    def test_tool_only_messages_keep_identity_arguments_results_and_answer(self):
        messages = session_messages([
            {'type': 'session', 'id': 'synthetic-session'},
            {'id': 'user', 'message': {'role': 'user', 'content': 'Inspect the fixture'}},
            {'id': 'call', 'message': {'role': 'assistant', 'content': [
                {'type': 'thinking', 'thinking': 'Check the evidence.', 'thinkingSignature': 'provider-private'},
                {'type': 'toolCall', 'id': 'read-1', 'name': 'read', 'arguments': {'path': 'fixture.txt'}}],
                'stopReason': 'toolUse'}},
            {'id': 'result', 'message': {'role': 'toolResult', 'toolCallId': 'read-1', 'toolName': 'read',
                'content': [{'type': 'text', 'text': 'The saved evidence.'}], 'isError': False}},
            {'id': 'answer', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'Verified.'}],
                'stopReason': 'stop'}},
        ])
        self.assertEqual([message['index'] for message in messages], list(range(4)))
        self.assertEqual(messages[1]['tool_calls'][0]['id'], messages[2]['tool_call_id'])
        self.assertEqual(messages[1]['tool_calls'][0]['arguments'], {'path': 'fixture.txt'})
        self.assertEqual(messages[3]['text'], 'Verified.')
        self.assertEqual(messages[3]['stop_reason'], 'stop')
        self.assertNotIn('provider-private', str(messages))
