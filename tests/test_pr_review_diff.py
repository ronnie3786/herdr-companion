import unittest
from herdr_harness.pr_review_diff import parse_unified_diff, line_window

class PRReviewDiffTests(unittest.TestCase):
    def test_rename_and_multiple_hunks_keep_line_numbers(self):
        files = parse_unified_diff('''diff --git a/old.txt b/new.txt
similarity index 90%
rename from old.txt
rename to new.txt
--- a/old.txt
+++ b/new.txt
@@ -1,2 +1,2 @@ heading
-one
+two
 two
@@ -8 +8 @@
-old
+new
''')
        self.assertEqual(files[0]["status"], "renamed")
        self.assertEqual(files[0]["path"], "new.txt")
        self.assertEqual(files[0]["additions"], 2)
        self.assertEqual(files[0]["hunks"][0]["lines"][0]["old_number"], 1)

    def test_line_window_is_one_based_and_clamped(self):
        self.assertEqual(line_window("a\nb\nc\n", 0, 9)["text"], "a\nb\nc\n")

    def test_deleted_and_binary_paths_with_spaces_are_preserved(self):
        files = parse_unified_diff('''diff --git a/old name.bin b/old name.bin
deleted file mode 100644
Binary files a/old name.bin and /dev/null differ
diff --git a/new name.bin b/new name.bin
new file mode 100644
Binary files /dev/null and b/new name.bin differ
''')
        self.assertEqual([(item["path"], item["old_path"], item["status"]) for item in files], [("old name.bin", "old name.bin", "binary"), ("new name.bin", "new name.bin", "binary")])

if __name__ == '__main__': unittest.main()
