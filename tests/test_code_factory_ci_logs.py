"""Regression coverage for failures hidden by large successful-test log tails."""

import unittest

from herdr_harness.code_factory.ci_logs import MAX_LOG_CHARS, failed_log_excerpt
from herdr_harness.code_factory import prompts


class FailureExcerptTests(unittest.TestCase):
    def test_short_log_is_unchanged_and_unknown_format_keeps_tail(self):
        self.assertEqual(failed_log_excerpt('a short log\n'), 'a short log\n')
        log = 'unrecognized output\n' * 2000
        self.assertEqual(failed_log_excerpt(log), log[-MAX_LOG_CHARS:])

    def test_early_swift_failure_survives_runtime_noise_and_passed_tests(self):
        log = ('mac\tTest\tUnable to connect, error: service unavailable\n'
               'mac\tTest\tTest a failed operation passed\n'
               'mac\tTest\timage decoder: *** ERROR: invalid synthetic image\n') * 1000
        log += 'mac\tTest\tTest compactCue recorded an issue at CompactTests.swift:14: Expectation failed: visible\n'
        log += 'mac\tTest\tactual: false; expected: true\n'
        log += 'mac\tTest\tTest passed\n' * 4000
        excerpt = failed_log_excerpt(log)
        self.assertIn('CompactTests.swift:14', excerpt)
        self.assertIn('actual: false; expected: true', excerpt)
        self.assertNotIn('Unable to connect', excerpt)
        self.assertNotIn('image decoder', excerpt)
        self.assertLessEqual(len(excerpt), MAX_LOG_CHARS)
        # Both reviewer and reviser retain the same diagnostic budget.
        revision = prompts.reviser_prompt({}, None, excerpt, {'number': 7})
        self.assertIn('CompactTests.swift:14', revision)

    def test_multiple_jobs_survive_many_distinct_failures_in_first_job(self):
        log = ''.join(f'mac\tTest\tTest case{i} recorded an issue at Case.swift:{i}\n' for i in range(200))
        log += 'portable\tTest\tFAIL: test_bounded_read (test_links.LinksTests)\n'
        log += 'portable\tTest\tAssertionError: 65 != 64\n'
        log += 'ios\tBuild\tSources/Example.swift:14:5: error: cannot convert value\n'
        log += 'passed\n' * 4000
        excerpt = failed_log_excerpt(log)
        for expected in ['case0', 'test_bounded_read', 'AssertionError: 65 != 64', 'Example.swift:14:5']:
            self.assertIn(expected, excerpt)
        self.assertLessEqual(len(excerpt), MAX_LOG_CHARS)

    def test_long_diagnostic_lines_are_bounded(self):
        log = 'mac\tTest\tExpectation failed: ' + 'x' * 100_000 + '\n'
        log += 'portable\tTest\tFAIL: useful_other_job\n' + 'passed\n' * 4000
        excerpt = failed_log_excerpt(log)
        self.assertLessEqual(len(excerpt), MAX_LOG_CHARS)
        self.assertIn('useful_other_job', excerpt)

    def test_repeated_diagnostics_do_not_hide_later_failure(self):
        log = 'mac\tTest\tTest repeated recorded an issue at Example.swift:12\n' * 2000
        log += 'mac\tTest\tTest distinct recorded an issue at Example.swift:45\n'
        log += 'passed\n' * 4000
        self.assertIn('Example.swift:45', failed_log_excerpt(log))


if __name__ == '__main__':
    unittest.main()
