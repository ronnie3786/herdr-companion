"""Request budgets permit a slow-but-responsive companion without duplicate writes."""
import io
import json
import socket
import unittest
from unittest.mock import MagicMock, patch

from herdr_harness.client import HerdrClient
from herdr_harness.control_cli import ControlClient
from herdr_harness.pi_semantic import PiSemanticManager
from herdr_harness.remote_activity import RemoteActivityPoller


class NetworkTimeoutBudgetsTests(unittest.TestCase):
    def test_native_socket_tolerates_a_seven_second_reply(self):
        connection = MagicMock()
        connection.__enter__.return_value = connection
        budget = []
        connection.settimeout.side_effect = budget.append
        def receive(_maximum):
            if budget[-1] < 7:
                raise socket.timeout("synthetic slow native server")
            return b'{"id":"slow-native","result":{"type":"ok"}}\n'
        connection.recv.side_effect = receive
        with patch('herdr_harness.client.socket.socket', return_value=connection):
            result = HerdrClient('/tmp/synthetic.sock').request('session.snapshot', request_id='slow-native')
        self.assertEqual(result['type'], 'ok')
        connection.sendall.assert_called_once()

    def test_pi_command_keeps_a_slow_acknowledgement_observable(self):
        manager = PiSemanticManager('/tmp/synthetic.sock', environ={})
        self.addCleanup(manager.journal.close)
        manager._known_pi_panes.add('w1:p1')
        connection = MagicMock()
        connection.__enter__.return_value = connection
        identifier = []
        connection.sendall.side_effect = lambda data: identifier.append(json.loads(data)['id'])
        connection.recv.side_effect = lambda _size: json.dumps({'id': identifier[0], 'success': True}).encode() + b'\n'
        # The response arrives after the previous 3-second ceiling. The new
        # deadline must still enter recv and preserve the original request ID.
        with patch.object(manager, '_connect', return_value=connection) as connect, \
                patch('herdr_harness.pi_semantic.time.monotonic', side_effect=[0, 7, 7]):
            result = manager.command('w1:p1', 'prompt', {'text': 'Synthetic task'})
        self.assertTrue(result['success'])
        self.assertGreater(connect.call_args.kwargs['timeout'], 7)
        self.assertGreater(connection.settimeout.call_args.args[0], 7)
        connection.sendall.assert_called_once()

    def test_remote_activity_bootstrap_allows_slow_snapshot(self):
        def slow(request, timeout=None):
            if timeout <= 8:
                raise TimeoutError('synthetic slow snapshot')
            return io.BytesIO(b'{"latest_cursor":42}')
        poller = RemoteActivityPoller(lambda: set(), lambda event: None, environ={
            'HERDR_HARNESS_REMOTE_ACTIVITY_URL': 'https://synthetic.example.invalid'}, open_url=slow)
        self.assertEqual(poller._latest_cursor('w1:p1'), 42)

    def test_native_agent_wait_outlives_its_requested_completion_window(self):
        for wait, expected in (({}, 125), ({"timeout_ms": 300000}, 305),
                               ({"timeout_ms": True}, None), ({"timeout_ms": 300001}, None)):
            with self.subTest(wait=wait):
                connection = MagicMock()
                connection.__enter__.return_value = connection
                connection.recv.return_value = b'{"id":"wait","result":{"type":"ok"}}\n'
                client = HerdrClient('/tmp/synthetic.sock')
                with patch.object(client, '_connect', return_value=connection):
                    client.request('agent.prompt', {'target':'w1:p1', 'text':'Continue', 'wait':wait}, request_id='wait')
                if expected is None:
                    connection.settimeout.assert_not_called()
                else:
                    connection.settimeout.assert_called_once_with(expected)
                connection.sendall.assert_called_once()

    def test_http_agent_wait_outlives_native_wait_and_does_not_extend_pi_ack(self):
        budgets = []
        def opener(request, timeout=None):
            budgets.append(timeout)
            return io.BytesIO(b'{"ok":true}')
        client = ControlClient('https://synthetic.example.invalid', 'synthetic-token', opener=opener)
        for path, payload in (
            ('/api/v1/panes/p/prompt', {'wait':True}),
            ('/api/v1/agents/a/prompt', {'wait':True, 'timeoutMs':300000}),
            ('/api/v1/panes/p/pi/prompt', {'wait':True}),
            ('/api/v1/panes/p/prompt', {'wait':True, 'timeoutMs':True}),
        ):
            client.request('POST', path, payload, has_payload=True)
        self.assertEqual(budgets, [135, 315, 60, 60])
