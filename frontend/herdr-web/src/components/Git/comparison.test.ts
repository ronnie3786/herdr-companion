import { describe, expect, it } from "vitest";
import { comparisonSelection, isComparisonAncestor, questionScopeKey, referencedComparisonFiles, revisionOptions, WORKING_TREE } from "./comparison";

describe("shared Git comparison", () => {
  it("offers merged branch commits without allowing sibling or reverse pairs", () => {
    const commits = [
      { sha: "left", parents: ["base"], subject: "Left" },
      { sha: "right", parents: ["base"], subject: "Right" },
      { sha: "merge", parents: ["left", "right"], subject: "Merge" },
    ];
    expect(isComparisonAncestor("left", "right", "base", commits)).toBe(false);
    expect(isComparisonAncestor("right", "merge", "base", commits)).toBe(true);
    expect(isComparisonAncestor("merge", "left", "base", commits)).toBe(false);
    expect(isComparisonAncestor("base", "right", "base", commits)).toBe(true);
    expect(isComparisonAncestor("right", WORKING_TREE, "base", commits)).toBe(true);
  });
  it("offers navigation only for exact cited files available in this comparison", () => {
    expect(referencedComparisonFiles("Inspect src/a.ts:12 and other/a.ts. See a.ts too.", ["src/a.ts", "src/b.ts", "a.ts"]))
      .toEqual(["src/a.ts", "a.ts"]);
    expect(referencedComparisonFiles("other/src/a.ts is from a later commit", ["src/a.ts"])).toEqual([]);
  });
  it("compares two explicit tree endpoints rather than including the left commit", () => {
    expect(comparisonSelection("older", "newer")).toEqual({ mode: "range", start_commit: "older", end_commit: "newer" });
    expect(comparisonSelection("older", WORKING_TREE)).toEqual({ mode: "working-tree", start_commit: "older" });
  });
  it("keeps the target baseline first without duplicating it", () => {
    expect(revisionOptions("base", [
      { sha: "base", parents: [], subject: "Base" },
      { sha: "one", parents: ["base"], subject: "First" },
      { sha: "two", parents: ["one"], subject: "Second" },
    ])).toEqual(["base", "one", "two"]);
  });
  it("never resumes the same-file question at a different commit or workspace", () => {
    const key = (revision: string, target = "feature:one", root = "/repo") => questionScopeKey("https://example.invalid", target, root, "a.swift", "comparison", revision);
    expect(key("one")).not.toBe(key("two"));
    expect(key("one")).not.toBe(key("one", "feature:two"));
    expect(key("one")).not.toBe(key("one", "feature:one", "/other"));
  });
});
