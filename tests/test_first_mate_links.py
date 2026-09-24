"""Validation, classification, and normalization contracts for First Mate links."""
from __future__ import annotations

import unittest
from unittest.mock import patch

from herdr_harness.first_mate_links import (
    MAX_TITLE_LENGTH,
    MAX_URL_LENGTH,
    LinkValidationError,
    default_link_title,
    normalize_link,
    parse_github_pull_request,
    validate_internal_link_source,
    validate_link_provenance,
)


class FirstMateLinkTests(unittest.TestCase):
    def assert_invalid(self, value, **values):
        with self.assertRaises(LinkValidationError):
            normalize_link(value, **values)

    def test_github_pull_request_paths_canonicalize_to_their_root(self):
        for value in (
            "https://github.com/synthetic-owner/synthetic-repo/pull/42",
            "https://github.com/synthetic-owner/synthetic-repo/pull/42/",
            "https://github.com/synthetic-owner/synthetic-repo/pull/42/files",
            "https://github.com/synthetic-owner/synthetic-repo/pull/42/files#diff-1",
            "https://github.com/synthetic-owner/synthetic-repo/pull/42?diff=split",
            "http://github.com/synthetic-owner/synthetic-repo/pull/42/files",
        ):
            with self.subTest(value=value):
                normalized = normalize_link(value)
                self.assertEqual(normalized["url"], "https://github.com/synthetic-owner/synthetic-repo/pull/42")
                self.assertEqual(normalized["kind"], "pull_request")
                self.assertEqual(normalized["number"], 42)
                self.assertEqual(normalized["owner"], "synthetic-owner")
                self.assertEqual(normalized["repo"], "synthetic-repo")
                self.assertFalse(normalized["title_supplied"])
                self.assertEqual(normalized["title"], "synthetic-owner/synthetic-repo #42")

    def test_only_exact_github_pull_request_paths_are_recognized(self):
        for value in (
            "https://github.example.test/synthetic-owner/synthetic-repo/pull/42",
            "https://github.com/synthetic-owner/synthetic-repo/issues/42",
            "https://github.com/synthetic-owner/synthetic-repo/commit/abc",
            "https://github.com/pull/42",
        ):
            with self.subTest(value=value):
                self.assertIsNone(parse_github_pull_request(value))
                self.assertEqual(normalize_link(value)["kind"], "link")
        recognized = parse_github_pull_request("https://github.com/synthetic-owner/synthetic-repo/pull/7/files")
        self.assertEqual(recognized["url"], "https://github.com/synthetic-owner/synthetic-repo/pull/7")
        self.assertEqual(recognized["number"], 7)

    def test_non_github_pull_requests_require_explicit_classification(self):
        normalized = normalize_link(
            "https://github.example.test/synthetic-team/synthetic-repo/pull/5/files",
            kind="pull_request",
        )
        self.assertEqual(normalized["kind"], "pull_request")
        self.assertEqual(normalized["url"], "https://github.example.test/synthetic-team/synthetic-repo/pull/5/files")
        self.assertEqual(normalized["title"], "github.example.test")
        self.assertNotIn("number", normalized)

    def test_github_owner_and_repository_casing_folds_without_touching_paths(self):
        canonical = "https://github.com/synthetic-owner/synthetic-repo/pull/42/files#diff-1"
        for value in (
            "https://github.com/Synthetic-Owner/Synthetic-Repo/pull/42/files#diff-1",
            "https://github.com/SYNTHETIC-OWNER/SYNTHETIC-REPO/pull/42",
            canonical,
        ):
            with self.subTest(value=value):
                normalized = normalize_link(value)
                self.assertEqual(normalized["url"], "https://github.com/synthetic-owner/synthetic-repo/pull/42")
                self.assertEqual(normalized["owner"], "synthetic-owner")
                self.assertEqual(normalized["repo"], "synthetic-repo")
                self.assertEqual(normalized["title"], "synthetic-owner/synthetic-repo #42")
        # General link paths keep their exact casing.
        general = normalize_link("https://Share.Example.Test/Path-Case?Query=Keep#Fragment")
        self.assertEqual(general["url"], "https://share.example.test/Path-Case?Query=Keep#Fragment")

    def test_bracketed_ipv6_share_links_round_trip_and_keep_brackets(self):
        value = "https://[2001:db8::42]:8443/review?tab=links#evidence"
        normalized = normalize_link(value)
        self.assertEqual(normalized["url"], value)
        self.assertEqual(normalized["kind"], "link")
        self.assertEqual(normalized["title"], "[2001:db8::42]")
        self.assertEqual(normalize_link("http://[2001:db8::42]/review")["url"], "http://[2001:db8::42]/review")
        self.assertEqual(normalize_link("https://[2001:DB8::42]:8443/review")["url"],
                         "https://[2001:db8::42]:8443/review")
        for value in (
            "https://[]:8443/review",
            "https://[fe80::1%25en0]:8443/review",
            "https://[2001:db8::42]:0/review",
            "https://[2001:db8::42]:70000/review",
            "https://user:secret@[2001:db8::42]/review",
            "https://[2001:db8::42/review",
        ):
            with self.subTest(value=value):
                self.assert_invalid(value)

    def test_general_links_preserve_meaningful_components(self):
        value = "http://share.example.test:8443/private/report?token=synthetic&view=summary#section-2"
        normalized = normalize_link(value)
        self.assertEqual(normalized["url"], value)
        self.assertEqual(normalized["kind"], "link")
        self.assertEqual(normalized["title"], "share.example.test")
        self.assertFalse(normalized["title_supplied"])
        self.assertEqual(normalize_link("HTTPS://Share.Example.Test/Path")["url"], "https://share.example.test/Path")
        self.assertEqual(normalize_link("https://example.test:443/report")["url"], "https://example.test:443/report")

    def test_caller_titles_and_kinds_are_bounded(self):
        normalized = normalize_link(
            "https://share.example.test/private/report",
            title="  Synthetic review evidence  ",
            kind="pull_request",
        )
        self.assertEqual(normalized["title"], "Synthetic review evidence")
        self.assertTrue(normalized["title_supplied"])
        self.assertEqual(normalized["kind"], "pull_request")
        self.assert_invalid("https://share.example.test/report", kind="issue")
        self.assert_invalid("https://share.example.test/report", kind="")
        self.assert_invalid("https://share.example.test/report", title="x" * (MAX_TITLE_LENGTH + 1))
        self.assert_invalid("https://share.example.test/report", title="bad\x01title")

    def test_absolute_http_and_https_are_the_only_supported_schemes(self):
        for value in (
            "github.com/synthetic-owner/synthetic-repo/pull/1",
            "//github.com/synthetic-owner/synthetic-repo/pull/1",
            "javascript:alert(1)",
            "data:text/plain,hello",
            "file:///tmp/synthetic-report.txt",
            "ftp://example.test/report",
            "",
            None,
            "https://example.test/" + "a" * MAX_URL_LENGTH,
        ):
            with self.subTest(value=value):
                self.assert_invalid(value)
        boundary = "https://example.test/" + "a" * (MAX_URL_LENGTH - len("https://example.test/"))
        self.assertEqual(normalize_link(boundary)["url"], boundary)

    def test_credentials_control_characters_hosts_and_ports_are_rejected(self):
        for value in (
            "https://user:secret@example.test/report",
            "https://user@example.test/report",
            "https://@example.test/report",
            "https://exa mple.test/report",
            "https://example.test:99999/report",
            "https://example.test:0/report",
            "https://example.test:abc/report",
            "https://example.test:/report",
            "https://-example.test/report",
            "https://bad_host.example.test/report",
            "https://example.test/report\n",
            "https://example.test/report\x00",
        ):
            with self.subTest(value=value):
                self.assert_invalid(value)

    def test_provenance_is_trusted_bounded_and_optional(self):
        provenance = validate_link_provenance({
            "native_session_id": "synthetic-session-1",
            "assignment_id": "fma_synthetic",
            "observed_at": "2026-09-21T20:00:00Z",
        })
        self.assertEqual(provenance, {
            "native_session_id": "synthetic-session-1",
            "assignment_id": "fma_synthetic",
            "observed_at": "2026-09-21T20:00:00Z",
        })
        self.assertEqual(validate_link_provenance(None), {})
        self.assertEqual(validate_link_provenance({"document_id": None}), {})
        invalid = (
            {"client_note": "forged"},
            "not-an-object",
            {"native_session_id": 7},
            {"native_session_id": "bad\x02value"},
            {"native_session_id": "s" * 501},
        )
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(LinkValidationError):
                    validate_link_provenance(value)
        self.assertEqual(validate_internal_link_source("discovery"), "discovery")
        self.assertEqual(validate_internal_link_source("agent"), "agent")
        for value in ("user", "system", "", None):
            with self.subTest(value=value):
                with self.assertRaises(LinkValidationError):
                    validate_internal_link_source(value)

    def test_derived_titles_never_claim_pull_request_lifecycle(self):
        title = default_link_title("https://github.com/synthetic-owner/synthetic-repo/pull/3", "pull_request")
        self.assertEqual(title, "synthetic-owner/synthetic-repo #3")
        for state in ("draft", "ready", "open", "merged", "closed", "review"):
            self.assertNotIn(state, title.lower())
        self.assertEqual(default_link_title("https://share.example.test/report", "link"), "share.example.test")

    def test_normalization_never_opens_a_connection(self):
        with patch("socket.create_connection", side_effect=AssertionError("network use is not allowed")):
            normalized = normalize_link(
                "http://share.example.test:8443/private/report?token=synthetic#summary"
            )
        self.assertEqual(normalized["url"], "http://share.example.test:8443/private/report?token=synthetic#summary")


if __name__ == "__main__":
    unittest.main()
