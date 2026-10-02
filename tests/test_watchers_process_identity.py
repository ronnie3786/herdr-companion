import os
from pathlib import Path
import signal
import sys
import unittest
from unittest.mock import patch

from herdr_harness.watchers import process_identity as identity


class WatchersProcessIdentityTests(unittest.TestCase):
    def test_live_process_identity_and_non_signaling_probe(self):
        if sys.platform not in ('darwin', 'linux'):
            self.skipTest('Process identity is implemented for companion macOS/Linux hosts')
        value = identity.process_identity(os.getpid())
        self.assertIsNotNone(value)
        self.assertEqual(value['pid'], os.getpid())
        self.assertEqual(value['pgid'], os.getpgid(os.getpid()))
        self.assertEqual(value['uid'], os.geteuid())
        self.assertTrue(value['started'])
        self.assertTrue(identity.same_process(os.getpid(), value))
        self.assertTrue(identity.signal_process(os.getpid(), value, 0))

    def test_invalid_unknown_and_reused_pids_fail_closed(self):
        for pid in (None, True, -1, 0, 1, '123'):
            self.assertIsNone(identity.process_identity(pid))
        expected = {'pid': 1234, 'started': 'old', 'pgid': 1234, 'uid': os.geteuid()}
        for actual in (None, {**expected, 'started': 'new'}, {**expected, 'uid': os.geteuid() + 1}, {**expected, 'pgid': 789}):
            with self.subTest(actual=actual), patch.object(identity, 'process_identity', return_value=actual), patch.object(identity.os, 'kill') as kill, patch.object(identity.os, 'killpg') as killpg:
                self.assertFalse(identity.same_process(1234, expected))
                self.assertFalse(identity.signal_process(1234, expected, signal.SIGTERM))
                self.assertFalse(identity.signal_process(1234, expected, signal.SIGKILL, group=True))
                kill.assert_not_called()
                killpg.assert_not_called()

    def test_group_signal_requires_group_leader_and_current_user(self):
        expected = {'pid': 1234, 'started': 'original', 'pgid': 1234, 'uid': os.geteuid()}
        with patch.object(identity, 'process_identity', return_value=expected), patch.object(identity.os, 'killpg') as killpg:
            self.assertTrue(identity.signal_process(1234, expected, signal.SIGTERM, group=True))
            killpg.assert_called_once_with(1234, signal.SIGTERM)
        for different in ({**expected, 'uid': os.geteuid() + 1}, {**expected, 'pgid': 5678}):
            with patch.object(identity, 'process_identity', return_value=different), patch.object(identity.os, 'killpg') as killpg:
                self.assertFalse(identity.signal_process(1234, different, signal.SIGTERM, group=True))
                killpg.assert_not_called()

    def test_process_exit_between_check_and_signal_is_harmless(self):
        expected = {'pid': 1234, 'started': 'original', 'pgid': 1234, 'uid': os.geteuid()}
        with patch.object(identity, 'process_identity', return_value=expected), patch.object(identity.os, 'kill', side_effect=ProcessLookupError):
            self.assertFalse(identity.signal_process(1234, expected, signal.SIGTERM))

    def test_linux_parser_handles_parentheses_and_includes_boot_identity(self):
        fields = ['S', '1', '1234'] + ['0'] * 16 + ['56789']
        stat = '1234 (example (worker)) ' + ' '.join(fields)
        files = {'/proc/1234/stat': stat, '/proc/1234/status': 'Name:\texample\nUid:\t1000\t1001\t1001\t1001\n', '/proc/sys/kernel/random/boot_id': 'synthetic-boot-id\n'}
        with patch.object(Path, 'read_text', lambda path: files[str(path)]), patch.object(identity.sys, 'platform', 'linux'):
            self.assertEqual(identity.process_identity(1234), {'pid': 1234, 'started': 'linux:synthetic-boot-id:56789', 'pgid': 1234, 'uid': 1001})

    def test_unreadable_or_unsupported_identity_fails_closed(self):
        with patch.object(identity.sys, 'platform', 'linux'), patch.object(Path, 'read_text', side_effect=PermissionError):
            self.assertIsNone(identity.process_identity(1234))
        with patch.object(identity.sys, 'platform', 'unsupported'):
            self.assertIsNone(identity.process_identity(1234))
