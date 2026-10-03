"""Streaming usage extraction validates skipped JSON and stays bounded."""
import json
import tracemalloc
import unittest

from herdr_harness.usage_json import UsageJSON, usage_fingerprint


class UsageJSONTests(unittest.TestCase):
    def test_every_byte_boundary_preserves_usage_and_unicode_keys(self):
        row = (b'{"type":"message","content":[{"usage":{"cost":{"total":99}}}],'
               b'"message":{"role":"assistant","content":"image \\u1234 \\n \\" '
               + "é🐈".encode() + b'","us\\u0061ge":{"input":42,"cost":{"total":1.25}}}}\n')
        expected = {"type": "message", "message": {"role": "assistant", "usage": {
            "input": 42, "cost": {"total": 1.25}}}}
        for size in range(1, len(row) + 1):
            with self.subTest(size=size):
                reader = UsageJSON(row[i:i + size] for i in range(0, len(row), size))
                self.assertEqual(reader.record(), expected)
                self.assertEqual(reader.fingerprint, usage_fingerprint(json.loads(row)))

    def test_discarded_values_are_still_validated(self):
        for value in (b'"\\q"', b'"\\u00xx"', b'"\xff"', b'"\xc3\\n"', b'"\x01"',
                      b'[1,]', b'{"a":1,}', b'01', b'NaN', b'1e', b'no', b'[' * 66 + b']' * 66):
            with self.subTest(value=value):
                row = b'{"content":' + value + b'}'
                with self.assertRaises(ValueError):
                    UsageJSON(row[i:i + 3] for i in range(0, len(row), 3)).record()

    def test_duplicate_keys_keep_last_value_like_standard_decoder(self):
        row = b'{"usage":{"cost":{"total":1}},"usage":{"cost":{"total":2}}}'
        self.assertEqual(UsageJSON([row]).record(), json.loads(row))

    def test_large_unknown_keys_and_arrays_are_discarded(self):
        row = json.dumps({"x" * 1000: 1, "content": [dict(text="hello")] * 10000,
                          "message": {"role": "toolResult"}}).encode()
        self.assertEqual(UsageJSON([row], limit=1024).record(), {"message": {"role": "toolResult"}})

    def test_fingerprints_match_standard_parser_for_equivalent_json(self):
        rows = [b'{"id":"x","content":"\\ud83d\\ude00","usage":{"cost":{"total":1e0}}}',
                '{"usage":{"cost":{"total":1.0}}, "content":"😀", "id":"x"}'.encode(),
                b'{"id":"x","id":"x","content":"\\ud83d\\ude00","usage":{"cost":{"total":1.0}}}']
        expected = usage_fingerprint(json.loads(rows[0]))
        for row in rows:
            reader = UsageJSON(bytes([byte]) for byte in row)
            reader.record()
            self.assertEqual(reader.fingerprint, expected)

    def test_very_wide_discarded_object_hits_memory_bound(self):
        row = json.dumps({"content": {str(i): i for i in range(1000)}}).encode()
        with self.assertRaises(ValueError):
            UsageJSON([row], limit=1024).record()

    def test_cancellation_can_interrupt_within_a_chunk_of_small_values(self):
        def stop():
            raise InterruptedError("synthetic stop")

        row = json.dumps({"content": [0] * 2000}).encode()
        with self.assertRaises(InterruptedError):
            UsageJSON([row], check_cancelled=stop).record()

    def test_large_selected_metadata_fails_closed(self):
        with self.assertRaises(ValueError):
            UsageJSON([b'{"id":"' + b"x" * 1024 + b'"}'], limit=64).record()

    def test_memory_does_not_grow_with_discarded_image_size(self):
        def chunks():
            yield b'{"message":{"role":"toolResult","content":"'
            for _ in range(1024):
                yield b"a" * (64 * 1024)
            yield b'"}}\n'

        tracemalloc.start()
        try:
            result = UsageJSON(chunks()).record()
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        self.assertEqual(result, {"message": {"role": "toolResult"}})
        self.assertLess(peak, 1024 * 1024)
