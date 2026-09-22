import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { configureClient } from "./client";
import {
  gitCommitDiff,
  gitCommitFiles,
  gitDiff,
  gitOpenFile,
  gitStage,
  gitStatus,
  gitTargetFromKey,
  gitTargetKey,
  gitUnstage,
  paneGitCommitDiff,
  paneGitCommitFiles,
  paneGitDiff,
} from "./git";

const BASE_URL = "http://127.0.0.1:9092/api/v1";

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  fetchMock = vi.fn().mockResolvedValue(
    new Response(JSON.stringify({ ok: true, files: [], diff: "" }), {
      headers: { "content-type": "application/json" },
    }),
  );
  vi.stubGlobal("fetch", fetchMock);
  configureClient({ baseUrl: BASE_URL, onUnauthorized: undefined });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("pane Git read preconditions", () => {
  it("includes the expected repository root in working-tree diff queries", async () => {
    await paneGitDiff("w1:p1", "src/a b.ts", "untracked", "/repo with spaces");

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      `${BASE_URL}/panes/w1%3Ap1/git/diff?file=src%2Fa+b.ts&section=untracked&expected_root=%2Frepo+with+spaces`,
    );
  });

  it("includes the expected repository root in commit-file queries", async () => {
    await paneGitCommitFiles("w1:p1", "a1b2c3d", "/repo");

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      `${BASE_URL}/panes/w1%3Ap1/git/commit-files?hash=a1b2c3d&expected_root=%2Frepo`,
    );
  });

  it("includes the expected repository root in historical diff queries", async () => {
    await paneGitCommitDiff("w1:p1", "a1b2c3d", "src/a.ts", "/repo");

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      `${BASE_URL}/panes/w1%3Ap1/git/commit-diff?hash=a1b2c3d&file=src%2Fa.ts&expected_root=%2Frepo`,
    );
  });
});

describe("First Mate Git target routing", () => {
  it("routes every operation through the feature API with an explicit workspace", async () => {
    const target = gitTargetKey({ kind: "firstMate", featureId: "fmf/one", workspaceId: "fma two" });
    await gitStatus(target);
    await gitDiff(target, "src/a b.ts", "unstaged", "/repo");
    await gitCommitFiles(target, "a1b2c3d", "/repo");
    await gitCommitDiff(target, "a1b2c3d", "src/a.ts", "/repo");
    await gitStage(target, "src/a.ts", "/repo");
    await gitUnstage(target, "src/a.ts", "/repo");
    await gitOpenFile(target, "src/a.ts", "/repo", true);

    const base = `${BASE_URL}/first-mate/features/fmf%2Fone/git`;
    expect(fetchMock.mock.calls.map((call) => call[0])).toEqual([
      `${base}?workspace=fma+two`,
      `${base}/diff?workspace=fma+two&file=src%2Fa+b.ts&section=unstaged&expected_root=%2Frepo`,
      `${base}/commit-files?workspace=fma+two&hash=a1b2c3d&expected_root=%2Frepo`,
      `${base}/commit-diff?workspace=fma+two&hash=a1b2c3d&file=src%2Fa.ts&expected_root=%2Frepo`,
      `${base}/stage`, `${base}/unstage`, `${base}/open`,
    ]);
    expect(fetchMock.mock.calls.slice(4).map((call) => JSON.parse(call[1].body))).toEqual([
      { file: "src/a.ts", expected_root: "/repo", workspace: "fma two" },
      { file: "src/a.ts", expected_root: "/repo", workspace: "fma two" },
      { file: "src/a.ts", expected_root: "/repo", reveal: true, workspace: "fma two" },
    ]);
  });

  it("never sends an opaque feature key to a pane endpoint", async () => {
    const target = gitTargetKey({ kind: "firstMate", featureId: "feature", workspaceId: "project" });
    await gitStatus(target);
    expect(fetchMock.mock.calls[0]?.[0]).not.toContain("/panes/");
  });

  it("round-trips scoped keys and rejects malformed opaque identities", () => {
    const target = { kind: "firstMate", featureId: "feature:one/%", workspaceId: "worker:two" } as const;
    expect(gitTargetFromKey(gitTargetKey(target))).toEqual(target);
    for (const key of ["first-mate-git:", "first-mate-git:feature:", "first-mate-git:feature:worker:extra", "first-mate-git:%E0:project"]) {
      expect(() => gitTargetFromKey(key)).toThrow("Invalid First Mate Git target");
    }
  });

  it("keeps a plain pane key on the unchanged pane status endpoint", async () => {
    await gitStatus("w1:p1");
    expect(fetchMock.mock.calls[0]?.[0]).toBe(`${BASE_URL}/panes/w1%3Ap1/git`);
  });
});

describe("pane Git open-file requests", () => {
  it("posts the file, precondition root, and reveal flag", async () => {
    await gitOpenFile("w1:p1", "Sources/Pane.swift", "/repo with spaces", true);

    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(`${BASE_URL}/panes/w1%3Ap1/git/open`);
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body)).toEqual({
      file: "Sources/Pane.swift",
      expected_root: "/repo with spaces",
      reveal: true,
    });
  });
});
