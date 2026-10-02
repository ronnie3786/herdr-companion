import unittest

from herdr_harness.pr_review_report import markdown_html, render_report


class ReviewReportTests(unittest.TestCase):
    def test_markdown_is_readable_without_executable_markup_or_links(self):
        rendered = markdown_html("# Findings\n\nA **real issue** in `garden.py`.\n\n- First\n- Second\n\n1. Inspect\n2. Verify\n\n```html\n<script>alert('code')</script>\n```\n\n<img src=x onerror=alert(1)>\n\n[Follow](javascript:alert(1))")
        self.assertIn("<h2>Findings</h2>", rendered)
        self.assertIn("<strong>real issue</strong>", rendered)
        self.assertIn("<code>garden.py</code>", rendered)
        self.assertIn("<ul>", rendered)
        self.assertIn("<ol>", rendered)
        self.assertIn("<pre><code>&lt;script&gt;", rendered)
        self.assertNotIn("<script>", rendered)
        self.assertNotIn("<img", rendered)
        self.assertNotIn("href=", rendered)

    def test_coverage_is_owned_by_ledger_and_raw_links_use_exact_ids(self):
        rendered = render_report("Everything is fine. <iframe src=https://example.test/>",
            {"base_sha": "a" * 40, "head_sha": "b" * 40}, [
                {"name": "Synthetic <Reviewer>", "state": "failed", "complete": False, "reason": "Interrupted <b>before</b> completion.",
                 "documents": [{"id": "prdoc_abcdef123456", "title": "Raw <script>report</script>"}, {"id": "javascript:alert(1)", "title": "Bad link"}]}])
        self.assertIn("Incomplete review coverage", rendered)
        self.assertIn("Synthetic &lt;Reviewer&gt;", rendered)
        self.assertIn("not an all-clear", rendered)
        self.assertIn('href="herdr-pr-review-document:prdoc_abcdef123456"', rendered)
        self.assertNotIn("javascript:alert", rendered)
        self.assertNotIn("<iframe", rendered)
        self.assertNotIn("<script>", rendered)
        self.assertNotIn('src="http', rendered)
        self.assertIn("default-src 'none'", rendered)
        self.assertIn("backdrop-filter:blur", rendered)

    def test_code_and_unclosed_fence_remain_literal(self):
        rendered = markdown_html("`**literal**`\n\n```\n# still code\n<img src=x>")
        self.assertIn("<code>**literal**</code>", rendered)
        self.assertIn("# still code", rendered)
        self.assertNotIn("<h2>", rendered)
        self.assertNotIn("<img", rendered)
