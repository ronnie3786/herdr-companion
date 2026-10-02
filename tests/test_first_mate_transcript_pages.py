"""Saved-session pagination remains compatible while retaining only one page."""
import json
from pathlib import Path
import tempfile
import tracemalloc
import unittest
from unittest import mock

from herdr_harness.first_mate_transcript import session_messages, session_page
from herdr_harness.first_mate_usage import FirstMateUsage
from test_first_mate_usage import assistant, write_session


class SavedSessionPageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.path = self.root / 'saved.jsonl'
        self.engine = FirstMateUsage(self.root)

    def page(self, before=None, limit=2):
        return session_page(self.path, 'native-saved', before=before, limit=limit,
                            opener=self.engine._open_source)

    def test_counts_cursors_and_contents_match_original_projection(self):
        rows = [assistant(str(i), 1) for i in range(7)]
        rows.insert(2, {'type': 'model_change', 'modelId': 'synthetic'})
        rows.insert(5, {'type': 'message', 'message': {'role': 'user', 'content': 'Synthetic'}})
        write_session(self.path, 'native-saved', rows)
        expected = session_messages(rows)
        for before in (None, 0, 1, 4, 8, 99, -1):
            for limit in (1, 2, 100):
                with self.subTest(before=before, limit=limit):
                    end = len(expected) if before is None else max(0, min(len(expected), before))
                    start = max(0, end - limit)
                    actual = self.page(before=before, limit=limit)
                    self.assertEqual(actual, {'messages': expected[start:end],
                        'total_messages': len(expected), 'next_before': start or None})

    def test_large_history_memory_is_page_sized(self):
        row = {'type': 'message', 'message': {'role': 'toolResult', 'content': 'x' * (512 * 1024)}}
        write_session(self.path, 'native-saved', [row] * 32)
        tracemalloc.start()
        try:
            result = self.page(limit=1)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(result['total_messages'], 32)
        self.assertEqual(result['next_before'], 31)
        self.assertLess(peak, 6 * 1024 * 1024)

    def test_append_cannot_extend_the_initial_read_and_rewritten_identity_is_rejected(self):
        rows = [assistant('one'), assistant('two')]
        write_session(self.path, 'native-saved', rows)
        calls = 0
        def append_once(values):
            nonlocal calls
            calls += 1
            if calls == 1:
                with self.path.open('a') as handle:
                    handle.write(json.dumps(assistant('later')) + '\n')
            return session_messages(values)
        with mock.patch('herdr_harness.first_mate_transcript.session_messages', side_effect=append_once):
            self.assertEqual(self.page()['total_messages'], 2)
        self.assertEqual(self.page()['total_messages'], 3)
        def rewrite(values):
            write_session(self.path, 'other-native', rows)
            return session_messages(values)
        with mock.patch('herdr_harness.first_mate_transcript.session_messages', side_effect=rewrite):
            with self.assertRaisesRegex(ValueError, 'changed while being read'):
                self.page()

    def test_header_must_be_first_complete_record(self):
        self.path.write_text('{}\n' + json.dumps({'type': 'session', 'id': 'native-saved'}) + '\n')
        with self.assertRaisesRegex(ValueError, 'identity does not match'):
            self.page()


if __name__ == '__main__':
    unittest.main()
