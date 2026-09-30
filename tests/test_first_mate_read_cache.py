"""Bounded verification read cache behavior."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import threading
import unittest

from herdr_harness.first_mate_read_cache import AssessmentReadBusy, AssessmentReadCache


class AssessmentReadCacheTests(unittest.TestCase):
    def test_display_read_does_not_queue_or_reuse_unvalidated_cached_green(self):
        cache = AssessmentReadCache()
        cache.get("feature", lambda: "old", lambda: {"status": "verified"})
        entered, release = threading.Event(), threading.Event()

        def identity():
            entered.set()
            self.assertTrue(release.wait(5))
            return "new"

        def unexpected():
            self.fail("A competing display read must not probe or compute")

        with ThreadPoolExecutor(max_workers=1) as pool:
            first = pool.submit(cache.get, "feature", identity, lambda: {"status": "failed"}, wait=False)
            try:
                self.assertTrue(entered.wait(5))
                with self.assertRaises(AssessmentReadBusy):
                    cache.get("feature", unexpected, unexpected, wait=False)
                self.assertEqual(cache.get("other", lambda: "new", lambda: "independent", wait=False),
                                 "independent")
            finally:
                release.set()
            self.assertEqual(first.result(timeout=5), {"status": "failed"})
        self.assertEqual(cache.get("feature", lambda: "new", unexpected, wait=False), {"status": "failed"})

    def test_hit_invalidation_ttl_and_copy_isolation(self):
        now = [0.0]
        identity = ["one"]
        calls = []
        cache = AssessmentReadCache(ttl=10, clock=lambda: now[0])

        def compute():
            calls.append(identity[0])
            return {"identity": identity[0], "items": []}

        first = cache.get("feature", lambda: identity[0], compute)
        first["items"].append("caller mutation")
        self.assertEqual(cache.get("feature", lambda: identity[0], compute),
                         {"identity": "one", "items": []})
        self.assertEqual(calls, ["one"])

        identity[0] = "two"
        self.assertEqual(cache.get("feature", lambda: identity[0], compute)["identity"], "two")
        now[0] = 10.0
        self.assertEqual(cache.get("feature", lambda: identity[0], compute)["identity"], "two")
        self.assertEqual(calls, ["one", "two", "two"])

    def test_concurrent_reads_share_one_computation(self):
        cache = AssessmentReadCache()
        entered = threading.Event()
        release = threading.Event()
        calls = []

        def compute():
            calls.append(1)
            entered.set()
            self.assertTrue(release.wait(2))
            return {"status": "verified"}

        with ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(cache.get, "feature", lambda: "same", compute) for _ in range(8)]
            self.assertTrue(entered.wait(2))
            release.set()
            self.assertEqual([future.result(timeout=2) for future in futures],
                             [{"status": "verified"}] * 8)
        self.assertEqual(len(calls), 1)

    def test_failure_is_shared_but_not_cached(self):
        cache = AssessmentReadCache()
        entered = threading.Event()
        release = threading.Event()
        calls = []

        def fail():
            calls.append("failure")
            entered.set()
            self.assertTrue(release.wait(2))
            raise OSError("synthetic probe failure")

        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(cache.get, "feature", lambda: "same", fail) for _ in range(4)]
            self.assertTrue(entered.wait(2))
            release.set()
            for future in futures:
                with self.assertRaisesRegex(OSError, "synthetic probe failure"):
                    future.result(timeout=2)
        self.assertEqual(calls, ["failure"])
        self.assertEqual(cache.get("feature", lambda: "same", lambda: {"status": "available"}),
                         {"status": "available"})


if __name__ == "__main__":
    unittest.main()
