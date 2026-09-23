// @vitest-environment node
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";

// The app intentionally ships offline assets. Verify that they really come
// from the shared renderer, so a web styling change cannot leave PR Review on
// an older copied implementation. Never overwrite the checked-in resources.
test("the bundled Mac diff is an exact build of the shared renderer", () => {
  const root = fileURLToPath(new URL("../../../", import.meta.url));
  const output = mkdtempSync(join(tmpdir(), "herdr-diff-bundle-"));
  try {
    execFileSync(process.execPath, [
      resolve(root, "node_modules/vite/bin/vite.js"), "build",
      "--config", "vite.native-diff.config.ts", "--outDir", output,
    ], { cwd: root, env: { ...process.env, NODE_ENV: "production" }, timeout: 90_000, stdio: "pipe", maxBuffer: 2 * 1024 * 1024 });
    for (const name of ["PRReviewDiffRenderer.html", "PRReviewDiffRenderer.css", "PRReviewDiffRenderer.js", "PRReviewDiffRenderer-LICENSES.txt"]) {
      const digest = (path) => createHash("sha256").update(readFileSync(path)).digest("hex");
      expect(digest(join(output, name)), `${name} is stale; run npm run build:mac-diff`)
        .toBe(digest(resolve(root, "../../herdr-harness-mac/herdr-harness-mac/Resources", name)));
    }
  } finally {
    rmSync(output, { recursive: true, force: true });
  }
}, 100_000);
