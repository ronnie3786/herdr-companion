import json
import unittest

from herdr_harness.watchers.errors import WatchersError
from herdr_harness.watchers.steps.gate import evaluate


class WatcherGateTests(unittest.TestCase):
    def test_new_items_and_versions_only_forward_new_data(self):
        rule = {'kind': 'new_items', 'key': 'url', 'version': 'updated'}
        first = [{'url': 'https://example.invalid/1', 'updated': 'v1'}]
        passed, output, cursor = evaluate(rule, json.dumps({'items': first}))
        self.assertTrue(passed)
        self.assertEqual(json.loads(output), first)
        self.assertFalse(evaluate(rule, json.dumps(first), cursor)[0])
        updated = [{'url': 'https://example.invalid/1', 'updated': 'v2'}]
        self.assertEqual(json.loads(evaluate(rule, json.dumps(updated), cursor)[1]), updated)

    def test_cursor_is_bounded_to_newest_keys(self):
        items = [{'id': i} for i in range(6000)]
        _, _, cursor = evaluate({'kind': 'new_items', 'key': 'id'}, json.dumps(items))
        self.assertEqual(len(cursor['keys']), 5000)
        self.assertEqual(cursor['keys'][0]['key'], '1000')
        self.assertEqual(cursor['keys'][-1]['key'], '5999')

    def test_changed_hashes_exact_output(self):
        passed, output, cursor = evaluate({'kind': 'changed'}, b'first')
        self.assertTrue(passed)
        self.assertFalse(evaluate({'kind': 'changed'}, b'first', cursor)[0])
        self.assertTrue(evaluate({'kind': 'changed'}, b'first\n', cursor)[0])

    def test_invalid_data_fails_instead_of_silently_skipping(self):
        for content in ('not json', '{}', '[{"other":1}]'):
            with self.assertRaises(WatchersError):
                evaluate({'kind': 'new_items', 'key': 'id'}, content)
