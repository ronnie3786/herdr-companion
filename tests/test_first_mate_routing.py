"""Synthetic unit contract for First Mate role routing."""
import unittest

from herdr_harness.first_mate_routing import delegation_profile, resolve_dispatch_policy


class FirstMateRoutingTests(unittest.TestCase):
    def test_four_runtime_profiles_and_feature_override(self):
        environ = {
            "HERDR_FIRST_MATE_MODEL": "synthetic/coordinator",
            "HERDR_FIRST_MATE_COORDINATOR_THINKING": "low",
            "HERDR_FIRST_MATE_PLANNER_MODEL": "synthetic/planner",
            "HERDR_FIRST_MATE_PLANNER_THINKING": "high",
            "HERDR_FIRST_MATE_WORKER_MODEL": "synthetic/worker",
            "HERDR_FIRST_MATE_WORKER_THINKING": "medium",
            "HERDR_FIRST_MATE_ARCHITECT_MODEL": "synthetic/architect",
            "HERDR_FIRST_MATE_ARCHITECT_THINKING": "xhigh",
        }
        feature = {"coordinator_model": "synthetic/feature", "coordinator_thinking": "xhigh"}
        coordinator = resolve_dispatch_policy(kind="coordinator", feature=feature,
                                              claim={}, environ=environ)
        planning = resolve_dispatch_policy(kind="worker", feature=feature,
                                           claim={"model": "synthetic/ignored", "metadata": {"model_profile": "planning"}},
                                           environ=environ)
        execution = resolve_dispatch_policy(kind="advisor", feature=feature,
                                            claim={}, environ=environ)
        architect = resolve_dispatch_policy(
            kind="worker", feature=feature,
            claim={"model": "synthetic/must-not-fallback",
                   "metadata": {"model_profile": "architect"}},
            environ=environ,
        )
        self.assertEqual(coordinator.selection(), {
            "profile": "coordinator", "requested_model": "synthetic/feature",
            "requested_thinking": "xhigh", "actual_model": None,
            "actual_thinking": None, "source": "feature_override"})
        self.assertEqual((planning.requested_model, planning.requested_thinking, planning.source),
                         ("synthetic/planner", "high", "host_policy"))
        self.assertEqual((execution.requested_model, execution.requested_thinking, execution.source),
                         ("synthetic/worker", "medium", "host_policy"))
        self.assertEqual((architect.profile, architect.requested_model,
                          architect.requested_thinking, architect.source),
                         ("architect", "synthetic/architect", "xhigh", "host_policy"))

    def test_legacy_absence_assignment_override_and_pi_default(self):
        assignment = resolve_dispatch_policy(
            kind="worker", feature={}, claim={"model": "synthetic/legacy-override", "metadata": {}},
            environ={}, stage_key="planning")
        default = resolve_dispatch_policy(kind="worker", feature={}, claim={"metadata": {}},
                                          environ={}, stage_key="planning notes")
        legacy = resolve_dispatch_policy(kind="worker", feature={}, claim={"metadata": {"model_profile": "planning"}},
                                         environ={"HERDR_FIRST_MATE_MODEL": "synthetic/host"})
        self.assertEqual((assignment.profile, assignment.source), ("planning", "assignment_override"))
        self.assertEqual((default.profile, default.source, default.requested_model),
                         ("execution", "pi_default", ""))
        self.assertEqual((legacy.requested_model, legacy.source), ("synthetic/host", "host_policy"))

    def test_architect_requires_an_exact_independent_host_pin(self):
        from herdr_harness.first_mate_routing import ArchitectConfigurationError

        claim = {"model": "synthetic/assignment", "metadata": {"model_profile": "architect"}}
        for environment in ({}, {"HERDR_FIRST_MATE_MODEL": "synthetic/legacy"},
                            {"HERDR_FIRST_MATE_WORKER_MODEL": "synthetic/worker"},
                            {"HERDR_FIRST_MATE_ARCHITECT_MODEL": "unqualified"},
                            {"HERDR_FIRST_MATE_ARCHITECT_MODEL": "synthetic/architect",
                             "HERDR_FIRST_MATE_ARCHITECT_THINKING": "ultra"}):
            with self.subTest(environment=environment), self.assertRaises(ArchitectConfigurationError):
                resolve_dispatch_policy(kind="worker", feature={}, claim=claim, environ=environment)

    def test_invalid_profile_shapes_are_deterministic(self):
        for value in ("review", {}, [], 7, True):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "planning, execution, or architect"):
                delegation_profile(value, stage_key="planning")


if __name__ == "__main__":
    unittest.main()
