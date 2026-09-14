"""Ephemeral service tests must never reconcile an operator's live Pi jobs."""
import tempfile
import unittest
from pathlib import Path

from herdr_harness.service import HerdrService


class FirstMateServiceTests(unittest.TestCase):
    def test_memory_service_isolates_runtime_and_never_dispatches(self):
        service = HerdrService(environ={})
        self.addCleanup(service.stop)
        self.assertFalse(service._first_mate_execution_enabled)
        runtime = service.first_mate
        self.assertIn("herdr-first-mate-", str(runtime.root))
        service.first_mate_changed("synthetic-feature")
        self.assertIsNone(runtime._thread)
        service.stop()
        self.assertFalse(runtime.root.exists())

    def test_durable_service_uses_its_configured_state_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            service = HerdrService(environ={"HERDR_STATE_DIR": directory})
            try:
                self.assertTrue(service._first_mate_execution_enabled)
                self.assertEqual(service.first_mate.root, Path(directory).resolve() / "first-mate-runs")
            finally:
                service.stop()
